#!/usr/bin/env bash
################################################################################
# e2e_onserver_pbmc.sh
#
# End-to-end ON-SERVER (traditional) scRNA-seq pipeline for PBMC datasets.
# Replicates the "On-Server (SSD) Execution" baseline from the GigaScience
# paper Table 2.
#
# This script runs piscem + alevin-fry entirely on a dedicated server — no AWS
# resources (no S3, Lambda, ECR, EventBridge).
#
# USAGE:
#   # Driver mode (default): SSH into the server, run everything, download results
#   bash scripts/e2e_onserver_pbmc.sh pbmc1k
#   bash scripts/e2e_onserver_pbmc.sh pbmc10k
#
#   # Run mode (on the server itself):
#   bash scripts/e2e_onserver_pbmc.sh pbmc1k --run
#
#   # Dry-run mode (validate requirements only):
#   bash scripts/e2e_onserver_pbmc.sh pbmc1k --dry-run
#
# CREDENTIALS (two options):
#   1. GitHub Actions: credentials are injected automatically from repository
#      secrets (SSH_USER, SSH_PASSWORD, SERVER_HOST). No setup needed.
#   2. Local: create a .env file from .env.example and fill in your values.
#      NEVER commit .env to version control.
#
# ENVIRONMENT VARIABLES (override via .env or shell export):
#   SERVER_HOST              Server IP or hostname
#   SSH_USER                 SSH username
#   SSH_PASSWORD             SSH/sudo password (used for key setup + sudo)
#   THREADS                  CPU threads for tools (default: nproc on server)
#   RUN_QC                   Run QC analysis after quant (default: 1)
#   WRITE_H5AD               Save h5ad from QC (default: 0, requires RUN_QC=1)
#   DOWNLOAD_RESULTS         Download results to local machine (default: 1)
#   LOCAL_RESULTS_DIR        Local directory for results (default: ./onserver_runs)
#   PISCEM_INDEX_DIR         Piscem index directory on server
#   T2G_PATH                 Transcript-to-gene mapping file on server
#   FASTQ_BASE_DIR           Base directory for FASTQ files on server
#   SERVER_RUN_DIR           Base run directory on server
#
################################################################################

set -euo pipefail

################################################################################
# Helper Functions
################################################################################

_mask() {
    local s="$*"
    [[ -n "${SERVER_HOST:-}" ]] && s="${s//$SERVER_HOST/***}"
    [[ -n "${SSH_USER:-}" ]]   && s="${s//$SSH_USER/***}"
    echo "$s"
}

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $(_mask "$*")" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $(_mask "$*")" >&2
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $(_mask "$*")" >&2
}

die() {
    log_error "$@"
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

rand_hex() {
    local n="${1:-8}"
    if [[ -r /dev/urandom ]]; then
        head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c "$n"
    elif need_cmd openssl; then
        openssl rand -hex $(( (n + 1) / 2 )) | head -c "$n"
    else
        printf '%08x' $RANDOM$RANDOM | head -c "$n"
    fi
}

time_cmd() {
    local start end
    start=$(date +%s%N 2>/dev/null || date +%s)
    "$@"
    local rc=$?
    end=$(date +%s%N 2>/dev/null || date +%s)
    if [[ ${#start} -gt 10 ]]; then
        echo "scale=2; ($end - $start) / 1000000000" | bc
    else
        echo $(( end - start ))
    fi
    return $rc
}

fmt_secs() {
    local secs="$1"
    if need_cmd bc; then
        printf "%.2f" "$(echo "scale=4; $secs / 60" | bc)"
    else
        echo "$(( secs / 60 ))m $(( secs % 60 ))s"
    fi
}

################################################################################
# Load .env file (if present; credentials can also come from environment,
# e.g. via GitHub Actions secrets)
################################################################################

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_dotenv() {
    local env_file="$REPO_ROOT/.env"
    if [[ ! -f "$env_file" ]]; then
        return 0
    fi
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        if [[ -z "${!key:-}" ]]; then
            export "$key=$value"
        fi
    done < "$env_file"
}

load_dotenv

################################################################################
# SSH Configuration & Helpers
################################################################################

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=10 -o ConnectTimeout=30 -o LogLevel=ERROR"
SSH_KEY_FILE="$HOME/.ssh/id_ed25519_scrna"

setup_ssh_keys() {
    local ssh_target="${SSH_USER}@${SERVER_HOST}"

    if [[ ! -f "$SSH_KEY_FILE" ]]; then
        log_info "Generating SSH key pair for pipeline..."
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "scrna-pipeline" >/dev/null 2>&1
    fi

    if ssh -i "$SSH_KEY_FILE" -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" "exit" 2>/dev/null; then
        log_info "SSH key authentication verified."
        _detect_ssh_auth
        log_info "SSH auth mode: $_SSH_AUTH_MODE"
        return 0
    fi

    log_info "Setting up SSH key authentication (one-time setup)..."
    local pub_key
    pub_key=$(cat "${SSH_KEY_FILE}.pub")

    if need_cmd sshpass && [[ -n "${SSH_PASSWORD:-}" ]]; then
        export SSHPASS="$SSH_PASSWORD"
        sshpass -e ssh $SSH_OPTS "$ssh_target" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"
    else
        log_info "You may be prompted for your password (one-time key setup)."
        ssh $SSH_OPTS "$ssh_target" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"
    fi

    if ssh -i "$SSH_KEY_FILE" -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" "exit" 2>/dev/null; then
        log_info "SSH key authentication set up successfully."
    else
        log_warn "SSH key auth could not be verified. Will fall back to password auth."
    fi

    _detect_ssh_auth
    log_info "SSH auth mode: $_SSH_AUTH_MODE"
}

# Cached auth mode: set once during setup_ssh_keys, reused for all operations.
# Values: "key", "sshpass", "interactive"
_SSH_AUTH_MODE=""

_detect_ssh_auth() {
    local ssh_target="${SSH_USER}@${SERVER_HOST}"
    if [[ -f "$SSH_KEY_FILE" ]] && ssh -i "$SSH_KEY_FILE" -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" "exit" 2>/dev/null; then
        _SSH_AUTH_MODE="key"
    elif need_cmd sshpass && [[ -n "${SSH_PASSWORD:-}" ]]; then
        export SSHPASS="$SSH_PASSWORD"
        _SSH_AUTH_MODE="sshpass"
    else
        _SSH_AUTH_MODE="interactive"
    fi
}

run_ssh() {
    local ssh_target="${SSH_USER}@${SERVER_HOST}"
    case "$_SSH_AUTH_MODE" in
        key)      ssh -i "$SSH_KEY_FILE" $SSH_OPTS "$ssh_target" "$@" ;;
        sshpass)  sshpass -e ssh $SSH_OPTS "$ssh_target" "$@" ;;
        *)        ssh $SSH_OPTS "$ssh_target" "$@" ;;
    esac
}

run_ssh_tty() {
    local ssh_target="${SSH_USER}@${SERVER_HOST}"
    case "$_SSH_AUTH_MODE" in
        key)      ssh -t -i "$SSH_KEY_FILE" $SSH_OPTS "$ssh_target" "$@" ;;
        sshpass)  sshpass -e ssh -t $SSH_OPTS "$ssh_target" "$@" ;;
        *)        ssh -t $SSH_OPTS "$ssh_target" "$@" ;;
    esac
}

run_scp() {
    case "$_SSH_AUTH_MODE" in
        key)      scp -i "$SSH_KEY_FILE" $SSH_OPTS "$@" ;;
        sshpass)  sshpass -e scp $SSH_OPTS "$@" ;;
        *)        scp $SSH_OPTS "$@" ;;
    esac
}

################################################################################
# Default Configuration
################################################################################

SERVER_HOST="${SERVER_HOST:-}"
SSH_USER="${SSH_USER:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"

THREADS="${THREADS:-}"
RUN_QC="${RUN_QC:-1}"
WRITE_H5AD="${WRITE_H5AD:-0}"
DOWNLOAD_RESULTS="${DOWNLOAD_RESULTS:-1}"
LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR:-./onserver_runs}"

# Reference paths on server (read-only — NEVER modify or delete these)
# Originals at /home/nnasam/test/test-alevin/ are not directly accessible;
# use copies under the SSH_USER's home, or override via environment.
PISCEM_INDEX_DIR="${PISCEM_INDEX_DIR:-/home/${SSH_USER}/reference/index_output_transcriptome}"
T2G_PATH="${T2G_PATH:-/home/${SSH_USER}/reference/t2g.tsv}"

FASTQ_BASE_DIR="${FASTQ_BASE_DIR:-/home/${SSH_USER}/datasets/10x}"
SERVER_RUN_DIR="${SERVER_RUN_DIR:-/home/${SSH_USER}/onserver_runs}"

RUN_ID="${RUN_ID:-}"

# Internal state
RUN_MODE=0
DRY_RUN_MODE=0
DATASET=""

################################################################################
# FASTQ download URLs
################################################################################

declare -A FASTQ_TAR_URLS=(
    [pbmc1k]="https://cf.10xgenomics.com/samples/cell-exp/3.0.0/pbmc_1k_v3/pbmc_1k_v3_fastqs.tar"
    [pbmc10k]="https://s3-us-west-2.amazonaws.com/10x.files/samples/cell-exp/3.0.0/pbmc_10k_v3/pbmc_10k_v3_fastqs.tar"
)

declare -A FASTQ_DIR_NAMES=(
    [pbmc1k]="pbmc_1k_v3_fastqs"
    [pbmc10k]="pbmc_10k_v3_fastqs"
)

declare -A FASTQ_SUBDIRS=(
    [pbmc1k]="pbmc_1k_v3"
    [pbmc10k]="pbmc_10k_v3"
)

################################################################################
# Argument Parsing
################################################################################

if [[ $# -lt 1 ]]; then
    cat >&2 <<EOF
Usage: $0 <dataset> [--run|--dry-run]

  dataset:    pbmc1k or pbmc10k
  --run:      Execute in run mode directly on the server (instead of SSH driver)
  --dry-run:  Validate requirements without executing the pipeline

Credentials come from GitHub Secrets (via GitHub Actions) or a local .env file.
See .env.example for the template if running locally.

Examples:
  bash $0 pbmc1k
  bash $0 pbmc10k
  RUN_QC=1 WRITE_H5AD=1 bash $0 pbmc1k
  bash $0 pbmc1k --run   # Run locally on the server
EOF
    exit 1
fi

DATASET="$1"
if [[ "$DATASET" != "pbmc1k" && "$DATASET" != "pbmc10k" ]]; then
    die "Unknown dataset: $DATASET (must be pbmc1k or pbmc10k)"
fi

if [[ $# -gt 1 ]]; then
    case "$2" in
        --run) RUN_MODE=1 ;;
        --dry-run) DRY_RUN_MODE=1 ;;
        *) die "Unknown flag: $2 (expected --run or --dry-run)" ;;
    esac
fi

################################################################################
# Generate Run ID
################################################################################

if [[ -z "$RUN_ID" ]]; then
    RUN_ID="${DATASET}-$(date +%s)-$(rand_hex 8)"
fi

################################################################################
################################################################################
##                                                                            ##
##                          DRIVER MODE (default)                             ##
##                                                                            ##
################################################################################
################################################################################

if [[ $RUN_MODE -eq 0 && $DRY_RUN_MODE -eq 0 ]]; then

    if [[ -z "$SERVER_HOST" || -z "$SSH_USER" ]]; then
        die "SERVER_HOST and SSH_USER are not set.
  If running via GitHub Actions, ensure the repository secrets are configured.
  If running locally, create a .env file — see .env.example."
    fi

    SSH_TARGET="${SSH_USER}@${SERVER_HOST}"

    log_info "======== E2E On-Server scRNA Pipeline (DRIVER MODE) ========"
    log_info "Dataset:  $DATASET"
    log_info "Run ID:   $RUN_ID"
    log_info "Server:   $SSH_TARGET"
    log_info "RUN_QC:   $RUN_QC"

    ########################################################################
    # Setup SSH key authentication
    ########################################################################
    setup_ssh_keys

    ########################################################################
    # Test SSH connectivity
    ########################################################################
    log_info "Testing SSH connectivity to $SSH_TARGET..."
    if ! run_ssh "echo SSH_OK" >/dev/null 2>&1; then
        die "Cannot SSH to server. Check credentials in .env"
    fi
    log_info "SSH connection verified."

    ########################################################################
    # Check disk space on server
    ########################################################################
    log_info "Checking disk space on server..."
    FASTQ_SUBDIR="${FASTQ_SUBDIRS[$DATASET]}"
    FASTQ_DIR_NAME="${FASTQ_DIR_NAMES[$DATASET]}"
    FASTQ_CHECK_DIR="${FASTQ_BASE_DIR}/${FASTQ_SUBDIR}/${FASTQ_DIR_NAME}"
    FASTQ_CACHED=$(run_ssh "[ -d '$FASTQ_CHECK_DIR' ] && echo yes || echo no" 2>/dev/null || echo "no")

    if [[ "$DATASET" == "pbmc10k" ]]; then
        if [[ "$FASTQ_CACHED" == "yes" ]]; then
            REQUIRED_MB=20000
        else
            REQUIRED_MB=60000
        fi
    else
        if [[ "$FASTQ_CACHED" == "yes" ]]; then
            REQUIRED_MB=5000
        else
            REQUIRED_MB=10000
        fi
    fi
    AVAIL_MB=$(run_ssh "df -m /home 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null || echo 0)
    log_info "Server disk: ${AVAIL_MB} MB available, ${REQUIRED_MB} MB required (FASTQs cached: ${FASTQ_CACHED})"
    if [[ "${AVAIL_MB:-0}" -lt "$REQUIRED_MB" ]]; then
        die "Insufficient disk space on server: ${AVAIL_MB} MB available, need ${REQUIRED_MB} MB"
    fi

    ########################################################################
    # Copy repo to server
    ########################################################################
    log_info "Copying repository to server..."

    TARBALL_LOCAL=$(mktemp /tmp/scrna-repo-XXXXXX.tar.gz 2>/dev/null || echo "/tmp/scrna-repo-$$.tar.gz")
    REPO_BASENAME="$(basename "$REPO_ROOT")"
    tar -czf "$TARBALL_LOCAL" \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='runs' \
        --exclude='onserver_runs' \
        --exclude='.env' \
        --exclude='MASTER_PROMPT.md' \
        -C "$REPO_ROOT/.." \
        "$REPO_BASENAME"

    REMOTE_REPO_DIR="/home/${SSH_USER}/scrna-repo"

    # Clean up any leftover run directories and repo copies from interrupted runs
    log_info "Cleaning up leftover files from previous runs..."
    run_ssh bash -s <<PRECLEAN
set -euo pipefail
CLEANED=0
# Remove old run directories (but not the parent)
if [[ -d "${SERVER_RUN_DIR}" ]]; then
    for d in "${SERVER_RUN_DIR}"/*/; do
        [[ -d "\$d" ]] && rm -rf "\$d" && CLEANED=\$((CLEANED + 1))
    done
fi
# Remove old repo copy
[[ -d "${REMOTE_REPO_DIR}" ]] && rm -rf "${REMOTE_REPO_DIR}" && CLEANED=\$((CLEANED + 1))
# Remove stale tarballs
rm -f /tmp/scrna-repo-upload.tar.gz /home/${SSH_USER}/scrna-repo.tar /home/${SSH_USER}/scrna-scripts.tar 2>/dev/null
echo "PRE_CLEANED=\$CLEANED"
PRECLEAN

    log_info "Pre-run cleanup complete."

    run_scp "$TARBALL_LOCAL" "${SSH_TARGET}:/tmp/scrna-repo-upload.tar.gz"
    rm -f "$TARBALL_LOCAL"

    run_ssh bash -s <<REMOTE_EXTRACT
set -euo pipefail
rm -rf "$REMOTE_REPO_DIR"
cd /tmp
tar -xzf scrna-repo-upload.tar.gz
if [[ -d "/tmp/$REPO_BASENAME" ]]; then
    mv "/tmp/$REPO_BASENAME" "$REMOTE_REPO_DIR"
else
    FOUND=\$(find /tmp -maxdepth 1 -type d -name 'scRNA*' | head -1)
    if [[ -n "\$FOUND" ]]; then
        mv "\$FOUND" "$REMOTE_REPO_DIR"
    else
        echo "ERROR: Could not find extracted repo directory" >&2
        exit 1
    fi
fi
rm -f /tmp/scrna-repo-upload.tar.gz
echo "REPO_EXTRACTED"
REMOTE_EXTRACT

    log_info "Repository copied to server at $REMOTE_REPO_DIR"

    ########################################################################
    # Run pipeline on server via SSH
    ########################################################################
    log_info "Running pipeline on server (this may take a while)..."
    log_info "  Expected: PBMC 1K ~3 min, PBMC 10K ~25 min"

    DRIVER_START=$(date +%s)

    run_ssh_tty bash -c "'
export THREADS=\"${THREADS}\"
export RUN_QC=\"${RUN_QC}\"
export WRITE_H5AD=\"${WRITE_H5AD}\"
export RUN_ID=\"${RUN_ID}\"
export PISCEM_INDEX_DIR=\"${PISCEM_INDEX_DIR}\"
export T2G_PATH=\"${T2G_PATH}\"
export FASTQ_BASE_DIR=\"${FASTQ_BASE_DIR}\"
export SERVER_RUN_DIR=\"${SERVER_RUN_DIR}\"
export PIPELINE_SUDO_PASS=\"${SSH_PASSWORD}\"
export SSH_USER=\"${SSH_USER}\"
export SERVER_HOST=\"${SERVER_HOST}\"

cd ${REMOTE_REPO_DIR}
bash scripts/e2e_onserver_pbmc.sh ${DATASET} --run
'"
    RUN_EXIT=$?

    DRIVER_END=$(date +%s)
    DRIVER_SECS=$(( DRIVER_END - DRIVER_START ))

    if [[ $RUN_EXIT -ne 0 ]]; then
        log_error "Pipeline exited with code $RUN_EXIT after ${DRIVER_SECS}s."
        log_error "Check server logs at: ${SERVER_RUN_DIR}/${RUN_ID}/"
        exit $RUN_EXIT
    fi

    log_info "Pipeline completed in ${DRIVER_SECS}s ($(fmt_secs $DRIVER_SECS) min)"

    ########################################################################
    # Download results
    ########################################################################
    if [[ "${DOWNLOAD_RESULTS}" -eq 1 ]]; then
        log_info "Downloading results from server..."

        LOCAL_RUN_DIR="${LOCAL_RESULTS_DIR}/${RUN_ID}"
        REMOTE_RUN_DIR="${SERVER_RUN_DIR}/${RUN_ID}"
        mkdir -p "$LOCAL_RUN_DIR/logs"

        # Download metadata & timing
        log_info "  Downloading metadata..."
        run_scp "${SSH_TARGET}:${REMOTE_RUN_DIR}/timing_summary.txt" \
            "$LOCAL_RUN_DIR/" 2>/dev/null || true
        run_scp "${SSH_TARGET}:${REMOTE_RUN_DIR}/run.env" \
            "$LOCAL_RUN_DIR/" 2>/dev/null || true

        # Download log files
        log_info "  Downloading log files..."
        for logfile in piscem_map.log alevin_gpl.log alevin_collate.log alevin_quant.log; do
            run_scp "${SSH_TARGET}:${REMOTE_RUN_DIR}/${logfile}" \
                "$LOCAL_RUN_DIR/logs/" 2>/dev/null || true
        done

        # Download full alevin_output/ (matches serverless output structure)
        log_info "  Downloading alevin output (full)..."
        mkdir -p "$LOCAL_RUN_DIR/alevin_output"
        run_scp -r "${SSH_TARGET}:${REMOTE_RUN_DIR}/alevin_output/" \
            "$LOCAL_RUN_DIR/" 2>/dev/null || true

        # Download piscem mapping output into combined/ (matches serverless layout)
        log_info "  Downloading piscem mapping output..."
        mkdir -p "$LOCAL_RUN_DIR/combined"
        run_scp "${SSH_TARGET}:${REMOTE_RUN_DIR}/piscem_output/map_output/map.rad" \
            "$LOCAL_RUN_DIR/combined/" 2>/dev/null || true
        run_scp "${SSH_TARGET}:${REMOTE_RUN_DIR}/piscem_output/map_output/unmapped_bc_count.bin" \
            "$LOCAL_RUN_DIR/combined/" 2>/dev/null || true

        # Download QC analysis if it exists
        if [[ "${RUN_QC:-0}" == "1" ]]; then
            log_info "  Downloading QC analysis..."
            mkdir -p "$LOCAL_RUN_DIR/analysis"
            run_scp -r "${SSH_TARGET}:${REMOTE_RUN_DIR}/analysis/" \
                "$LOCAL_RUN_DIR/" 2>/dev/null || true
        fi

        log_info "  Download complete."

        # Verify download
        DOWNLOAD_OK=1
        if [[ ! -f "$LOCAL_RUN_DIR/timing_summary.txt" ]]; then
            log_warn "Download may be incomplete: timing_summary.txt missing"
            DOWNLOAD_OK=0
        fi

        QUANT_LOCAL=$(find "$LOCAL_RUN_DIR" -name 'quants_mat.mtx' -o -name 'quants_mat.mtx.gz' 2>/dev/null | head -1)
        if [[ -n "$QUANT_LOCAL" ]]; then
            log_info "Quant matrix found: $QUANT_LOCAL"
        else
            log_warn "quants_mat.mtx not found in download"
            DOWNLOAD_OK=0
        fi

        if [[ -f "$LOCAL_RUN_DIR/combined/map.rad" ]]; then
            log_info "Combined map.rad found"
        else
            log_warn "combined/map.rad not found in download"
        fi

        if [[ "${RUN_QC:-0}" == "1" ]]; then
            QC_FILES=$(find "$LOCAL_RUN_DIR" -name '*.png' 2>/dev/null | wc -l)
            if [[ $QC_FILES -gt 0 ]]; then
                log_info "QC plots found: $QC_FILES PNG files"
            else
                log_warn "No QC plots (*.png) found in download"
            fi
        fi

        log_info "Results downloaded to: $(cd "$LOCAL_RUN_DIR" && pwd)"
        log_info "--- Downloaded files ---"
        find "$LOCAL_RUN_DIR" -type f -printf "  %p (%s bytes)\n" 2>/dev/null || \
            find "$LOCAL_RUN_DIR" -type f | while read -r f; do log_info "  $f"; done

        if [[ -f "$LOCAL_RUN_DIR/timing_summary.txt" ]]; then
            log_info ""
            log_info "=== TIMING SUMMARY ==="
            cat "$LOCAL_RUN_DIR/timing_summary.txt" >&2
        fi

        ####################################################################
        # Clean up server (after confirmed download)
        ####################################################################
        if [[ $DOWNLOAD_OK -eq 1 ]]; then
            log_info "Cleaning up server (run dir + repo copy; FASTQs kept cached)..."

            run_ssh bash -s <<CLEANUP_SCRIPT
set -euo pipefail
echo "=== Server Cleanup ==="

if [[ -d "${REMOTE_RUN_DIR}" ]]; then
    echo "Removing run directory: ${REMOTE_RUN_DIR}"
    rm -rf "${REMOTE_RUN_DIR}"
fi

if [[ -d "${REMOTE_REPO_DIR}" ]]; then
    echo "Removing repo copy: ${REMOTE_REPO_DIR}"
    rm -rf "${REMOTE_REPO_DIR}"
fi

echo "FASTQs kept cached at: ${FASTQ_BASE_DIR}/"
echo "Server cleanup complete."
CLEANUP_SCRIPT

            log_info "Server cleanup complete (FASTQs cached for next run)."
        else
            log_warn "Download may be incomplete — skipping server cleanup."
            log_warn "Server files remain at: ${REMOTE_RUN_DIR}"
            log_warn "Clean up manually when ready."
        fi
    else
        log_info "Skipping result download (DOWNLOAD_RESULTS=0)"
        log_info "Results are on server at: ${SERVER_RUN_DIR}/${RUN_ID}/"
    fi

    log_info "======== Driver mode complete ========"
    log_info "Local results: $(cd "${LOCAL_RESULTS_DIR}/${RUN_ID}" 2>/dev/null && pwd || echo "${LOCAL_RESULTS_DIR}/${RUN_ID}")"
    exit 0
fi

################################################################################
################################################################################
##                                                                            ##
##                          DRY-RUN MODE                                      ##
##                                                                            ##
################################################################################
################################################################################

if [[ $DRY_RUN_MODE -eq 1 ]]; then

    log_info "======== E2E On-Server scRNA Pipeline (DRY-RUN) ========"
    log_info "Dataset: $DATASET"

    ERRORS=0

    # Check credentials
    if [[ -z "$SERVER_HOST" || -z "$SSH_USER" ]]; then
        log_error "SERVER_HOST and SSH_USER are not set."
        log_error "Set them via .env file or environment variables."
        ERRORS=$((ERRORS + 1))
    else
        log_info "  [OK] Server: ${SSH_USER}@${SERVER_HOST}"
    fi

    # Set up SSH and test connectivity
    if [[ $ERRORS -eq 0 ]]; then
        setup_ssh_keys
        log_info "Testing SSH connection..."
        if run_ssh "echo ok" >/dev/null 2>&1; then
            log_info "  [OK] SSH connection to server"
        else
            log_error "  [FAIL] Cannot SSH into server"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # All remaining checks run ON THE SERVER via SSH
    if [[ $ERRORS -eq 0 ]]; then
        REMOTE_CHECK=$(run_ssh bash -s <<DRYRUN_SCRIPT
set -euo pipefail
ERRORS=0

echo "=== Tool checks ==="
for tool in tar curl gzip; do
    if command -v "\$tool" >/dev/null 2>&1; then
        echo "[OK] \$tool found: \$(command -v \$tool)"
    else
        echo "[ERROR] \$tool not found"
        ERRORS=\$((ERRORS + 1))
    fi
done

for tool in piscem alevin-fry radtk; do
    if command -v "\$tool" >/dev/null 2>&1; then
        echo "[OK] \$tool: \$(\$tool --version 2>/dev/null || echo 'version unknown')"
    else
        echo "[WARN] \$tool not installed (will be installed in run mode)"
    fi
done

echo "=== Reference checks ==="
if [[ -d "${PISCEM_INDEX_DIR}" ]]; then
    echo "[OK] Piscem index directory: ${PISCEM_INDEX_DIR}"
else
    echo "[ERROR] Piscem index directory missing: ${PISCEM_INDEX_DIR}"
    ERRORS=\$((ERRORS + 1))
fi

if [[ -f "${T2G_PATH}" ]]; then
    echo "[OK] t2g.tsv: ${T2G_PATH}"
else
    echo "[ERROR] t2g.tsv missing: ${T2G_PATH}"
    ERRORS=\$((ERRORS + 1))
fi

echo "=== FASTQ checks ==="
FASTQ_DIR="${FASTQ_BASE_DIR}/${FASTQ_SUBDIRS[$DATASET]}/${FASTQ_DIR_NAMES[$DATASET]}"
if [[ -d "\$FASTQ_DIR" ]]; then
    R2_COUNT=\$(find "\$FASTQ_DIR" -name '*_R2_*.fastq.gz' 2>/dev/null | wc -l)
    echo "[OK] FASTQ directory: \$FASTQ_DIR (\${R2_COUNT} R2 files)"
else
    echo "[WARN] FASTQs not present at \$FASTQ_DIR (will be downloaded in run mode)"
fi

echo "=== Disk space ==="
AVAIL_MB=\$(df -m /home 2>/dev/null | awk 'NR==2{print \$4}' || echo 0)
echo "AVAIL_MB=\$AVAIL_MB"
echo "Disk space available on /home: \${AVAIL_MB} MB"

echo "=== Server info ==="
echo "Hostname: \$(hostname)"
echo "CPU cores: \$(nproc 2>/dev/null || echo unknown)"
echo "RAM: \$(free -g 2>/dev/null | awk '/^Mem:/{print \$2}' || echo unknown) GB"

echo "REMOTE_ERRORS=\$ERRORS"
DRYRUN_SCRIPT
        )

        echo "$REMOTE_CHECK" | while IFS= read -r line; do
            case "$line" in
                *"[OK]"*)   log_info "  $line" ;;
                *"[ERROR]"*) log_error "  $line" ;;
                *"[WARN]"*) log_warn "  $line" ;;
                AVAIL_MB=*) ;;
                REMOTE_ERRORS=*) ;;
                *)          log_info "  $line" ;;
            esac
        done

        REMOTE_ERRORS=$(echo "$REMOTE_CHECK" | grep '^REMOTE_ERRORS=' | cut -d= -f2)
        ERRORS=$((ERRORS + ${REMOTE_ERRORS:-0}))

        AVAIL_MB=$(echo "$REMOTE_CHECK" | grep '^AVAIL_MB=' | cut -d= -f2)
        FASTQ_IS_CACHED=$(echo "$REMOTE_CHECK" | grep -q '\[OK\] FASTQ directory' && echo yes || echo no)
        if [[ "$DATASET" == "pbmc10k" ]]; then
            if [[ "$FASTQ_IS_CACHED" == "yes" ]]; then
                REQUIRED_MB=20000
            else
                REQUIRED_MB=60000
            fi
        else
            if [[ "$FASTQ_IS_CACHED" == "yes" ]]; then
                REQUIRED_MB=5000
            else
                REQUIRED_MB=10000
            fi
        fi
        if [[ ${AVAIL_MB:-0} -lt $REQUIRED_MB ]]; then
            log_warn "  Low disk space: ${AVAIL_MB:-0} MB available, ${REQUIRED_MB} MB recommended (FASTQs cached: ${FASTQ_IS_CACHED})"
        fi
    fi

    if [[ $ERRORS -gt 0 ]]; then
        die "Dry-run found $ERRORS error(s). Fix them before running."
    fi

    log_info "Dry-run passed. Ready to run."
    exit 0
fi

################################################################################
################################################################################
##                                                                            ##
##                          RUN MODE (on the server)                          ##
##                                                                            ##
################################################################################
################################################################################

log_info "======== E2E On-Server scRNA Pipeline (RUN MODE) ========"
log_info "Dataset: $DATASET"
log_info "Run ID: $RUN_ID"

################################################################################
# Sudo wrapper (uses password from driver if available)
################################################################################

_sudo() {
    if [[ -n "${PIPELINE_SUDO_PASS:-}" ]]; then
        echo "$PIPELINE_SUDO_PASS" | sudo -S "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}

################################################################################
# Pre-flight: disk space check
################################################################################

log_info "Checking disk space..."
AVAIL_MB=$(df -m /home 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
FASTQ_SUBDIR="${FASTQ_SUBDIRS[$DATASET]}"
FASTQ_DIR_NAME="${FASTQ_DIR_NAMES[$DATASET]}"
FASTQ_CHECK_PATH="${FASTQ_BASE_DIR}/${FASTQ_SUBDIR}/${FASTQ_DIR_NAME}"
if [[ "$DATASET" == "pbmc10k" ]]; then
    if [[ -d "$FASTQ_CHECK_PATH" ]]; then
        REQUIRED_MB=20000
    else
        REQUIRED_MB=60000
    fi
else
    if [[ -d "$FASTQ_CHECK_PATH" ]]; then
        REQUIRED_MB=5000
    else
        REQUIRED_MB=10000
    fi
fi
log_info "  Available: ${AVAIL_MB} MB, Required: ${REQUIRED_MB} MB (FASTQs cached: $([[ -d "$FASTQ_CHECK_PATH" ]] && echo yes || echo no))"
if [[ "${AVAIL_MB:-0}" -lt "$REQUIRED_MB" ]]; then
    die "Insufficient disk space: ${AVAIL_MB} MB available, need ${REQUIRED_MB} MB. Clean up and retry."
fi

################################################################################
# Auto-detect thread count
################################################################################

if [[ -z "$THREADS" ]]; then
    THREADS=$(nproc 2>/dev/null || echo 16)
fi
log_info "Threads: $THREADS"

################################################################################
# Setup run directory
################################################################################

RUN_DIR="${SERVER_RUN_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"/{piscem_output,alevin_output,analysis}
log_info "Run directory: $RUN_DIR"

################################################################################
# Timing arrays
################################################################################

declare -A STEP_TIMES
declare -a STEP_ORDER

record_time() {
    local name="$1" secs="$2"
    STEP_TIMES["$name"]="$secs"
    STEP_ORDER+=("$name")
}

################################################################################
# Step 0: Bootstrap Tools
################################################################################

log_info "Step 0: Checking and installing tools..."

STEP0_START=$(date +%s)

wait_for_dpkg_lock() {
    for _w in $(seq 1 30); do
        if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
           ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            return 0
        fi
        log_info "Waiting for dpkg/apt lock (attempt $_w/30)..."
        sleep 10
    done
    log_warn "dpkg lock did not release after 5 minutes — proceeding anyway."
}

APT_UPDATED=0
ensure_apt_updated() {
    if [[ $APT_UPDATED -eq 0 ]]; then
        wait_for_dpkg_lock
        _sudo apt-get update -qq
        APT_UPDATED=1
    fi
}

for tool in curl wget tar gzip bc jq; do
    if ! need_cmd "$tool"; then
        log_info "Installing $tool..."
        ensure_apt_updated
        _sudo apt-get install -y -qq "$tool" >/dev/null 2>&1
    fi
done

if ! need_cmd piscem; then
    log_info "Installing piscem v0.10.3..."
    PISCEM_URL="https://github.com/COMBINE-lab/piscem/releases/download/v0.10.3/piscem-x86_64-unknown-linux-gnu.tar.gz"
    cd /tmp
    curl -fsSL "$PISCEM_URL" -o piscem.tar.gz
    tar -xzf piscem.tar.gz
    _sudo mv piscem-x86_64-unknown-linux-gnu/piscem /usr/local/bin/
    _sudo chmod +x /usr/local/bin/piscem
    rm -rf piscem.tar.gz piscem-x86_64-unknown-linux-gnu
    cd - >/dev/null
    log_info "piscem installed: $(piscem --version 2>&1 | head -1)"
fi

if ! need_cmd alevin-fry; then
    log_info "Installing alevin-fry v0.9.0..."
    AFRY_URL="https://github.com/COMBINE-lab/alevin-fry/releases/download/v0.9.0/alevin-fry-x86_64-unknown-linux-gnu.tar.xz"
    cd /tmp
    curl -fsSL "$AFRY_URL" -o alevin-fry.tar.xz
    tar -xf alevin-fry.tar.xz
    _sudo mv alevin-fry-x86_64-unknown-linux-gnu/alevin-fry /usr/local/bin/
    _sudo chmod +x /usr/local/bin/alevin-fry
    rm -rf alevin-fry.tar.xz alevin-fry-x86_64-unknown-linux-gnu
    cd - >/dev/null
    log_info "alevin-fry installed: $(alevin-fry --version 2>&1 | head -1)"
fi

if ! need_cmd radtk; then
    log_info "Installing radtk v0.1.0..."
    RADTK_URL="https://github.com/COMBINE-lab/radtk/releases/download/v0.1.0/radtk-x86_64-unknown-linux-gnu.tar.xz"
    cd /tmp
    curl -fsSL "$RADTK_URL" -o radtk.tar.xz
    tar -xf radtk.tar.xz
    _sudo mv radtk-x86_64-unknown-linux-gnu/radtk /usr/local/bin/
    _sudo chmod +x /usr/local/bin/radtk
    rm -rf radtk.tar.xz radtk-x86_64-unknown-linux-gnu
    cd - >/dev/null
    log_info "radtk installed: $(radtk --version 2>&1 | head -1)"
fi

log_info "Tool versions:"
log_info "  piscem:     $(piscem --version 2>&1 | head -1)"
log_info "  alevin-fry: $(alevin-fry --version 2>&1 | head -1)"
log_info "  radtk:      $(radtk --version 2>&1 | head -1)"

STEP0_END=$(date +%s)
log_info "Step 0 completed in $(( STEP0_END - STEP0_START ))s"

################################################################################
# Verify reference files
# SAFETY: These are read-only. The script must NEVER modify or delete them.
#   /home/nnasam/test/test-alevin/index_output_transcriptome
#   /home/nnasam/test/test-alevin/reference
################################################################################

log_info "Verifying reference files (read-only)..."

if [[ ! -d "$PISCEM_INDEX_DIR" ]]; then
    die "Piscem index directory not found: $PISCEM_INDEX_DIR"
fi

PISCEM_INDEX_PREFIX=""
for f in "$PISCEM_INDEX_DIR"/*.sshash; do
    if [[ -f "$f" ]]; then
        PISCEM_INDEX_PREFIX="${f%.sshash}"
        break
    fi
done
if [[ -z "$PISCEM_INDEX_PREFIX" ]]; then
    die "Cannot find .sshash file in $PISCEM_INDEX_DIR"
fi
log_info "Piscem index prefix: $PISCEM_INDEX_PREFIX"

if [[ ! -f "$T2G_PATH" ]]; then
    die "Transcript-to-gene mapping not found: $T2G_PATH"
fi
log_info "t2g.tsv: $T2G_PATH"

################################################################################
# Step 1: Locate / validate / download FASTQs
#
# FASTQ download time is NOT included in the pipeline benchmark total.
# The paper assumes pre-staged FASTQs; download time is reported separately.
################################################################################

log_info "Step 1: Locating FASTQ files..."

FASTQ_SUBDIR="${FASTQ_SUBDIRS[$DATASET]}"
FASTQ_DIR_NAME="${FASTQ_DIR_NAMES[$DATASET]}"
FASTQ_DIR="${FASTQ_BASE_DIR}/${FASTQ_SUBDIR}/${FASTQ_DIR_NAME}"
FASTQ_DOWNLOAD_SECS=0
FASTQ_STATUS="cached"

_validate_fastqs() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        return 1
    fi
    local r1_count r2_count
    r1_count=$(find "$dir" -name '*_R1_*.fastq.gz' 2>/dev/null | wc -l)
    r2_count=$(find "$dir" -name '*_R2_*.fastq.gz' 2>/dev/null | wc -l)
    if [[ $r1_count -eq 0 || $r2_count -eq 0 ]]; then
        log_warn "  Missing R1 or R2 files (R1=${r1_count}, R2=${r2_count})"
        return 1
    fi
    if [[ $r1_count -ne $r2_count ]]; then
        log_warn "  Mismatched R1/R2 counts (R1=${r1_count}, R2=${r2_count})"
        return 1
    fi
    log_info "  Checking gzip integrity of ${r1_count} R1 + ${r2_count} R2 files..."
    local bad=0
    while IFS= read -r gz; do
        if ! gzip -t "$gz" 2>/dev/null; then
            log_warn "  Corrupt file: $(basename "$gz")"
            bad=1
        fi
    done < <(find "$dir" -name '*.fastq.gz' | sort)
    if [[ $bad -ne 0 ]]; then
        return 1
    fi
    log_info "  FASTQ integrity check passed (${r2_count} R2 files, all gzip-valid)"
    return 0
}

_download_fastqs() {
    local url="${FASTQ_TAR_URLS[$DATASET]}"
    local parent="${FASTQ_BASE_DIR}/${FASTQ_SUBDIR}"
    mkdir -p "$parent"
    log_info "  Downloading from: $url"
    if [[ "$DATASET" == "pbmc10k" ]]; then
        log_info "  (PBMC 10K is ~44 GB — this will take a while)"
    fi
    curl -fSL "$url" | tar -xf - -C "$parent"
    if [[ ! -d "$FASTQ_DIR" ]]; then
        local found
        found=$(find "$parent" -maxdepth 1 -type d -name '*fastqs*' | head -1)
        if [[ -n "$found" && "$found" != "$FASTQ_DIR" ]]; then
            mv "$found" "$FASTQ_DIR"
        else
            die "FASTQ download/extraction failed. Expected: $FASTQ_DIR"
        fi
    fi
}

if [[ -d "$FASTQ_DIR" ]]; then
    log_info "FASTQ directory found at $FASTQ_DIR — validating..."
    if _validate_fastqs "$FASTQ_DIR"; then
        log_info "Using cached FASTQs (no download needed)"
        FASTQ_STATUS="cached"
    else
        log_warn "Cached FASTQs are incomplete or corrupt — re-downloading..."
        rm -rf "$FASTQ_DIR"
        DL_START=$(date +%s)
        _download_fastqs
        DL_END=$(date +%s)
        FASTQ_DOWNLOAD_SECS=$(( DL_END - DL_START ))
        FASTQ_STATUS="redownloaded"
        if ! _validate_fastqs "$FASTQ_DIR"; then
            die "FASTQs still invalid after re-download"
        fi
        log_info "Re-downloaded and validated FASTQs in ${FASTQ_DOWNLOAD_SECS}s"
    fi
else
    log_info "FASTQs not found — downloading..."
    DL_START=$(date +%s)
    _download_fastqs
    DL_END=$(date +%s)
    FASTQ_DOWNLOAD_SECS=$(( DL_END - DL_START ))
    FASTQ_STATUS="downloaded"
    if ! _validate_fastqs "$FASTQ_DIR"; then
        die "Downloaded FASTQs failed validation"
    fi
    log_info "Downloaded and validated FASTQs in ${FASTQ_DOWNLOAD_SECS}s"
fi

log_info "Step 1 complete (FASTQ status: $FASTQ_STATUS)"

################################################################################
# Collect FASTQ file lists (R1 and R2, skip I1 index files)
################################################################################

R1_FILES=()
R2_FILES=()

while IFS= read -r f; do
    R1_FILES+=("$f")
done < <(find "$FASTQ_DIR" -name '*_R1_*.fastq.gz' | sort)

while IFS= read -r f; do
    R2_FILES+=("$f")
done < <(find "$FASTQ_DIR" -name '*_R2_*.fastq.gz' | sort)

if [[ ${#R1_FILES[@]} -eq 0 || ${#R2_FILES[@]} -eq 0 ]]; then
    die "No R1 or R2 FASTQ files found in $FASTQ_DIR"
fi

if [[ ${#R1_FILES[@]} -ne ${#R2_FILES[@]} ]]; then
    die "Mismatched R1/R2 file counts: ${#R1_FILES[@]} R1 vs ${#R2_FILES[@]} R2"
fi

log_info "FASTQ pairs: ${#R1_FILES[@]} lanes"
for i in "${!R1_FILES[@]}"; do
    log_info "  Lane $((i+1)): $(basename "${R1_FILES[$i]}") + $(basename "${R2_FILES[$i]}")"
done

R1_COMMA=$(IFS=,; echo "${R1_FILES[*]}")
R2_COMMA=$(IFS=,; echo "${R2_FILES[*]}")

################################################################################
# Step 2: Piscem Map
################################################################################

log_info "Step 2: Running piscem map-sc..."
log_info "  Index: $PISCEM_INDEX_PREFIX"
log_info "  Threads: $THREADS"
log_info "  Output: $RUN_DIR/piscem_output"

PISCEM_OUTPUT="$RUN_DIR/piscem_output"

STEP2_START=$(date +%s)

piscem map-sc \
    -i "$PISCEM_INDEX_PREFIX" \
    -g chromium_v3 \
    -1 "$R1_COMMA" \
    -2 "$R2_COMMA" \
    -t "$THREADS" \
    -o "$PISCEM_OUTPUT/map_output" \
    2>&1 | tee "$RUN_DIR/piscem_map.log" >&2

STEP2_END=$(date +%s)
STEP2_SECS=$(( STEP2_END - STEP2_START ))
record_time "Piscem Map" "$STEP2_SECS"
log_info "Step 2 completed in ${STEP2_SECS}s ($(fmt_secs $STEP2_SECS) min)"

if [[ ! -f "$PISCEM_OUTPUT/map_output/map.rad" ]]; then
    die "piscem map failed: map.rad not found in $PISCEM_OUTPUT/map_output/"
fi

MAP_RAD_SIZE=$(stat --format=%s "$PISCEM_OUTPUT/map_output/map.rad" 2>/dev/null || \
               stat -f%z "$PISCEM_OUTPUT/map_output/map.rad" 2>/dev/null || echo 0)
log_info "map.rad size: $(( MAP_RAD_SIZE / 1048576 )) MB"

################################################################################
# Step 3: Alevin-fry generate-permit-list
################################################################################

log_info "Step 3: Running alevin-fry generate-permit-list..."

ALEVIN_OUTPUT="$RUN_DIR/alevin_output"

STEP3_START=$(date +%s)

alevin-fry generate-permit-list \
    -d fw \
    -k \
    -i "$PISCEM_OUTPUT/map_output" \
    -o "$ALEVIN_OUTPUT" \
    2>&1 | tee "$RUN_DIR/alevin_gpl.log" >&2

STEP3_END=$(date +%s)
STEP3_SECS=$(( STEP3_END - STEP3_START ))
record_time "Alevin-fry generate-permit-list" "$STEP3_SECS"
log_info "Step 3 completed in ${STEP3_SECS}s ($(fmt_secs $STEP3_SECS) min)"

################################################################################
# Step 4: Alevin-fry collate
################################################################################

log_info "Step 4: Running alevin-fry collate..."

STEP4_START=$(date +%s)

alevin-fry collate \
    -t "$THREADS" \
    -i "$ALEVIN_OUTPUT" \
    -r "$PISCEM_OUTPUT/map_output" \
    2>&1 | tee "$RUN_DIR/alevin_collate.log" >&2

STEP4_END=$(date +%s)
STEP4_SECS=$(( STEP4_END - STEP4_START ))
record_time "Alevin-fry collate" "$STEP4_SECS"
log_info "Step 4 completed in ${STEP4_SECS}s ($(fmt_secs $STEP4_SECS) min)"

################################################################################
# Step 5: Alevin-fry quant
################################################################################

log_info "Step 5: Running alevin-fry quant..."

STEP5_START=$(date +%s)

alevin-fry quant \
    -t "$THREADS" \
    -i "$ALEVIN_OUTPUT" \
    -o "$ALEVIN_OUTPUT" \
    --tg-map "$T2G_PATH" \
    --resolution cr-like \
    --use-mtx \
    2>&1 | tee "$RUN_DIR/alevin_quant.log" >&2

STEP5_END=$(date +%s)
STEP5_SECS=$(( STEP5_END - STEP5_START ))
record_time "Alevin-fry quant" "$STEP5_SECS"
log_info "Step 5 completed in ${STEP5_SECS}s ($(fmt_secs $STEP5_SECS) min)"

if [[ ! -f "$ALEVIN_OUTPUT/quants_mat.mtx" && ! -f "$ALEVIN_OUTPUT/alevin/quants_mat.mtx" ]]; then
    log_warn "quants_mat.mtx not found in expected location. Checking subdirectories..."
    QUANT_MTX=$(find "$ALEVIN_OUTPUT" -name 'quants_mat.mtx' -o -name 'quants_mat.mtx.gz' | head -1)
    if [[ -z "$QUANT_MTX" ]]; then
        die "alevin-fry quant failed: cannot find quants_mat.mtx"
    fi
    log_info "Found quant matrix: $QUANT_MTX"
fi

################################################################################
# Step 6: Optional QC Analysis (UMAP + violin plots)
################################################################################

STEP6_SECS=0
if [[ "${RUN_QC:-0}" == "1" ]]; then
    log_info "Step 6: Running QC analysis (UMAP + violin plots)..."

    STEP6_START=$(date +%s)

    if ! need_cmd python3; then
        log_info "Installing python3 for QC..."
        wait_for_dpkg_lock
        _sudo apt-get update -qq
        _sudo apt-get install -y python3 python3-venv python3-pip
    fi

    QC_DIR="$RUN_DIR/analysis"
    mkdir -p "$QC_DIR/out"

    python3 -m venv "$RUN_DIR/venv_qc"
    # shellcheck disable=SC1091
    source "$RUN_DIR/venv_qc/bin/activate"

    python -m pip install -q --upgrade pip setuptools wheel
    pip install -q numpy pandas scipy matplotlib seaborn anndata scanpy python-igraph leidenalg

    QC_ARGS=("$ALEVIN_OUTPUT" "--outdir" "$QC_DIR/out")
    if [[ "${WRITE_H5AD:-0}" == "1" ]]; then
        QC_ARGS+=("--write-h5ad")
    fi

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if python "$SCRIPT_DIR/qc_onserver.py" "${QC_ARGS[@]}"; then
        log_info "QC analysis complete."
        QC_PLOTS=$(find "$QC_DIR/out" -name '*.png' 2>/dev/null | wc -l)
        log_info "QC output: $QC_PLOTS plot(s) in $QC_DIR/out/"
    else
        log_warn "QC analysis failed (non-fatal). Pipeline continues."
    fi

    deactivate 2>/dev/null || true

    STEP6_END=$(date +%s)
    STEP6_SECS=$(( STEP6_END - STEP6_START ))
    record_time "QC Analysis" "$STEP6_SECS"
    log_info "Step 6 completed in ${STEP6_SECS}s ($(fmt_secs $STEP6_SECS) min)"
else
    log_info "Step 6: Skipping QC (RUN_QC=0)."
    record_time "QC Analysis" "SKIPPED"
fi

################################################################################
# Clean up venv (save disk space before download)
################################################################################

if [[ -d "$RUN_DIR/venv_qc" ]]; then
    rm -rf "$RUN_DIR/venv_qc"
fi

################################################################################
# Save Run Metadata
################################################################################

log_info "Saving run metadata..."

DATASET_UPPER=$(echo "$DATASET" | tr '[:lower:]' '[:upper:]')

cat > "$RUN_DIR/run.env" <<EOF
RUN_ID=$RUN_ID
DATASET=$DATASET
THREADS=$THREADS
SERVER=$(hostname)
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'unknown')
CPU_LOGICAL_CORES=$(nproc 2>/dev/null || echo 'unknown')
RAM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo 'unknown')
PISCEM_VERSION=$(piscem --version 2>&1 | head -1)
ALEVIN_FRY_VERSION=$(alevin-fry --version 2>&1 | head -1)
RADTK_VERSION=$(radtk --version 2>&1 | head -1 || echo 'unknown')
PISCEM_INDEX_DIR=$PISCEM_INDEX_DIR
T2G_PATH=$T2G_PATH
FASTQ_DIR=$FASTQ_DIR
RUN_DIR=$RUN_DIR
RUN_QC=$RUN_QC
WRITE_H5AD=$WRITE_H5AD
EOF

log_info "Run metadata saved to $RUN_DIR/run.env"

################################################################################
# Timing Summary
################################################################################

TOTAL_SECS=0
for key in "${STEP_ORDER[@]}"; do
    val="${STEP_TIMES[$key]}"
    if [[ "$val" != "SKIPPED" ]]; then
        TOTAL_SECS=$(( TOTAL_SECS + val ))
    fi
done

{
    echo ""
    echo "========== ON-SERVER TIMING SUMMARY (${DATASET_UPPER}) =========="
    printf "%-42s %s\n" "Task" "Time (min)"
    echo "------------------------------------------------------------"
    for key in "${STEP_ORDER[@]}"; do
        val="${STEP_TIMES[$key]}"
        if [[ "$val" == "SKIPPED" ]]; then
            printf "%-42s %s\n" "$key" "SKIPPED"
        else
            printf "%-42s %s\n" "$key" "$(fmt_secs "$val")"
        fi
    done
    echo "------------------------------------------------------------"
    printf "%-42s %s\n" "Total On-Server Execution" "$(fmt_secs "$TOTAL_SECS")"
    echo "============================================================"
    echo ""
    if [[ "$FASTQ_STATUS" == "downloaded" ]]; then
        printf "%-42s %s\n" "FASTQ download (not in total):" "$(fmt_secs "$FASTQ_DOWNLOAD_SECS") min"
        echo "  (outside the scope of the paper benchmark; pre-staged FASTQs assumed)"
        echo ""
        echo "FASTQs: downloaded fresh"
    elif [[ "$FASTQ_STATUS" == "redownloaded" ]]; then
        printf "%-42s %s\n" "FASTQ re-download (not in total):" "$(fmt_secs "$FASTQ_DOWNLOAD_SECS") min"
        echo "  (outside the scope of the paper benchmark; pre-staged FASTQs assumed)"
        echo ""
        echo "FASTQs: re-downloaded (cached copy was corrupt)"
    else
        echo "FASTQs: cached (verified, no download needed)"
    fi
    echo ""
} | tee "$RUN_DIR/timing_summary.txt" >&2

################################################################################
# Summary
################################################################################

log_info "======== Pipeline Complete ========"
log_info "Run ID: $RUN_ID"
log_info "Dataset: $DATASET"
log_info "Output directory: $RUN_DIR"
log_info "Quantification output: $ALEVIN_OUTPUT"

if [[ "${RUN_QC:-0}" == "1" ]]; then
    log_info "QC plots: $RUN_DIR/analysis/out/"
    if [[ "${WRITE_H5AD:-0}" == "1" ]]; then
        log_info "H5AD file: $RUN_DIR/analysis/out/pbmc_adata.h5ad"
    fi
fi

log_info "Timing summary: $RUN_DIR/timing_summary.txt"
log_info "Run metadata: $RUN_DIR/run.env"

exit 0
