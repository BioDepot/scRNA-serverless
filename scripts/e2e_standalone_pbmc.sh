#!/usr/bin/env bash
################################################################################
# e2e_standalone_pbmc.sh
#
# Standalone scRNA-seq pipeline for PBMC datasets.
# Replicates the "On-Server (SSD) Execution" baseline from the GigaScience
# paper — but runs entirely on YOUR machine. No remote server, no SSH, no
# secrets, no AWS.
#
# Everything is downloaded from public sources:
#   - Tools:     GitHub releases (piscem, alevin-fry, radtk)
#   - Reference: Zenodo (pre-built piscem index + t2g.tsv)
#   - FASTQs:    10x Genomics
#
# USAGE:
#   bash scripts/e2e_standalone_pbmc.sh pbmc1k
#   bash scripts/e2e_standalone_pbmc.sh pbmc1k --dry-run
#   bash scripts/e2e_standalone_pbmc.sh pbmc10k        # if enabled
#
# ENVIRONMENT VARIABLES (optional overrides):
#   THREADS            CPU threads for tools (default: nproc)
#   RUN_QC             Run QC analysis after quant (default: 1)
#   WRITE_H5AD         Save h5ad from QC (default: 0, requires RUN_QC=1)
#   DATA_DIR           Where to store reference + FASTQs (default: ./data)
#   TOOLS_DIR          Where to install tools (default: ./tools)
#   RESULTS_DIR        Where to store results (default: ./standalone_runs)
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

################################################################################
# Zenodo reference URL
################################################################################

ZENODO_RECORD_ID="${ZENODO_RECORD_ID:-19375096}"
ZENODO_REF_URL="https://zenodo.org/records/${ZENODO_RECORD_ID}/files/piscem_reference.tar.gz"

################################################################################
# FASTQ download URLs (10x Genomics, public)
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
# Directory Layout
################################################################################

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${DATA_DIR:-${REPO_ROOT}/data}"
TOOLS_DIR="${TOOLS_DIR:-${REPO_ROOT}/tools}"
RESULTS_DIR="${RESULTS_DIR:-${REPO_ROOT}/standalone_runs}"
TOOLS_BIN="${TOOLS_DIR}/bin"

REFERENCE_DIR="${DATA_DIR}/reference"
PISCEM_INDEX_DIR="${REFERENCE_DIR}/index_output_transcriptome"
T2G_PATH="${REFERENCE_DIR}/t2g.tsv"
FASTQ_BASE_DIR="${DATA_DIR}/datasets/10x"

THREADS="${THREADS:-}"
RUN_QC="${RUN_QC:-1}"
WRITE_H5AD="${WRITE_H5AD:-0}"

################################################################################
# Argument Parsing
################################################################################

if [[ $# -lt 1 ]]; then
    cat >&2 <<EOF
Usage: $0 <dataset> [--dry-run]

  dataset:    pbmc1k or pbmc10k
  --dry-run:  Validate requirements without executing the pipeline

This script runs entirely on your machine. It downloads all data from
public sources (Zenodo for reference, 10x Genomics for FASTQs) and
auto-installs pipeline tools if they are not found.

Examples:
  bash $0 pbmc1k
  bash $0 pbmc1k --dry-run
  RUN_QC=1 WRITE_H5AD=1 bash $0 pbmc1k
EOF
    exit 1
fi

DATASET="$1"
if [[ "$DATASET" != "pbmc1k" && "$DATASET" != "pbmc10k" ]]; then
    die "Unknown dataset: $DATASET (must be pbmc1k or pbmc10k)"
fi

# ── PBMC 10K is disabled by default ──────────────────────────────────────────
if [[ "$DATASET" == "pbmc10k" && "${ALLOW_10K:-0}" != "1" ]]; then
    echo ""
    echo "  PBMC 10K is disabled by default."
    echo "  To enable, set ALLOW_10K=1 before running:"
    echo ""
    echo "    ALLOW_10K=1 bash scripts/e2e_standalone_pbmc.sh pbmc10k"
    echo ""
    exit 1
fi
# ─────────────────────────────────────────────────────────────────────────────

DRY_RUN_MODE=0
if [[ $# -gt 1 ]]; then
    case "$2" in
        --dry-run) DRY_RUN_MODE=1 ;;
        *) die "Unknown flag: $2 (expected --dry-run)" ;;
    esac
fi

################################################################################
# Generate Run ID
################################################################################

RUN_ID="${RUN_ID:-${DATASET}-$(date +%s)-$(rand_hex 8)}"

################################################################################
# Add tools/bin to PATH
################################################################################

mkdir -p "$TOOLS_BIN"
export PATH="${TOOLS_BIN}:${PATH}"

################################################################################
# Step 0: Check and install tools
################################################################################

log_info "======== Standalone scRNA-seq Pipeline ========"
log_info "Dataset: $DATASET"
log_info "Run ID:  $RUN_ID"
log_info ""
log_info "Step 0: Checking and installing tools..."

_install_tool() {
    local name="$1" url="$2" archive_name="$3" binary_path="$4"
    if need_cmd "$name"; then
        log_info "  [OK] $name already installed: $($name --version 2>&1 | head -1)"
        return 0
    fi
    log_info "  Installing $name..."
    local tmpdir
    tmpdir=$(mktemp -d)
    (
        cd "$tmpdir"
        curl -fsSL "$url" -o "$archive_name"
        if [[ "$archive_name" == *.tar.gz ]]; then
            tar -xzf "$archive_name"
        elif [[ "$archive_name" == *.tar.xz ]]; then
            tar -xf "$archive_name"
        fi
        cp "$binary_path" "${TOOLS_BIN}/"
        chmod +x "${TOOLS_BIN}/$(basename "$binary_path")"
    )
    rm -rf "$tmpdir"
    if need_cmd "$name"; then
        log_info "  [OK] $name installed: $($name --version 2>&1 | head -1)"
    else
        die "Failed to install $name"
    fi
}

_install_tool "piscem" \
    "https://github.com/COMBINE-lab/piscem/releases/download/v0.10.3/piscem-x86_64-unknown-linux-gnu.tar.gz" \
    "piscem.tar.gz" \
    "piscem-x86_64-unknown-linux-gnu/piscem"

_install_tool "alevin-fry" \
    "https://github.com/COMBINE-lab/alevin-fry/releases/download/v0.9.0/alevin-fry-x86_64-unknown-linux-gnu.tar.xz" \
    "alevin-fry.tar.xz" \
    "alevin-fry-x86_64-unknown-linux-gnu/alevin-fry"

_install_tool "radtk" \
    "https://github.com/COMBINE-lab/radtk/releases/download/v0.1.0/radtk-x86_64-unknown-linux-gnu.tar.xz" \
    "radtk.tar.xz" \
    "radtk-x86_64-unknown-linux-gnu/radtk"

for tool in curl tar gzip bc; do
    if ! need_cmd "$tool"; then
        die "$tool is required but not installed. Install it with your package manager (e.g. apt-get install $tool)"
    fi
done

log_info "Tool versions:"
log_info "  piscem:     $(piscem --version 2>&1 | head -1)"
log_info "  alevin-fry: $(alevin-fry --version 2>&1 | head -1)"
log_info "  radtk:      $(radtk --version 2>&1 | head -1)"
log_info "Step 0 complete"

################################################################################
# Step 1a: Download reference from Zenodo (if not present)
################################################################################

log_info "Step 1a: Checking reference data..."

if [[ -d "$PISCEM_INDEX_DIR" && -f "$T2G_PATH" ]]; then
    log_info "  [OK] Reference already present at $REFERENCE_DIR"
else
    log_info "  Downloading reference from Zenodo (record ${ZENODO_RECORD_ID})..."
    mkdir -p "$REFERENCE_DIR"
    curl -fSL "$ZENODO_REF_URL" | tar -xzf - -C "$REFERENCE_DIR"
    if [[ ! -d "$PISCEM_INDEX_DIR" ]]; then
        die "Reference download/extraction failed: $PISCEM_INDEX_DIR not found after extraction"
    fi
    if [[ ! -f "$T2G_PATH" ]]; then
        die "Reference download/extraction failed: $T2G_PATH not found after extraction"
    fi
    log_info "  [OK] Reference downloaded and extracted"
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
log_info "  Piscem index prefix: $PISCEM_INDEX_PREFIX"
log_info "  t2g.tsv: $T2G_PATH"
log_info "Step 1a complete"

################################################################################
# Step 1b: Download FASTQs from 10x Genomics (if not present)
################################################################################

log_info "Step 1b: Checking FASTQ files..."

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
    log_info "  FASTQ directory found at $FASTQ_DIR — validating..."
    if _validate_fastqs "$FASTQ_DIR"; then
        log_info "  Using cached FASTQs (no download needed)"
        FASTQ_STATUS="cached"
    else
        log_warn "  Cached FASTQs are incomplete or corrupt — re-downloading..."
        rm -rf "$FASTQ_DIR"
        DL_START=$(date +%s)
        _download_fastqs
        DL_END=$(date +%s)
        FASTQ_DOWNLOAD_SECS=$(( DL_END - DL_START ))
        FASTQ_STATUS="redownloaded"
        if ! _validate_fastqs "$FASTQ_DIR"; then
            die "FASTQs still invalid after re-download"
        fi
        log_info "  Re-downloaded and validated FASTQs in ${FASTQ_DOWNLOAD_SECS}s"
    fi
else
    log_info "  FASTQs not found — downloading..."
    DL_START=$(date +%s)
    _download_fastqs
    DL_END=$(date +%s)
    FASTQ_DOWNLOAD_SECS=$(( DL_END - DL_START ))
    FASTQ_STATUS="downloaded"
    if ! _validate_fastqs "$FASTQ_DIR"; then
        die "Downloaded FASTQs failed validation"
    fi
    log_info "  Downloaded and validated FASTQs in ${FASTQ_DOWNLOAD_SECS}s"
fi

log_info "Step 1b complete (FASTQ status: $FASTQ_STATUS)"

################################################################################
# Disk space check
################################################################################

log_info "Checking disk space..."
AVAIL_MB=$(df -m . 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
if [[ "$DATASET" == "pbmc10k" ]]; then
    REQUIRED_MB=15000
else
    REQUIRED_MB=3000
fi
log_info "  Available: ${AVAIL_MB} MB, Required: ${REQUIRED_MB} MB"
if [[ "${AVAIL_MB:-0}" -lt "$REQUIRED_MB" ]]; then
    die "Insufficient disk space: ${AVAIL_MB} MB available, need ${REQUIRED_MB} MB"
fi

################################################################################
# DRY-RUN exits here
################################################################################

if [[ $DRY_RUN_MODE -eq 1 ]]; then
    log_info ""
    log_info "=== Dry-run summary ==="
    log_info "  Dataset:    $DATASET"
    log_info "  Reference:  $PISCEM_INDEX_DIR"
    log_info "  t2g.tsv:    $T2G_PATH"
    log_info "  FASTQs:     $FASTQ_DIR (status: $FASTQ_STATUS)"
    log_info "  Disk:       ${AVAIL_MB} MB available"
    log_info "  CPU cores:  $(nproc 2>/dev/null || echo unknown)"
    log_info "  RAM:        $(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo unknown) GB"
    log_info ""
    log_info "Dry-run passed. Ready to run."
    exit 0
fi

################################################################################
# Auto-detect thread count
################################################################################

if [[ -z "$THREADS" ]]; then
    THREADS=$(nproc 2>/dev/null || echo 4)
fi
log_info "Threads: $THREADS"

################################################################################
# Setup run directory
################################################################################

RUN_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"/{piscem_output,alevin_output,analysis,logs}
log_info "Run directory: $RUN_DIR"

################################################################################
# Collect FASTQ file lists
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
    2>&1 | tee "$RUN_DIR/logs/piscem_map.log" >&2

STEP2_END=$(date +%s)
STEP2_SECS=$(( STEP2_END - STEP2_START ))

if [[ ! -f "$PISCEM_OUTPUT/map_output/map.rad" ]]; then
    die "piscem map failed: map.rad not found"
fi

MAP_RAD_SIZE=$(stat --format=%s "$PISCEM_OUTPUT/map_output/map.rad" 2>/dev/null || \
               stat -f%z "$PISCEM_OUTPUT/map_output/map.rad" 2>/dev/null || echo 0)
log_info "Step 2 completed in ${STEP2_SECS}s"
log_info "  map.rad size: $(( MAP_RAD_SIZE / 1048576 )) MB"

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
    2>&1 | tee "$RUN_DIR/logs/alevin_gpl.log" >&2

STEP3_END=$(date +%s)
STEP3_SECS=$(( STEP3_END - STEP3_START ))
log_info "Step 3 completed in ${STEP3_SECS}s"

################################################################################
# Step 4: Alevin-fry collate
################################################################################

log_info "Step 4: Running alevin-fry collate..."

STEP4_START=$(date +%s)

alevin-fry collate \
    -t "$THREADS" \
    -i "$ALEVIN_OUTPUT" \
    -r "$PISCEM_OUTPUT/map_output" \
    2>&1 | tee "$RUN_DIR/logs/alevin_collate.log" >&2

STEP4_END=$(date +%s)
STEP4_SECS=$(( STEP4_END - STEP4_START ))
log_info "Step 4 completed in ${STEP4_SECS}s"

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
    2>&1 | tee "$RUN_DIR/logs/alevin_quant.log" >&2

STEP5_END=$(date +%s)
STEP5_SECS=$(( STEP5_END - STEP5_START ))
log_info "Step 5 completed in ${STEP5_SECS}s"

if [[ ! -f "$ALEVIN_OUTPUT/quants_mat.mtx" && ! -f "$ALEVIN_OUTPUT/alevin/quants_mat.mtx" ]]; then
    QUANT_MTX=$(find "$ALEVIN_OUTPUT" -name 'quants_mat.mtx' -o -name 'quants_mat.mtx.gz' | head -1)
    if [[ -z "$QUANT_MTX" ]]; then
        die "alevin-fry quant failed: cannot find quants_mat.mtx"
    fi
    log_info "Found quant matrix: $QUANT_MTX"
fi

################################################################################
# Step 6: Optional QC Analysis (UMAP + violin plots)
################################################################################

if [[ "${RUN_QC:-0}" == "1" ]]; then
    log_info "Step 6: Running QC analysis (UMAP + violin plots)..."

    if ! need_cmd python3; then
        die "python3 is required for QC analysis but not found. Install Python 3 and try again."
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
        log_info "  $QC_PLOTS plot(s) generated in $QC_DIR/out/"
    else
        log_warn "QC analysis failed (non-fatal). Pipeline continues."
    fi

    deactivate 2>/dev/null || true
    rm -rf "$RUN_DIR/venv_qc"

    log_info "Step 6 complete"
else
    log_info "Step 6: Skipping QC (RUN_QC=0)."
fi

################################################################################
# Save Run Metadata
################################################################################

log_info "Saving run metadata..."

cat > "$RUN_DIR/run.env" <<EOF
RUN_ID=$RUN_ID
DATASET=$DATASET
THREADS=$THREADS
HOSTNAME=$(hostname)
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
FASTQ_STATUS=$FASTQ_STATUS
FASTQ_DOWNLOAD_SECS=$FASTQ_DOWNLOAD_SECS
STEP2_PISCEM_MAP_SECS=$STEP2_SECS
STEP3_PERMIT_LIST_SECS=$STEP3_SECS
STEP4_COLLATE_SECS=$STEP4_SECS
STEP5_QUANT_SECS=$STEP5_SECS
EOF

log_info "Run metadata saved to $RUN_DIR/run.env"

################################################################################
# Summary
################################################################################

TOTAL_PIPELINE_SECS=$(( STEP2_SECS + STEP3_SECS + STEP4_SECS + STEP5_SECS ))

log_info ""
log_info "======== Pipeline Complete ========"
log_info "  Run ID:     $RUN_ID"
log_info "  Dataset:    $DATASET"
log_info "  Results:    $RUN_DIR"
log_info ""
log_info "  Timing (pipeline steps only, excludes data download):"
log_info "    Step 2 - piscem map:           ${STEP2_SECS}s"
log_info "    Step 3 - generate-permit-list: ${STEP3_SECS}s"
log_info "    Step 4 - collate:              ${STEP4_SECS}s"
log_info "    Step 5 - quant:                ${STEP5_SECS}s"
log_info "    ─────────────────────────────"
log_info "    Total pipeline:                ${TOTAL_PIPELINE_SECS}s"
if [[ $FASTQ_DOWNLOAD_SECS -gt 0 ]]; then
    log_info "    FASTQ download (not counted):  ${FASTQ_DOWNLOAD_SECS}s"
fi
log_info ""
log_info "  Key output files:"
log_info "    Quant matrix: $ALEVIN_OUTPUT/alevin/quants_mat.mtx"
log_info "    Run metadata: $RUN_DIR/run.env"
if [[ "${RUN_QC:-0}" == "1" ]]; then
    log_info "    QC plots:     $RUN_DIR/analysis/out/"
fi
log_info ""
log_info "Done."

exit 0
