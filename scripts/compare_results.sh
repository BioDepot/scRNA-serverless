#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
#  compare_results.sh
#  Compare two scRNA-seq pipeline result directories (e.g. serverless vs
#  on-server / GitHub Actions).  Checks matrices, barcodes, gene lists,
#  quantification metrics, per-barcode QC stats, and prints timing side by
#  side.
# ---------------------------------------------------------------------------

# ── colour helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { printf "${GREEN}[PASS]${RESET} %s\n" "$1"; }
fail()  { printf "${RED}[FAIL]${RESET} %s\n" "$1"; FAILURES=$((FAILURES+1)); }
warn()  { printf "${YELLOW}[WARN]${RESET} %s\n" "$1"; WARNINGS=$((WARNINGS+1)); }
info()  { printf "${CYAN}[INFO]${RESET} %s\n" "$1"; }
header(){ printf "\n${BOLD}── %s ──${RESET}\n" "$1"; }

FAILURES=0
WARNINGS=0
CHECKS=0

check_pass() { CHECKS=$((CHECKS+1)); pass "$1"; }
check_fail() { CHECKS=$((CHECKS+1)); fail "$1"; }

# ── locate jq ─────────────────────────────────────────────────────────────
JQ=""
for candidate in jq "$HOME/.local/bin/jq" "$HOME/.local/bin/jq.exe"; do
    if command -v "$candidate" &>/dev/null; then JQ="$candidate"; break; fi
    if [[ -x "$candidate" ]]; then JQ="$candidate"; break; fi
done
if [[ -z "$JQ" ]]; then
    echo "ERROR: jq is required but not found. Install it or place it in ~/.local/bin/"
    exit 1
fi

# ── argument handling ─────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: compare_results.sh <dataset> <reference_zip_or_dir> [local_results_dir]

  dataset               Dataset size: 1k or 10k
  reference_zip_or_dir  Path to the on-server results zip file, OR
                        an already-extracted directory.
  local_results_dir     (Optional) Path to the local / serverless results
                        directory.  If omitted, the script scans
                        serverless_runs/ for the most recent matching run.

Examples:
  compare_results.sh 1k  /path/to/onserver-pbmc1k-results.zip
  compare_results.sh 10k /path/to/onserver-pbmc10k-results.zip
  compare_results.sh 1k  /path/to/1k.zip  /path/to/specific/local/run

The script compares:
  • Count matrix (quants_mat.mtx)  – exact match
  • Cell barcodes (quants_mat_rows.txt)
  • Gene list (quants_mat_cols.txt)
  • Quantification metrics from quant.json
  • Permit-list metrics from generate_permit_list.json
  • Per-barcode QC stats from featureDump.txt
  • Timing summaries (side by side, pipeline compute only)
  • File presence / sizes
EOF
    exit 1
}

[[ $# -lt 2 ]] && usage

DATASET_INPUT="$1"
case "$DATASET_INPUT" in
    1k|1K|pbmc1k)  DATASET="pbmc1k"  ;;
    10k|10K|pbmc10k) DATASET="pbmc10k" ;;
    *) echo "ERROR: dataset must be 1k or 10k (got: $DATASET_INPUT)"; exit 1 ;;
esac

REF_INPUT="$2"
LOCAL_INPUT="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLEANUP_TMPDIR=""

# ── resolve reference directory ───────────────────────────────────────────
resolve_ref() {
    local input="$1"
    # Convert Windows paths
    input="${input//\\//}"

    if [[ -d "$input" ]]; then
        # Already a directory – find the inner result dir if needed
        if [[ -f "$input/alevin_output/quant.json" ]]; then
            echo "$input"; return
        fi
        local inner
        inner=$(find "$input" -maxdepth 4 -name "quant.json" -path "*/alevin_output/*" 2>/dev/null | head -1)
        if [[ -n "$inner" ]]; then
            echo "$(dirname "$(dirname "$inner")")"; return
        fi
        echo "ERROR: Could not find alevin_output/quant.json inside $input" >&2; return 1
    fi

    # It's a file – try to unzip
    if [[ ! -f "$input" ]]; then
        echo "ERROR: $input does not exist" >&2; return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    CLEANUP_TMPDIR="$tmpdir"
    info "Extracting $(basename "$input") to temp directory …" >&2
    if command -v unzip &>/dev/null; then
        unzip -q "$input" -d "$tmpdir"
    elif command -v powershell.exe &>/dev/null; then
        powershell.exe -NoProfile -Command \
            "Expand-Archive -Path '$(cygpath -w "$input")' -DestinationPath '$(cygpath -w "$tmpdir")'"
    else
        echo "ERROR: No unzip or powershell available to extract the zip" >&2; return 1
    fi

    resolve_ref "$tmpdir"
}

# ── resolve local results directory ───────────────────────────────────────
# Detects which dataset a result directory belongs to by reading run.env or
# checking the timing_summary.txt header.
detect_dataset() {
    local dir="$1"
    # Try run.env first
    local env_file=""
    env_file=$(find "$dir" -maxdepth 2 -name "run.env" 2>/dev/null | head -1)
    if [[ -n "$env_file" ]]; then
        local ds
        ds=$(grep "^DATASET=" "$env_file" 2>/dev/null | cut -d= -f2-)
        if [[ -n "$ds" ]]; then echo "$ds"; return; fi
    fi
    # Fall back to timing summary header
    local ts_file=""
    ts_file=$(find "$dir" -maxdepth 2 -name "timing_summary.txt" 2>/dev/null | head -1)
    if [[ -n "$ts_file" ]]; then
        if grep -qi "PBMC1K" "$ts_file" 2>/dev/null; then echo "pbmc1k"; return; fi
        if grep -qi "PBMC10K" "$ts_file" 2>/dev/null; then echo "pbmc10k"; return; fi
    fi
    echo "unknown"
}

resolve_local() {
    local input="$1" target_dataset="$2"
    input="${input//\\//}"

    if [[ -n "$input" ]]; then
        if [[ -f "$input/alevin_output/quant.json" ]]; then
            echo "$input"; return
        fi
        local inner
        inner=$(find "$input" -maxdepth 4 -name "quant.json" -path "*/alevin_output/*" 2>/dev/null | head -1)
        if [[ -n "$inner" ]]; then
            echo "$(dirname "$(dirname "$inner")")"; return
        fi
        echo "ERROR: Could not find alevin_output/quant.json inside $input" >&2; return 1
    fi

    # Auto-detect: find the newest run matching target_dataset under serverless_runs/
    local runs_dir="$REPO_ROOT/serverless_runs"
    if [[ ! -d "$runs_dir" ]]; then
        echo "ERROR: No local results dir given and $runs_dir not found" >&2; return 1
    fi

    # Collect all result dirs with quant.json, newest first
    local best_dir="" best_mtime=0
    while IFS= read -r qj; do
        local result_dir
        result_dir="$(dirname "$(dirname "$qj")")"
        local ds
        ds=$(detect_dataset "$result_dir")
        if [[ "$ds" == "$target_dataset" ]]; then
            local mtime
            mtime=$(stat -c '%Y' "$qj" 2>/dev/null || stat -f '%m' "$qj" 2>/dev/null || echo "0")
            if [[ $mtime -gt $best_mtime ]]; then
                best_mtime=$mtime
                best_dir="$result_dir"
            fi
        fi
    done < <(find "$runs_dir" -maxdepth 5 -name "quant.json" -path "*/alevin_output/*" 2>/dev/null)

    if [[ -z "$best_dir" ]]; then
        # List what IS available
        local available=""
        while IFS= read -r qj; do
            local rd
            rd="$(dirname "$(dirname "$qj")")"
            local ds
            ds=$(detect_dataset "$rd")
            available="${available}  ${ds} → $(basename "$rd")\n"
        done < <(find "$runs_dir" -maxdepth 5 -name "quant.json" -path "*/alevin_output/*" 2>/dev/null)

        if [[ -n "$available" ]]; then
            echo "ERROR: No ${target_dataset} serverless run found. Available runs:" >&2
            printf "$available" >&2
        else
            echo "ERROR: No serverless runs found in $runs_dir" >&2
        fi
        return 1
    fi

    echo "$best_dir"
}

# ── main ──────────────────────────────────────────────────────────────────
cleanup() { [[ -n "${CLEANUP_TMPDIR:-}" ]] && rm -rf "$CLEANUP_TMPDIR"; }
trap cleanup EXIT

REF_DIR=$(resolve_ref "$REF_INPUT")
LOCAL_DIR=$(resolve_local "$LOCAL_INPUT" "$DATASET")

# ── auto-save log ────────────────────────────────────────────────────────
COMPARE_LOG="${LOCAL_RESULTS_DIR:-$REPO_ROOT/serverless_runs}/compare_${DATASET}_$(date '+%Y%m%d_%H%M%S').log"
mkdir -p "$(dirname "$COMPARE_LOG")"
exec > >(tee "$COMPARE_LOG") 2>&1

printf "\n${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║          scRNA-seq Pipeline Results Comparison               ║${RESET}\n"
printf "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}\n"
echo
info "Dataset:       $DATASET"
info "Reference (A): $REF_DIR"
info "Local     (B): $LOCAL_DIR"
info "Log saved to:  $COMPARE_LOG"

# ── helper: json field compare ────────────────────────────────────────────
json_cmp() {
    local file_a="$1" file_b="$2" field="$3" label="$4"
    if [[ ! -f "$file_a" || ! -f "$file_b" ]]; then
        warn "$label – file(s) missing"; return
    fi
    local va vb
    va=$("$JQ" -r "$field" "$file_a" 2>/dev/null || echo "N/A")
    vb=$("$JQ" -r "$field" "$file_b" 2>/dev/null || echo "N/A")
    if [[ "$va" == "$vb" ]]; then
        check_pass "$label: $va"
    else
        check_fail "$label: ref=$va  local=$vb"
    fi
}

# ── pre-define common file paths ──────────────────────────────────────────
MTX_A="$REF_DIR/alevin_output/alevin/quants_mat.mtx"
MTX_B="$LOCAL_DIR/alevin_output/alevin/quants_mat.mtx"
ROWS_FILE_A="$REF_DIR/alevin_output/alevin/quants_mat_rows.txt"
ROWS_FILE_B="$LOCAL_DIR/alevin_output/alevin/quants_mat_rows.txt"
COLS_FILE_A="$REF_DIR/alevin_output/alevin/quants_mat_cols.txt"
COLS_FILE_B="$LOCAL_DIR/alevin_output/alevin/quants_mat_cols.txt"

# ══════════════════════════════════════════════════════════════════════════
header "1. Count Matrix (quants_mat.mtx)"
# ══════════════════════════════════════════════════════════════════════════

if [[ -f "$MTX_A" && -f "$MTX_B" ]]; then
    # Compare header line (dimensions)
    DIM_A=$(sed -n '3p' "$MTX_A")
    DIM_B=$(sed -n '3p' "$MTX_B")
    ROWS_A=$(echo "$DIM_A" | awk '{print $1}')
    COLS_A=$(echo "$DIM_A" | awk '{print $2}')
    NNZ_A=$(echo "$DIM_A"  | awk '{print $3}')
    ROWS_B=$(echo "$DIM_B" | awk '{print $1}')
    COLS_B=$(echo "$DIM_B" | awk '{print $2}')
    NNZ_B=$(echo "$DIM_B"  | awk '{print $3}')

    if [[ "$ROWS_A" == "$ROWS_B" ]]; then
        check_pass "Cells (rows): $ROWS_A"
    else
        check_fail "Cells (rows): ref=$ROWS_A  local=$ROWS_B"
    fi

    if [[ "$COLS_A" == "$COLS_B" ]]; then
        check_pass "Genes (cols): $COLS_A"
    else
        check_fail "Genes (cols): ref=$COLS_A  local=$COLS_B"
    fi

    if [[ "$NNZ_A" == "$NNZ_B" ]]; then
        check_pass "Non-zeros:    $NNZ_A"
    else
        check_fail "Non-zeros:    ref=$NNZ_A  local=$NNZ_B"
    fi

    # Full content comparison – barcode order may differ between runs, so we
    # remap row indices to barcode names before comparing.
    info "Comparing full matrix content ($(echo "$NNZ_A" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta') entries) – normalising barcode order …"

    # Normalise: replace numeric row index with the barcode string, then sort
    normalise_mtx() {
        local mtx="$1" rows="$2"
        awk 'NR==FNR{bc[NR]=$1; next} {print bc[$1], $2, $3}' "$rows" <(tail -n +4 "$mtx") \
            | sort -k1,1 -k2,2n
    }

    NORM_A=$(normalise_mtx "$MTX_A" "$ROWS_FILE_A")
    NORM_B=$(normalise_mtx "$MTX_B" "$ROWS_FILE_B")

    if [[ "$NORM_A" == "$NORM_B" ]]; then
        check_pass "Matrix values: IDENTICAL (after barcode-order normalisation)"
    else
        DIFF_COUNT=$(diff <(echo "$NORM_A") <(echo "$NORM_B") | grep -c '^[<>]' || true)
        check_fail "Matrix values: $DIFF_COUNT differing entries (barcode-normalised)"
    fi
    unset NORM_A NORM_B
else
    [[ ! -f "$MTX_A" ]] && check_fail "quants_mat.mtx missing in reference"
    [[ ! -f "$MTX_B" ]] && check_fail "quants_mat.mtx missing in local"
fi

# ══════════════════════════════════════════════════════════════════════════
header "2. Cell Barcodes (quants_mat_rows.txt)"
# ══════════════════════════════════════════════════════════════════════════

if [[ -f "$ROWS_FILE_A" && -f "$ROWS_FILE_B" ]]; then
    COUNT_A=$(wc -l < "$ROWS_FILE_A" | tr -d ' ')
    COUNT_B=$(wc -l < "$ROWS_FILE_B" | tr -d ' ')
    if [[ "$COUNT_A" == "$COUNT_B" ]]; then
        check_pass "Barcode count: $COUNT_A"
    else
        check_fail "Barcode count: ref=$COUNT_A  local=$COUNT_B"
    fi

    SORTED_DIFF=$(diff <(sort "$ROWS_FILE_A") <(sort "$ROWS_FILE_B") || true)
    if [[ -z "$SORTED_DIFF" ]]; then
        check_pass "Barcode set: IDENTICAL"
    else
        ONLY_A=$(echo "$SORTED_DIFF" | grep -c '^< ' || true)
        ONLY_B=$(echo "$SORTED_DIFF" | grep -c '^> ' || true)
        check_fail "Barcode set: $ONLY_A only in ref, $ONLY_B only in local"
    fi

    ORDER_DIFF=$(diff "$ROWS_FILE_A" "$ROWS_FILE_B" || true)
    if [[ -z "$ORDER_DIFF" ]]; then
        check_pass "Barcode order: IDENTICAL"
    else
        warn "Barcode order differs (content matches)"
    fi
else
    [[ ! -f "$ROWS_FILE_A" ]] && check_fail "quants_mat_rows.txt missing in reference"
    [[ ! -f "$ROWS_FILE_B" ]] && check_fail "quants_mat_rows.txt missing in local"
fi

# ══════════════════════════════════════════════════════════════════════════
header "3. Gene List (quants_mat_cols.txt)"
# ══════════════════════════════════════════════════════════════════════════

if [[ -f "$COLS_FILE_A" && -f "$COLS_FILE_B" ]]; then
    COUNT_A=$(wc -l < "$COLS_FILE_A" | tr -d ' ')
    COUNT_B=$(wc -l < "$COLS_FILE_B" | tr -d ' ')
    if [[ "$COUNT_A" == "$COUNT_B" ]]; then
        check_pass "Gene count: $COUNT_A"
    else
        check_fail "Gene count: ref=$COUNT_A  local=$COUNT_B"
    fi

    GENE_DIFF=$(diff "$COLS_FILE_A" "$COLS_FILE_B" || true)
    if [[ -z "$GENE_DIFF" ]]; then
        check_pass "Gene list: IDENTICAL (order preserved)"
    else
        SORTED_GENE_DIFF=$(diff <(sort "$COLS_FILE_A") <(sort "$COLS_FILE_B") || true)
        if [[ -z "$SORTED_GENE_DIFF" ]]; then
            warn "Gene list: same genes, different order"
        else
            ONLY_A=$(echo "$SORTED_GENE_DIFF" | grep -c '^< ' || true)
            ONLY_B=$(echo "$SORTED_GENE_DIFF" | grep -c '^> ' || true)
            check_fail "Gene list: $ONLY_A only in ref, $ONLY_B only in local"
        fi
    fi
else
    [[ ! -f "$COLS_FILE_A" ]] && check_fail "quants_mat_cols.txt missing in reference"
    [[ ! -f "$COLS_FILE_B" ]] && check_fail "quants_mat_cols.txt missing in local"
fi

# ══════════════════════════════════════════════════════════════════════════
header "4. Quantification Metrics (quant.json)"
# ══════════════════════════════════════════════════════════════════════════
QJ_A="$REF_DIR/alevin_output/quant.json"
QJ_B="$LOCAL_DIR/alevin_output/quant.json"

json_cmp "$QJ_A" "$QJ_B" ".num_genes"            "num_genes"
json_cmp "$QJ_A" "$QJ_B" ".num_quantified_cells"  "num_quantified_cells"
json_cmp "$QJ_A" "$QJ_B" ".resolution_strategy"   "resolution_strategy"
json_cmp "$QJ_A" "$QJ_B" ".version_str"           "alevin-fry version"
json_cmp "$QJ_A" "$QJ_B" ".usa_mode"              "usa_mode"
json_cmp "$QJ_A" "$QJ_B" ".quant_options.sa_model" "sa_model"
json_cmp "$QJ_A" "$QJ_B" ".quant_options.resolution" "resolution"
json_cmp "$QJ_A" "$QJ_B" ".quant_options.use_mtx"  "use_mtx"
json_cmp "$QJ_A" "$QJ_B" ".quant_options.small_thresh" "small_thresh"

# ══════════════════════════════════════════════════════════════════════════
header "5. Permit-List Metrics (generate_permit_list.json)"
# ══════════════════════════════════════════════════════════════════════════
GPL_A="$REF_DIR/alevin_output/generate_permit_list.json"
GPL_B="$LOCAL_DIR/alevin_output/generate_permit_list.json"

json_cmp "$GPL_A" "$GPL_B" '.["max-ambig-record"]'  "max-ambig-record"
json_cmp "$GPL_A" "$GPL_B" '.["permit-list-type"]'   "permit-list-type"
json_cmp "$GPL_A" "$GPL_B" ".velo_mode"              "velo_mode"
json_cmp "$GPL_A" "$GPL_B" ".version_str"            "gpl version"

# ══════════════════════════════════════════════════════════════════════════
header "6. Per-Barcode QC (featureDump.txt)"
# ══════════════════════════════════════════════════════════════════════════
FD_A="$REF_DIR/alevin_output/featureDump.txt"
FD_B="$LOCAL_DIR/alevin_output/featureDump.txt"

if [[ -f "$FD_A" && -f "$FD_B" ]]; then
    BC_A=$(tail -n +2 "$FD_A" | wc -l | tr -d ' ')
    BC_B=$(tail -n +2 "$FD_B" | wc -l | tr -d ' ')
    if [[ "$BC_A" == "$BC_B" ]]; then
        check_pass "Barcode entries: $BC_A"
    else
        check_fail "Barcode entries: ref=$BC_A  local=$BC_B"
    fi

    # Sort by barcode (first column) and compare all columns
    SORTED_A=$(tail -n +2 "$FD_A" | sort -t$'\t' -k1,1)
    SORTED_B=$(tail -n +2 "$FD_B" | sort -t$'\t' -k1,1)

    if [[ "$SORTED_A" == "$SORTED_B" ]]; then
        check_pass "Per-barcode stats: IDENTICAL"
    else
        # Count matching vs mismatching barcodes
        MATCH=0; MISMATCH=0; TOTAL=0
        while IFS=$'\t' read -r bc_a rest_a; do
            rest_b=$(echo "$SORTED_B" | awk -F'\t' -v bc="$bc_a" '$1==bc{$1=""; print}')
            if [[ -n "$rest_b" ]]; then
                rest_a_trimmed=$(echo "$rest_a" | sed 's/^[[:space:]]*//')
                rest_b_trimmed=$(echo "$rest_b" | sed 's/^[[:space:]]*//')
                if [[ "$rest_a_trimmed" == "$rest_b_trimmed" ]]; then
                    MATCH=$((MATCH+1))
                else
                    MISMATCH=$((MISMATCH+1))
                fi
            else
                MISMATCH=$((MISMATCH+1))
            fi
            TOTAL=$((TOTAL+1))
        done <<< "$SORTED_A"

        if [[ $MISMATCH -eq 0 ]]; then
            check_pass "Per-barcode stats: all $TOTAL barcodes match"
        else
            check_fail "Per-barcode stats: $MISMATCH/$TOTAL barcodes differ"
        fi

        # Show aggregate stats comparison
        info "Aggregate QC comparison:"
        for col_idx in 2 3 4 5 6 8; do
            col_name=$(head -1 "$FD_A" | awk -F'\t' -v i=$col_idx '{print $i}')
            sum_a=$(echo "$SORTED_A" | awk -F'\t' -v i=$col_idx '{s+=$i}END{printf "%.2f", s}')
            sum_b=$(echo "$SORTED_B" | awk -F'\t' -v i=$col_idx '{s+=$i}END{printf "%.2f", s}')
            if [[ "$sum_a" == "$sum_b" ]]; then
                printf "  ${GREEN}✓${RESET} %-25s sum=%s\n" "$col_name" "$sum_a"
            else
                printf "  ${RED}✗${RESET} %-25s ref=%-15s local=%s\n" "$col_name" "$sum_a" "$sum_b"
            fi
        done
    fi
else
    [[ ! -f "$FD_A" ]] && warn "featureDump.txt missing in reference"
    [[ ! -f "$FD_B" ]] && warn "featureDump.txt missing in local"
fi

# ══════════════════════════════════════════════════════════════════════════
header "7. Collate Metrics (collate.json)"
# ══════════════════════════════════════════════════════════════════════════
CJ_A="$REF_DIR/alevin_output/collate.json"
CJ_B="$LOCAL_DIR/alevin_output/collate.json"

json_cmp "$CJ_A" "$CJ_B" ".compressed_output" "compressed_output"
json_cmp "$CJ_A" "$CJ_B" ".version_str"       "collate version"

# ══════════════════════════════════════════════════════════════════════════
header "8. Timing Comparison"
# ══════════════════════════════════════════════════════════════════════════
TIME_A="$REF_DIR/timing_summary.txt"
TIME_B="$LOCAL_DIR/timing_summary.txt"

# parse_timing FILE -> outputs "step_name<TAB>minutes" lines
# Extracts data rows from timing summaries (skips headers/separators/blanks)
parse_timing() {
    local f="$1"
    grep -v '^[[:space:]]*$' "$f" \
    | grep -v '===\|---\|Step\|Task\|Time\|FASTQs:' \
    | while IFS= read -r line; do
        local mins
        mins=$(echo "$line" | awk '{for(i=NF;i>=1;i--) if($i ~ /^[0-9]*\.?[0-9]+$/) {print $i; exit}}')
        [[ -z "$mins" ]] && continue
        local name
        name=$(echo "$line" | sed 's/[0-9.,]*[[:space:]]*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$name" ]] && continue
        printf '%s\t%s\n' "$name" "$mins"
    done
}

# Steps to exclude from the "pipeline computation" total (infrastructure, not compute)
EXCLUDE_PATTERN="FASTQ Download|FASTQ Upload|Docker Build|Upload Quant|Upload .* to S3"

if [[ -f "$TIME_A" || -f "$TIME_B" ]]; then
    # Parse both files
    STEPS_A=""
    STEPS_B=""
    [[ -f "$TIME_A" ]] && STEPS_A=$(parse_timing "$TIME_A")
    [[ -f "$TIME_B" ]] && STEPS_B=$(parse_timing "$TIME_B")

    # Show step-by-step table
    printf "\n  ${BOLD}%-40s %10s %10s${RESET}\n" "Step" "Ref (min)" "Local (min)"
    printf "  %-40s %10s %10s\n" "$(printf '%0.s─' {1..40})" "──────────" "──────────"

    COMPUTE_A="0"; COMPUTE_B="0"
    TOTAL_A="0";   TOTAL_B="0"

    # Print reference steps
    if [[ -n "$STEPS_A" ]]; then
        while IFS=$'\t' read -r name mins; do
            [[ "$name" =~ ^Total ]] && { TOTAL_A="$mins"; continue; }
            local_mins="-"
            is_infra=0
            echo "$name" | grep -qE "$EXCLUDE_PATTERN" && is_infra=1
            if [[ $is_infra -eq 0 ]]; then
                COMPUTE_A=$(awk "BEGIN{printf \"%.2f\", $COMPUTE_A + $mins}")
            fi
            printf "  %-40s %10s %10s\n" "$name" "$mins" "$local_mins"
        done <<< "$STEPS_A"
    fi

    # Print local steps (skip those already in ref by nature)
    if [[ -n "$STEPS_B" ]]; then
        while IFS=$'\t' read -r name mins; do
            [[ "$name" =~ ^Total ]] && { TOTAL_B="$mins"; continue; }
            is_infra=0
            echo "$name" | grep -qE "$EXCLUDE_PATTERN" && is_infra=1
            if [[ $is_infra -eq 0 ]]; then
                COMPUTE_B=$(awk "BEGIN{printf \"%.2f\", $COMPUTE_B + $mins}")
            fi
            # Check if this step only exists in local
            if [[ $is_infra -eq 1 ]]; then
                printf "  ${YELLOW}%-40s %10s %10s${RESET}\n" "$name (infra)" "-" "$mins"
            else
                printf "  %-40s %10s %10s\n" "$name" "-" "$mins"
            fi
        done <<< "$STEPS_B"
    fi

    printf "  %-40s %10s %10s\n" "$(printf '%0.s─' {1..40})" "──────────" "──────────"

    # Compute-only totals (excluding FASTQ download + infrastructure)
    printf "  ${BOLD}%-40s %10s %10s${RESET}\n" \
        "Pipeline Compute (excl. infra)" "$COMPUTE_A" "$COMPUTE_B"

    if [[ "$TOTAL_A" != "0" || "$TOTAL_B" != "0" ]]; then
        printf "  %-40s %10s %10s\n" \
            "Total (including everything)" \
            "$([ "$TOTAL_A" != "0" ] && echo "$TOTAL_A" || echo "-")" \
            "$([ "$TOTAL_B" != "0" ] && echo "$TOTAL_B" || echo "-")"
    fi

    echo
    if [[ "$COMPUTE_A" != "0" && "$COMPUTE_B" != "0" ]]; then
        RATIO=$(awk "BEGIN{printf \"%.1f\", $COMPUTE_B / $COMPUTE_A}")
        info "Pipeline compute ratio: local is ${RATIO}x vs reference"
    fi

    # Still show raw summaries for full context
    echo
    if [[ -f "$TIME_A" ]]; then
        printf "${CYAN}  Raw reference timing:${RESET}\n"
        sed 's/^/    /' "$TIME_A"
    fi
    echo
    if [[ -f "$TIME_B" ]]; then
        printf "${CYAN}  Raw local timing:${RESET}\n"
        sed 's/^/    /' "$TIME_B"
    fi
else
    warn "No timing_summary.txt in either result set"
fi

# ══════════════════════════════════════════════════════════════════════════
header "9. Environment Comparison (run.env)"
# ══════════════════════════════════════════════════════════════════════════
ENV_A="$REF_DIR/run.env"
ENV_B="$LOCAL_DIR/run.env"

if [[ -f "$ENV_A" && -f "$ENV_B" ]]; then
    # Critical keys that must match (hard fail)
    for key in DATASET; do
        va=$(grep "^${key}=" "$ENV_A" 2>/dev/null | cut -d= -f2- || true)
        vb=$(grep "^${key}=" "$ENV_B" 2>/dev/null | cut -d= -f2- || true)
        if [[ -z "$va" && -z "$vb" ]]; then continue; fi
        if [[ "$va" == "$vb" ]]; then
            check_pass "$key: $va"
        else
            check_fail "$key: ref=${va:-(not set)}  local=${vb:-(not set)}"
        fi
    done

    # Version / config keys – warn if one side is missing, fail only if both
    # exist but differ
    for key in PISCEM_VERSION ALEVIN_FRY_VERSION RADTK_VERSION RUN_QC WRITE_H5AD; do
        va=$(grep "^${key}=" "$ENV_A" 2>/dev/null | cut -d= -f2- || true)
        vb=$(grep "^${key}=" "$ENV_B" 2>/dev/null | cut -d= -f2- || true)
        if [[ -z "$va" && -z "$vb" ]]; then continue; fi
        if [[ -z "$va" || -z "$vb" ]]; then
            warn "$key: ref=${va:-(not set)}  local=${vb:-(not set)}"
            continue
        fi
        if [[ "$va" == "$vb" ]]; then
            check_pass "$key: $va"
        else
            check_fail "$key: ref=$va  local=$vb"
        fi
    done

    # Show hardware differences (info only, not pass/fail)
    info "Hardware (reference): $(grep CPU_MODEL "$ENV_A" 2>/dev/null | cut -d= -f2-), $(grep THREADS "$ENV_A" 2>/dev/null | cut -d= -f2-) threads, $(grep RAM_GB "$ENV_A" 2>/dev/null | cut -d= -f2-) GB RAM"
    info "Hardware (local):     see run.env"
else
    [[ ! -f "$ENV_A" ]] && warn "run.env missing in reference"
    [[ ! -f "$ENV_B" ]] && warn "run.env missing in local"
fi

# ══════════════════════════════════════════════════════════════════════════
header "10. File Inventory"
# ══════════════════════════════════════════════════════════════════════════
# Key files that should exist in both
KEY_FILES=(
    "alevin_output/alevin/quants_mat.mtx"
    "alevin_output/alevin/quants_mat_rows.txt"
    "alevin_output/alevin/quants_mat_cols.txt"
    "alevin_output/quant.json"
    "alevin_output/generate_permit_list.json"
    "alevin_output/collate.json"
    "alevin_output/featureDump.txt"
    "alevin_output/map.collated.rad"
    "combined/map.rad"
    "combined/unmapped_bc_count.bin"
    "analysis/out/pbmc_adata.h5ad"
    "analysis/out/qc_violin.png"
    "run.env"
    "timing_summary.txt"
)

printf "\n  %-50s  %10s  %10s\n" "File" "Ref" "Local"
printf "  %-50s  %10s  %10s\n" "$(printf '%0.s─' {1..50})" "──────────" "──────────"

for f in "${KEY_FILES[@]}"; do
    fa="$REF_DIR/$f"
    fb="$LOCAL_DIR/$f"
    size_a="-"
    size_b="-"
    if [[ -f "$fa" ]]; then
        sz=$(wc -c < "$fa" | tr -d ' ')
        if [[ $sz -gt 1048576 ]]; then
            size_a="$(awk "BEGIN{printf \"%.1fM\", $sz/1048576}")"
        elif [[ $sz -gt 1024 ]]; then
            size_a="$(awk "BEGIN{printf \"%.1fK\", $sz/1024}")"
        else
            size_a="${sz}B"
        fi
    fi
    if [[ -f "$fb" ]]; then
        sz=$(wc -c < "$fb" | tr -d ' ')
        if [[ $sz -gt 1048576 ]]; then
            size_b="$(awk "BEGIN{printf \"%.1fM\", $sz/1048576}")"
        elif [[ $sz -gt 1024 ]]; then
            size_b="$(awk "BEGIN{printf \"%.1fK\", $sz/1024}")"
        else
            size_b="${sz}B"
        fi
    fi
    printf "  %-50s  %10s  %10s\n" "$f" "$size_a" "$size_b"
done

# ══════════════════════════════════════════════════════════════════════════
header "Summary"
# ══════════════════════════════════════════════════════════════════════════
echo
printf "  Checks run:  %d\n" "$CHECKS"
printf "  ${GREEN}Passed:${RESET}      %d\n" "$((CHECKS - FAILURES))"
if [[ $FAILURES -gt 0 ]]; then
    printf "  ${RED}Failed:${RESET}      %d\n" "$FAILURES"
else
    printf "  Failed:      0\n"
fi
if [[ $WARNINGS -gt 0 ]]; then
    printf "  ${YELLOW}Warnings:${RESET}    %d\n" "$WARNINGS"
fi
echo

if [[ $FAILURES -eq 0 ]]; then
    printf "${GREEN}${BOLD}✓ All checks passed – results are consistent.${RESET}\n\n"
    exit 0
else
    printf "${RED}${BOLD}✗ %d check(s) failed – results differ.${RESET}\n\n" "$FAILURES"
    exit 1
fi
