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
# ENVIRONMENT VARIABLES:
#   SERVER_HOST              SSH target (default: chrisb10@128.208.252.232)
#   SSH_USER                 SSH user (default: chrisb10)
#   THREADS                  CPU threads for tools (default: nproc on server)
#   RUN_QC                   Run QC analysis after quant (default: 0)
#   WRITE_H5AD               Save h5ad from QC (default: 0, requires RUN_QC=1)
#   DOWNLOAD_RESULTS         Download results to local machine (default: 1)
#   LOCAL_RESULTS_DIR         Local directory for results (default: ./onserver_runs)
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

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
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

# Measure a command's wall-clock time in seconds (fractional).
# Usage: elapsed=$(time_cmd some_command args...)
time_cmd() {
    local start end
    start=$(date +%s%N 2>/dev/null || date +%s)
    "$@"
    local rc=$?
    end=$(date +%s%N 2>/dev/null || date +%s)
    if [[ ${#start} -gt 10 ]]; then
        # Nanosecond precision available
        echo "scale=2; ($end - $start) / 1000000000" | bc
    else
        echo $(( end - start ))
    fi
    return $rc
}

# Format seconds to Xm Ys or X.XX min
fmt_secs() {
    local secs="$1"
    # Use bc for fractional division
    if need_cmd bc; then
        printf "%.2f" "$(echo "scale=4; $secs / 60" | bc)"
    else
        echo "$(( secs / 60 ))m $(( secs % 60 ))s"
    fi
}

################################################################################
# Default Configuration
################################################################################

# Server connection
SERVER_HOST="${SERVER_HOST:-chrisb10@128.208.252.232}"
SSH_USER="${SSH_USER:-chrisb10}"

# Execution
THREADS="${THREADS:-}"   # empty = auto-detect via nproc on server
RUN_QC="${RUN_QC:-0}"
WRITE_H5AD="${WRITE_H5AD:-0}"
DOWNLOAD_RESULTS="${DOWNLOAD_RESULTS:-1}"
LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR:-./onserver_runs}"

# Reference paths on server (pre-installed, read-only)
PISCEM_INDEX_DIR="${PISCEM_INDEX_DIR:-/home/nnasam/test/test-alevin/index_output_transcriptome}"
T2G_PATH="${T2G_PATH:-/home/nnasam/test/test-alevin/reference/t2g.tsv}"

# FASTQ base directory on server
FASTQ_BASE_DIR="${FASTQ_BASE_DIR:-/home/chrisb10/datasets/10x}"

# Run output location on server
SERVER_RUN_DIR="${SERVER_RUN_DIR:-/home/chrisb10/onserver_runs}"

# Run ID (auto-generated if empty)
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

# Expected FASTQ directory names after extraction
declare -A FASTQ_DIR_NAMES=(
    [pbmc1k]="pbmc_1k_v3_fastqs"
    [pbmc10k]="pbmc_10k_v3_fastqs"
)

# Subdirectory under FASTQ_BASE_DIR for each dataset
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

Environment variables:
  SERVER_HOST             SSH target (default: chrisb10@128.208.252.232)
  THREADS                 CPU threads (default: auto-detect)
  RUN_QC=1                Enable QC analysis
  WRITE_H5AD=1            Save h5ad from QC
  DOWNLOAD_RESULTS=0      Skip downloading results to local machine

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

    log_info "======== E2E On-Server scRNA Pipeline (DRIVER MODE) ========"
    log_info "Dataset: $DATASET"
    log_info "Run ID: $RUN_ID"
    log_info "Server: $SERVER_HOST"

    ########################################################################
    # Test SSH connectivity
    ########################################################################
    log_info "Testing SSH connectivity to $SERVER_HOST..."
    log_info "You may be prompted for your password."

    if ! ssh -o ConnectTimeout=15 -o BatchMode=no "$SERVER_HOST" "echo SSH_OK" 2>/dev/null; then
        die "Cannot SSH to $SERVER_HOST. Check host, username, and network."
    fi
    log_info "SSH connection verified."

    ########################################################################
    # Copy repo to server
    ########################################################################
    log_info "Copying repository to server..."

    # Create tarball of the repo (excluding .git and large dirs)
    TARBALL_LOCAL=$(mktemp /tmp/scrna-repo-XXXXXX.tar.gz)
    tar -czf "$TARBALL_LOCAL" \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='runs' \
        --exclude='onserver_runs' \
        -C "$(dirname "$(cd "$(dirname "$0")/.." && pwd)")" \
        "$(basename "$(cd "$(dirname "$0")/.." && pwd)")"

    REMOTE_REPO_DIR="/home/${SSH_USER}/scrna-repo"

    scp "$TARBALL_LOCAL" "${SERVER_HOST}:/tmp/scrna-repo-upload.tar.gz"
    rm -f "$TARBALL_LOCAL"

    ssh "$SERVER_HOST" bash -s <<REMOTE_EXTRACT
set -euo pipefail
rm -rf "$REMOTE_REPO_DIR"
cd /tmp
tar -xzf scrna-repo-upload.tar.gz
mv scRNA-serverless "$REMOTE_REPO_DIR"
rm -f /tmp/scrna-repo-upload.tar.gz
echo "REPO_EXTRACTED"
REMOTE_EXTRACT

    log_info "Repository copied to server at $REMOTE_REPO_DIR"

    ########################################################################
    # Run pipeline on server via SSH
    ########################################################################
    log_info "Running pipeline in --run mode on server..."
    log_info "(You may be prompted for your password again.)"

    ssh -t "$SERVER_HOST" bash -c "'
export THREADS=\"${THREADS}\"
export RUN_QC=\"${RUN_QC}\"
export WRITE_H5AD=\"${WRITE_H5AD}\"
export RUN_ID=\"${RUN_ID}\"
export PISCEM_INDEX_DIR=\"${PISCEM_INDEX_DIR}\"
export T2G_PATH=\"${T2G_PATH}\"
export FASTQ_BASE_DIR=\"${FASTQ_BASE_DIR}\"
export SERVER_RUN_DIR=\"${SERVER_RUN_DIR}\"

cd ${REMOTE_REPO_DIR}
bash scripts/e2e_onserver_pbmc.sh ${DATASET} --run
'"
    RUN_EXIT=$?

    if [[ $RUN_EXIT -ne 0 ]]; then
        log_error "Pipeline exited with code $RUN_EXIT."
        exit $RUN_EXIT
    fi

    ########################################################################
    # Download results
    ########################################################################
    if [[ "${DOWNLOAD_RESULTS}" -eq 1 ]]; then
        log_info "Downloading results from server..."

        LOCAL_RUN_DIR="${LOCAL_RESULTS_DIR}/${RUN_ID}"
        mkdir -p "$LOCAL_RUN_DIR"

        # Download timing summary and run.env first
        scp "${SERVER_HOST}:${SERVER_RUN_DIR}/${RUN_ID}/timing_summary.txt" \
            "$LOCAL_RUN_DIR/" 2>/dev/null || true
        scp "${SERVER_HOST}:${SERVER_RUN_DIR}/${RUN_ID}/run.env" \
            "$LOCAL_RUN_DIR/" 2>/dev/null || true

        # Download alevin quant output
        scp -r "${SERVER_HOST}:${SERVER_RUN_DIR}/${RUN_ID}/alevin_output/" \
            "$LOCAL_RUN_DIR/" 2>/dev/null || true

        # Download QC analysis if it exists
        if [[ "${RUN_QC:-0}" == "1" ]]; then
            scp -r "${SERVER_HOST}:${SERVER_RUN_DIR}/${RUN_ID}/analysis/" \
                "$LOCAL_RUN_DIR/" 2>/dev/null || true
        fi

        log_info "Results downloaded to $LOCAL_RUN_DIR"

        if [[ -f "$LOCAL_RUN_DIR/timing_summary.txt" ]]; then
            log_info "=== TIMING SUMMARY ==="
            cat "$LOCAL_RUN_DIR/timing_summary.txt" >&2
        fi
    else
        log_info "Skipping result download (DOWNLOAD_RESULTS=0)"
        log_info "Results are on server at: ${SERVER_RUN_DIR}/${RUN_ID}/"
    fi

    log_info "======== Driver mode complete ========"
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

    # Check tools
    for tool in tar curl gzip; do
        if need_cmd "$tool"; then
            log_info "  [OK] $tool found: $(command -v "$tool")"
        else
            log_error "  [MISSING] $tool not found"
            ERRORS=$((ERRORS + 1))
        fi
    done

    # Check optional tools (will be installed if missing in run mode)
    for tool in piscem alevin-fry radtk; do
        if need_cmd "$tool"; then
            log_info "  [OK] $tool found: $(command -v "$tool") — $($tool --version 2>/dev/null || echo 'version unknown')"
        else
            log_warn "  [MISSING] $tool not installed (will be installed in run mode)"
        fi
    done

    # Check reference files
    if [[ -d "$PISCEM_INDEX_DIR" ]]; then
        log_info "  [OK] Piscem index directory: $PISCEM_INDEX_DIR"
    else
        log_error "  [MISSING] Piscem index directory: $PISCEM_INDEX_DIR"
        ERRORS=$((ERRORS + 1))
    fi

    if [[ -f "$T2G_PATH" ]]; then
        log_info "  [OK] t2g.tsv: $T2G_PATH"
    else
        log_error "  [MISSING] t2g.tsv: $T2G_PATH"
        ERRORS=$((ERRORS + 1))
    fi

    # Check FASTQ directory
    FASTQ_DIR="${FASTQ_BASE_DIR}/${FASTQ_SUBDIRS[$DATASET]}/${FASTQ_DIR_NAMES[$DATASET]}"
    if [[ -d "$FASTQ_DIR" ]]; then
        R2_COUNT=$(find "$FASTQ_DIR" -name '*_R2_*.fastq.gz' 2>/dev/null | wc -l)
        log_info "  [OK] FASTQ directory exists: $FASTQ_DIR ($R2_COUNT R2 files)"
    else
        log_warn "  [MISSING] FASTQs not present at $FASTQ_DIR (will be downloaded in run mode)"
    fi

    # Check disk space
    AVAIL_MB=$(df -m /home 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
    log_info "  Disk space available on /home: ${AVAIL_MB} MB"
    if [[ $AVAIL_MB -lt 20000 ]]; then
        log_warn "  Low disk space on /home. Consider cleaning up."
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

# Wait for any dpkg locks (common on fresh Ubuntu instances)
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
        sudo apt-get update -qq
        APT_UPDATED=1
    fi
}

# Install basic tools if missing
for tool in curl wget tar gzip bc jq; do
    if ! need_cmd "$tool"; then
        log_info "Installing $tool..."
        ensure_apt_updated
        sudo apt-get install -y -qq "$tool" >/dev/null 2>&1
    fi
done

# Install piscem (pre-built binary from GitHub releases)
if ! need_cmd piscem; then
    log_info "Installing piscem v0.10.3..."
    PISCEM_URL="https://github.com/COMBINE-lab/piscem/releases/download/v0.10.3/piscem-x86_64-unknown-linux-gnu.tar.gz"
    cd /tmp
    curl -fsSL "$PISCEM_URL" -o piscem.tar.gz
    tar -xzf piscem.tar.gz
    sudo mv piscem-x86_64-unknown-linux-gnu/piscem /usr/local/bin/
    sudo chmod +x /usr/local/bin/piscem
    rm -rf piscem.tar.gz piscem-x86_64-unknown-linux-gnu
    cd - >/dev/null
    log_info "piscem installed: $(piscem --version 2>&1 | head -1)"
fi

# Install alevin-fry (pre-built binary from GitHub releases)
if ! need_cmd alevin-fry; then
    log_info "Installing alevin-fry v0.9.0..."
    AFRY_URL="https://github.com/COMBINE-lab/alevin-fry/releases/download/v0.9.0/alevin-fry-x86_64-unknown-linux-gnu.tar.xz"
    cd /tmp
    curl -fsSL "$AFRY_URL" -o alevin-fry.tar.xz
    tar -xf alevin-fry.tar.xz
    sudo mv alevin-fry-x86_64-unknown-linux-gnu/alevin-fry /usr/local/bin/
    sudo chmod +x /usr/local/bin/alevin-fry
    rm -rf alevin-fry.tar.xz alevin-fry-x86_64-unknown-linux-gnu
    cd - >/dev/null
    log_info "alevin-fry installed: $(alevin-fry --version 2>&1 | head -1)"
fi

# Install radtk (pre-built binary from GitHub releases)
if ! need_cmd radtk; then
    log_info "Installing radtk v0.1.0..."
    RADTK_URL="https://github.com/COMBINE-lab/radtk/releases/download/v0.1.0/radtk-x86_64-unknown-linux-gnu.tar.xz"
    cd /tmp
    curl -fsSL "$RADTK_URL" -o radtk.tar.xz
    tar -xf radtk.tar.xz
    sudo mv radtk-x86_64-unknown-linux-gnu/radtk /usr/local/bin/
    sudo chmod +x /usr/local/bin/radtk
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
################################################################################

log_info "Verifying reference files..."

if [[ ! -d "$PISCEM_INDEX_DIR" ]]; then
    die "Piscem index directory not found: $PISCEM_INDEX_DIR"
fi

# Find the index prefix (the common prefix for .sshash, .ctab, etc.)
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
# Step 1: Download / locate FASTQs
################################################################################

log_info "Step 1: Locating FASTQ files..."

STEP1_START=$(date +%s)

FASTQ_SUBDIR="${FASTQ_SUBDIRS[$DATASET]}"
FASTQ_DIR_NAME="${FASTQ_DIR_NAMES[$DATASET]}"
FASTQ_DIR="${FASTQ_BASE_DIR}/${FASTQ_SUBDIR}/${FASTQ_DIR_NAME}"

if [[ -d "$FASTQ_DIR" ]]; then
    R2_COUNT=$(find "$FASTQ_DIR" -name '*_R2_*.fastq.gz' | wc -l)
    if [[ $R2_COUNT -gt 0 ]]; then
        log_info "FASTQs already present at $FASTQ_DIR ($R2_COUNT R2 files)"
    else
        die "FASTQ directory exists but no R2 files found: $FASTQ_DIR"
    fi
else
    log_info "FASTQs not found — downloading..."
    FASTQ_TAR_URL="${FASTQ_TAR_URLS[$DATASET]}"
    DOWNLOAD_DIR="${FASTQ_BASE_DIR}/${FASTQ_SUBDIR}"
    mkdir -p "$DOWNLOAD_DIR"

    log_info "Downloading from: $FASTQ_TAR_URL"
    log_info "This may take a while for pbmc10k (~44 GB)..."
    curl -fSL "$FASTQ_TAR_URL" | tar -xf - -C "$DOWNLOAD_DIR"

    if [[ ! -d "$FASTQ_DIR" ]]; then
        # Tar may have extracted into a different name; look for it
        EXTRACTED=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type d -name '*fastqs*' | head -1)
        if [[ -n "$EXTRACTED" && "$EXTRACTED" != "$FASTQ_DIR" ]]; then
            mv "$EXTRACTED" "$FASTQ_DIR"
        else
            die "FASTQ download/extraction failed. Expected directory: $FASTQ_DIR"
        fi
    fi

    R2_COUNT=$(find "$FASTQ_DIR" -name '*_R2_*.fastq.gz' | wc -l)
    log_info "Downloaded FASTQs: $R2_COUNT R2 files in $FASTQ_DIR"
fi

STEP1_END=$(date +%s)
STEP1_SECS=$(( STEP1_END - STEP1_START ))
record_time "FASTQ Download / Locate" "$STEP1_SECS"
log_info "Step 1 completed in ${STEP1_SECS}s"

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

# Build comma-separated file lists for piscem
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

# Verify output
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

# Use knee-distance method (no external barcode list required)
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

# Verify quant output
if [[ ! -f "$ALEVIN_OUTPUT/quants_mat.mtx" && ! -f "$ALEVIN_OUTPUT/alevin/quants_mat.mtx" ]]; then
    log_warn "quants_mat.mtx not found in expected location. Checking subdirectories..."
    QUANT_MTX=$(find "$ALEVIN_OUTPUT" -name 'quants_mat.mtx' -o -name 'quants_mat.mtx.gz' | head -1)
    if [[ -z "$QUANT_MTX" ]]; then
        die "alevin-fry quant failed: cannot find quants_mat.mtx"
    fi
    log_info "Found quant matrix: $QUANT_MTX"
fi

################################################################################
# Step 6: Optional QC Analysis
################################################################################

STEP6_SECS=0
if [[ "${RUN_QC:-0}" == "1" ]]; then
    log_info "Step 6: Running QC analysis (requires python3)..."

    STEP6_START=$(date +%s)

    # Ensure python3 is available
    if ! need_cmd python3; then
        log_info "Installing python3 for QC..."
        wait_for_dpkg_lock
        sudo apt-get update -qq
        sudo apt-get install -y python3 python3-venv python3-pip
    fi

    QC_DIR="$RUN_DIR/analysis"
    mkdir -p "$QC_DIR/out"

    # Create isolated venv for QC
    python3 -m venv "$RUN_DIR/venv_qc"
    # shellcheck disable=SC1091
    source "$RUN_DIR/venv_qc/bin/activate"

    # Upgrade pip, install QC dependencies
    python -m pip install -q --upgrade pip setuptools wheel
    pip install -q numpy pandas scipy matplotlib seaborn anndata scanpy python-igraph leidenalg

    QC_ARGS=("$ALEVIN_OUTPUT" "--outdir" "$QC_DIR/out")
    if [[ "${WRITE_H5AD:-0}" == "1" ]]; then
        QC_ARGS+=("--write-h5ad")
    fi

    # qc_scanpy.py is in the repo at scripts/qc_scanpy.py
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python "$SCRIPT_DIR/qc_scanpy.py" "${QC_ARGS[@]}"

    deactivate

    STEP6_END=$(date +%s)
    STEP6_SECS=$(( STEP6_END - STEP6_START ))
    record_time "QC Analysis" "$STEP6_SECS"
    log_info "Step 6 completed in ${STEP6_SECS}s ($(fmt_secs $STEP6_SECS) min)"
else
    log_info "Step 6: Skipping QC (RUN_QC=0). No python required."
    record_time "QC Analysis" "SKIPPED"
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

# Build the timing table
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
    echo "Paper reference (Table 2):"
    echo "  PBMC 1K on-server:  2.26 min"
    echo "  PBMC 10K on-server: 23.21 min"
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
