#!/usr/bin/env bash

# Materialize one RAD and one companion unmapped-count stream per biological
# sample. Mapping remains sample-agnostic; this is the only grouping boundary.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  materialize_sample_groups.sh \
    --output-bucket BUCKET \
    --expected-folders FILE \
    --sample-manifest FILE \
    --output-dir DIR \
    [options]

Required arguments:
  --output-bucket BUCKET     Lambda Piscem output bucket.
  --expected-folders FILE    Complete expected-folder contract for the run.
  --sample-manifest FILE     TSV with unique sample and pair_name columns.
  --output-dir DIR           Parent for SAMPLE/map.rad outputs.

Options:
  --region REGION            AWS region (default: AWS_REGION or us-east-2).
  --profile PROFILE          Named AWS profile. Omit on an EC2 instance role.
  --rad-prefix PREFIX        Prefix above each shard (default: piscem_output).
  --threads N                RAD and companion transfer concurrency (default: 32).
  --poll-seconds N           S3 polling interval (default: 1).
  --timeout-seconds N        Global readiness timeout (default: 43200).
  --not-before TIME          Ignore output objects older than this time.
  --readiness-inventory FILE Use a previously captured global readiness
                             inventory instead of listing S3. If omitted, the
                             script polls once globally and records one.
  --materializer FILE        s3-rad-materialize executable override.
  --overwrite                Atomically replace existing local outputs.
  --rad-only                 Do not create SAMPLE/unmapped_bc_count.bin.
  -h, --help                 Show this help.

Each expected folder must end in _pN. Removing that suffix must produce one
pair_name in the manifest. The script validates the complete join before it
creates any sample output.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

OUTPUT_BUCKET=""
EXPECTED_FOLDERS_FILE=""
SAMPLE_MANIFEST=""
OUTPUT_DIR=""
AWS_REGION_VALUE="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
AWS_PROFILE_VALUE="${AWS_PROFILE:-}"
RAD_PREFIX="piscem_output"
THREADS="${MATERIALIZER_THREADS:-32}"
POLL_SECONDS="${POLL_INTERVAL_SECONDS:-1}"
TIMEOUT_SECONDS="${PROCESS_FASTQ_TIMEOUT_SEC:-43200}"
NOT_BEFORE=""
READINESS_INVENTORY=""
MATERIALIZER="${MATERIALIZER:-s3-rad-materialize}"
OVERWRITE=0
RAD_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-bucket)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            OUTPUT_BUCKET="$2"; shift 2 ;;
        --expected-folders)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            EXPECTED_FOLDERS_FILE="$2"; shift 2 ;;
        --sample-manifest)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            SAMPLE_MANIFEST="$2"; shift 2 ;;
        --output-dir)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            OUTPUT_DIR="$2"; shift 2 ;;
        --region)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            AWS_REGION_VALUE="$2"; shift 2 ;;
        --profile)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            AWS_PROFILE_VALUE="$2"; shift 2 ;;
        --rad-prefix)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            RAD_PREFIX="${2#/}"; RAD_PREFIX="${RAD_PREFIX%/}"; shift 2 ;;
        --threads)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            THREADS="$2"; shift 2 ;;
        --poll-seconds)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            POLL_SECONDS="$2"; shift 2 ;;
        --timeout-seconds)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            TIMEOUT_SECONDS="$2"; shift 2 ;;
        --not-before)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            NOT_BEFORE="$2"; shift 2 ;;
        --readiness-inventory)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            READINESS_INVENTORY="$2"; shift 2 ;;
        --materializer)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            MATERIALIZER="$2"; shift 2 ;;
        --overwrite)
            OVERWRITE=1; shift ;;
        --rad-only)
            RAD_ONLY=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "unknown argument: $1" ;;
    esac
done

[[ -n "$OUTPUT_BUCKET" ]] || die "--output-bucket is required"
[[ -n "$EXPECTED_FOLDERS_FILE" ]] || die "--expected-folders is required"
[[ -n "$SAMPLE_MANIFEST" ]] || die "--sample-manifest is required"
[[ -n "$OUTPUT_DIR" ]] || die "--output-dir is required"
[[ -f "$EXPECTED_FOLDERS_FILE" ]] || die "expected-folder file not found: $EXPECTED_FOLDERS_FILE"
[[ -f "$SAMPLE_MANIFEST" ]] || die "sample manifest not found: $SAMPLE_MANIFEST"
[[ -z "$READINESS_INVENTORY" || -f "$READINESS_INVENTORY" ]] || \
    die "readiness inventory not found: $READINESS_INVENTORY"
[[ -n "$RAD_PREFIX" ]] || die "--rad-prefix cannot be empty"
is_positive_integer "$THREADS" || die "--threads must be a positive integer"
is_positive_integer "$POLL_SECONDS" || die "--poll-seconds must be a positive integer"
is_positive_integer "$TIMEOUT_SECONDS" || die "--timeout-seconds must be a positive integer"
command -v python3 >/dev/null 2>&1 || die "required command not found: python3"
command -v aws >/dev/null 2>&1 || die "required command not found: aws"
command -v "$MATERIALIZER" >/dev/null 2>&1 || die "materializer not found: $MATERIALIZER"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONTRACT_BUILDER="$SCRIPT_DIR/build_sample_rad_contract.py"
SINGLE_MATERIALIZER="$SCRIPT_DIR/synchronous_s3_rad_materialize.sh"
[[ -f "$CONTRACT_BUILDER" ]] || die "contract builder not found: $CONTRACT_BUILDER"
[[ -f "$SINGLE_MATERIALIZER" ]] || die "RAD materializer wrapper not found: $SINGLE_MATERIALIZER"

mkdir -p "$OUTPUT_DIR"
CONTRACT_FILE=$(mktemp "$OUTPUT_DIR/.sample-contract.XXXXXX.tsv")
cleanup_contract() {
    rm -f -- "$CONTRACT_FILE"
}
trap cleanup_contract EXIT

python3 "$CONTRACT_BUILDER" \
    --sample-manifest "$SAMPLE_MANIFEST" \
    --expected-folders "$EXPECTED_FOLDERS_FILE" \
    > "$CONTRACT_FILE"

mapfile -t SAMPLES < <(tail -n +2 "$CONTRACT_FILE" | cut -f1 | LC_ALL=C sort -V -u)
[[ ${#SAMPLES[@]} -gt 0 ]] || die "sample contract contains no samples"

# Validate every destination before starting the first sample so a missing
# --overwrite cannot leave a partially materialized grouped run.
for sample in "${SAMPLES[@]}"; do
    sample_dir="$OUTPUT_DIR/$sample"
    [[ ! -e "$sample_dir/map.rad" || $OVERWRITE -eq 1 ]] || \
        die "output already exists: $sample_dir/map.rad (pass --overwrite to replace it)"
    if (( RAD_ONLY == 0 )); then
        [[ ! -e "$sample_dir/unmapped_bc_count.bin" || $OVERWRITE -eq 1 ]] || \
            die "output already exists: $sample_dir/unmapped_bc_count.bin (pass --overwrite to replace it)"
    fi
done

AWS_ARGS=(--region "$AWS_REGION_VALUE")
[[ -n "$AWS_PROFILE_VALUE" ]] && AWS_ARGS+=(--profile "$AWS_PROFILE_VALUE")

wait_for_global_readiness() {
    local inventory_file="$1" listing key modified relative folder object_epoch object_kind
    local started_ns started_utc started_epoch now elapsed ready list_calls=0
    local end_ns end_utc seconds
    local not_before_epoch="" partial="${inventory_file}.partial.$$"
    local -A expected=() have_rad=() have_marker=()

    while IFS= read -r folder; do
        [[ -n "$folder" ]] || continue
        expected["$folder"]=1
    done < "$EXPECTED_FOLDERS_FILE"
    (( ${#expected[@]} > 0 )) || die "expected-folder contract is empty"
    if [[ -n "$NOT_BEFORE" ]]; then
        not_before_epoch=$(date -u -d "$NOT_BEFORE" +%s 2>/dev/null) || \
            die "--not-before is not a valid date: $NOT_BEFORE"
    fi

    started_ns=$(date +%s%N)
    started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    started_epoch=$(date +%s)
    while true; do
        if ! listing=$(aws s3api list-objects-v2 \
            --bucket "$OUTPUT_BUCKET" --prefix "${RAD_PREFIX}/" \
            --query 'Contents[].[Key,LastModified]' --output text \
            "${AWS_ARGS[@]}" 2>&1); then
            log "Global S3 readiness listing failed; retrying: $(printf '%s' "$listing" | tail -1)"
            sleep "$POLL_SECONDS"
            continue
        fi
        list_calls=$((list_calls + 1))
        have_rad=()
        have_marker=()
        while IFS=$'\t' read -r key modified _rest; do
            [[ -n "${key:-}" && -n "${modified:-}" ]] || continue
            relative="${key#${RAD_PREFIX}/}"
            if [[ "$relative" == */map.rad ]]; then
                folder="${relative%/map.rad}"
                [[ -n "${expected[$folder]:-}" ]] || continue
                object_kind=rad
            elif [[ "$relative" == */output.txt ]]; then
                folder="${relative%/output.txt}"
                [[ -n "${expected[$folder]:-}" ]] || continue
                object_kind=marker
            else
                continue
            fi
            if [[ -n "$not_before_epoch" ]]; then
                object_epoch=$(date -u -d "$modified" +%s 2>/dev/null || echo 0)
                (( object_epoch >= not_before_epoch )) || continue
            fi
            if [[ "$object_kind" == rad ]]; then
                have_rad["$folder"]=1
            else
                have_marker["$folder"]=1
            fi
        done <<< "$listing"

        ready=0
        for folder in "${!expected[@]}"; do
            if [[ -n "${have_rad[$folder]:-}" && -n "${have_marker[$folder]:-}" ]]; then
                ready=$((ready + 1))
            fi
        done
        log "Global Lambda output progress: $ready/${#expected[@]} (S3 listings=$list_calls)"
        if (( ready == ${#expected[@]} )); then
            printf '%s\n' "$listing" > "$partial"
            mv -f -- "$partial" "$inventory_file"
            break
        fi
        now=$(date +%s)
        elapsed=$((now - started_epoch))
        (( elapsed < TIMEOUT_SECONDS )) || \
            die "timed out after ${elapsed}s waiting for the global Lambda output contract"
        sleep "$POLL_SECONDS"
    done

    end_ns=$(date +%s%N)
    end_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    seconds=$(awk -v start="$started_ns" -v end="$end_ns" \
        'BEGIN {printf "%.6f",(end-start)/1000000000}')
    printf 'stage,start_utc,end_utc,seconds,s3_list_calls\n' \
        > "$OUTPUT_DIR/group-readiness.timings.csv"
    printf 'global_lambda_readiness,%s,%s,%s,%s\n' \
        "$started_utc" "$end_utc" "$seconds" "$list_calls" \
        >> "$OUTPUT_DIR/group-readiness.timings.csv"
    log "Global readiness validated with $list_calls S3 listing(s) in ${seconds}s"
}

if [[ -z "$READINESS_INVENTORY" ]]; then
    READINESS_INVENTORY="$OUTPUT_DIR/s3-readiness-inventory.tsv"
    wait_for_global_readiness "$READINESS_INVENTORY"
else
    log "Using supplied shared readiness inventory: $READINESS_INVENTORY"
fi

download_unmapped_counts() {
    local expected_file="$1" output_file="$2"
    local temp_dir partial folder destination index=0 rc=0 pid
    local -a pids=() destinations=()

    temp_dir=$(mktemp -d "$(dirname "$output_file")/.unmapped.XXXXXX")
    partial="${output_file}.partial.$$"
    while IFS= read -r folder; do
        [[ -n "$folder" ]] || continue
        printf -v destination '%s/%08d.bin' "$temp_dir" "$index"
        destinations+=("$destination")
        aws s3 cp \
            "s3://${OUTPUT_BUCKET}/${RAD_PREFIX}/${folder}/unmapped_bc_count.bin" \
            "$destination" "${AWS_ARGS[@]}" --only-show-errors --no-progress &
        pids+=("$!")
        index=$((index + 1))
        if (( ${#pids[@]} >= THREADS )); then
            wait "${pids[0]}" || rc=1
            pids=("${pids[@]:1}")
        fi
    done < "$expected_file"
    for pid in "${pids[@]}"; do
        wait "$pid" || rc=1
    done
    if (( rc != 0 )); then
        find "$temp_dir" -type f -delete 2>/dev/null || true
        rmdir "$temp_dir" 2>/dev/null || true
        return 1
    fi

    : > "$partial"
    for destination in "${destinations[@]}"; do
        cat -- "$destination" >> "$partial"
    done
    [[ -s "$partial" ]] || return 1
    mv -f -- "$partial" "$output_file"
    find "$temp_dir" -type f -delete
    rmdir "$temp_dir"
}

for sample in "${SAMPLES[@]}"; do
    sample_dir="$OUTPUT_DIR/$sample"
    mkdir -p "$sample_dir"
    expected_file="$sample_dir/expected_rad_folders.txt"
    awk -F '\t' -v sample="$sample" \
        'NR > 1 && $1 == sample { print $2 }' "$CONTRACT_FILE" > "$expected_file"
    shard_count=$(awk 'NF {n++} END {print n+0}' "$expected_file")
    (( shard_count > 0 )) || die "sample $sample has no expected folders"

    materialize_args=(
        --output-bucket "$OUTPUT_BUCKET"
        --expected-folders "$expected_file"
        --output "$sample_dir/map.rad"
        --region "$AWS_REGION_VALUE"
        --rad-prefix "$RAD_PREFIX"
        --threads "$THREADS"
        --poll-seconds "$POLL_SECONDS"
        --timeout-seconds "$TIMEOUT_SECONDS"
        --manifest "$sample_dir/map.rad.shards.txt"
        --timings-file "$sample_dir/map.rad.timings.csv"
        --materializer "$MATERIALIZER"
        --readiness-inventory "$READINESS_INVENTORY"
    )
    [[ -n "$AWS_PROFILE_VALUE" ]] && materialize_args+=(--profile "$AWS_PROFILE_VALUE")
    [[ -n "$NOT_BEFORE" ]] && materialize_args+=(--not-before "$NOT_BEFORE")
    (( OVERWRITE == 1 )) && materialize_args+=(--overwrite)

    log "Materializing sample $sample from $shard_count Lambda shard(s)"
    bash "$SINGLE_MATERIALIZER" "${materialize_args[@]}"
    if (( RAD_ONLY == 0 )); then
        log "Combining sample $sample unmapped barcode counts"
        download_unmapped_counts "$expected_file" "$sample_dir/unmapped_bc_count.bin" || \
            die "failed to combine unmapped barcode counts for sample $sample"
    fi
done

cp -- "$CONTRACT_FILE" "$OUTPUT_DIR/sample_materialization.tsv"
log "Materialized ${#SAMPLES[@]} sample(s) under $OUTPUT_DIR"
