#!/usr/bin/env bash

# One-shot KO asynchronous serverless benchmark.  Provisioning is deliberately
# outside the measured run.  FASTQ/manifests are retained, and no cleanup or
# Alevin step is performed.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  benchmark_ko_async.sh --provision
  benchmark_ko_async.sh --preflight
  benchmark_ko_async.sh --run

Configuration is supplied with environment variables.  The defaults name the
dedicated 2026-08-20 development resources and use the 7 GiB direct-upload
cutoff.  --run is guarded by a one-shot marker and refuses nonempty input or
output prefixes.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
elapsed() { awk -v start="$1" -v end="$2" 'BEGIN {printf "%.6f", (end-start)/1000000000}'; }

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
ACTION="$1"
case "$ACTION" in
    --provision|--preflight|--run) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
REGION="${AWS_REGION:-us-east-2}"
ACCOUNT_ID="${AWS_ACCOUNT_ID:-171440768238}"
BENCHMARK_ID="${BENCHMARK_ID:-ko-async-7gib-20260820-dev1}"
RUN_DIR="${RUN_DIR:-/mnt/nvme/benchmark-runs/$BENCHMARK_ID}"
UPLOAD_DIR="$RUN_DIR/upload"
FASTQ_BUCKET="${FASTQ_BUCKET:-scrna-ko-upload-fastq-${ACCOUNT_ID}-20260820-dev1}"
INPUT_TXT_BUCKET="${INPUT_TXT_BUCKET:-scrna-ko-upload-txt-${ACCOUNT_ID}-20260820-dev1}"
OUTPUT_MAP_BUCKET="${OUTPUT_MAP_BUCKET:-scrna-ko-async-map-${ACCOUNT_ID}-20260820-dev1}"
OUTPUT_QUANT_BUCKET="${OUTPUT_QUANT_BUCKET:-scrna-ko-async-quant-${ACCOUNT_ID}-20260820-dev1}"
FUNCTION_NAME="${FUNCTION_NAME:-scrna-ko-async-20260820-dev1}"
SOURCE_FUNCTION="${SOURCE_FUNCTION:-scrna-map-2026-08-20-16-58-22-409f901a}"
SAMPLE_MANIFEST="${SAMPLE_MANIFEST:-$SCRIPT_DIR/ko_sample_pairs.tsv}"
DIRECT_GZIP_MAX_BYTES="${DIRECT_GZIP_MAX_BYTES:-7516192768}"
EXPECTED_SHARDS="${EXPECTED_SHARDS:-917}"
EXPECTED_READS="${EXPECTED_READS:-6623775561}"
EXPECTED_MAPPED="${EXPECTED_MAPPED:-3645770776}"
BASELINE_SECONDS="${BASELINE_SECONDS:-8696.991876}"
LOCAL_BASELINE_DIR="${LOCAL_BASELINE_DIR:-/mnt/nvme/benchmark-runs/ko-piscem-baseline-20260820-dev1}"
PREFIX="${S3_PREFIX:-ko}"

bucket_object_count() {
    aws s3api list-objects-v2 --bucket "$1" --prefix "$2" --region "$REGION" \
        --query 'length(Contents || `[]`)' --output text
}

create_bucket_if_missing() {
    local bucket="$1"
    if ! aws s3api head-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
        aws s3api create-bucket --bucket "$bucket" --region "$REGION" \
            --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
        aws s3api put-public-access-block --bucket "$bucket" --region "$REGION" \
            --public-access-block-configuration \
            BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    fi
}

provision() {
    local source role image env_json
    create_bucket_if_missing "$OUTPUT_MAP_BUCKET"
    create_bucket_if_missing "$OUTPUT_QUANT_BUCKET"
    if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
        die "function already exists: $FUNCTION_NAME"
    fi
    source=$(aws lambda get-function --function-name "$SOURCE_FUNCTION" --region "$REGION")
    role=$(jq -r '.Configuration.Role' <<< "$source")
    image=$(jq -r '.Code.ResolvedImageUri' <<< "$source")
    env_json=$(jq -cn \
        --arg fastq "$FASTQ_BUCKET" --arg txt "$INPUT_TXT_BUCKET" --arg output "$OUTPUT_MAP_BUCKET" \
        '{Variables:{S3_INPUT_BUCKET_NAME:$fastq,S3_INPUT_TXT_BUCKET_NAME:$txt,S3_OUTPUT_BUCKET_NAME:$output,S3_CLAIM_PREFIX:"piscem_claims",CLAIM_LEASE_SECONDS:"180",CLAIM_HEARTBEAT_SECONDS:"30",LAMBDA_MEMORY_MB:"10240"}}')
    aws lambda create-function \
        --function-name "$FUNCTION_NAME" --package-type Image --code "ImageUri=$image" \
        --role "$role" --architectures x86_64 --memory-size 10240 --timeout 900 \
        --ephemeral-storage Size=10240 --environment "$env_json" --region "$REGION" \
        --tags benchmark=ko-async-7gib,cleanup=retained >/dev/null
    aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME" --region "$REGION"
    # No reservation is requested: the account currently retains only the
    # mandatory 100-unit unreserved pool after earlier benchmark reservations.
    aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" \
        > "$RUN_DIR.function.json"
    log "Provisioned $FUNCTION_NAME and isolated output buckets"
}

preflight() {
    local config notifications sample
    [[ -f "$SAMPLE_MANIFEST" ]] || die "sample manifest missing: $SAMPLE_MANIFEST"
    command -v jq >/dev/null || die "jq is required"
    command -v aws >/dev/null || die "aws CLI is required"
    command -v s3-rad-materialize >/dev/null || die "s3-rad-materialize is required"
    for sample in A B C D E F G_1 G_2 H I J L_1 L_2; do
        [[ -f "$LOCAL_BASELINE_DIR/samples/$sample/output/map_info.json" ]] || \
            die "local baseline map metadata is missing for sample $sample"
    done
    aws sts get-caller-identity --region "$REGION" >/dev/null
    for bucket in "$FASTQ_BUCKET" "$INPUT_TXT_BUCKET" "$OUTPUT_MAP_BUCKET" "$OUTPUT_QUANT_BUCKET"; do
        aws s3api head-bucket --bucket "$bucket" --region "$REGION"
    done
    notifications=$(aws s3api get-bucket-notification-configuration \
        --bucket "$INPUT_TXT_BUCKET" --region "$REGION")
    jq -e 'length == 0' <<< "$notifications" >/dev/null || \
        die "input manifest bucket must have no notifications; direct async invoke is the sole trigger"
    config=$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --region "$REGION")
    jq -e --arg f "$FASTQ_BUCKET" --arg t "$INPUT_TXT_BUCKET" --arg o "$OUTPUT_MAP_BUCKET" \
        '.State == "Active" and .MemorySize == 10240 and .Timeout == 900 and
         .EphemeralStorage.Size == 10240 and
         .Environment.Variables.S3_INPUT_BUCKET_NAME == $f and
         .Environment.Variables.S3_INPUT_TXT_BUCKET_NAME == $t and
         .Environment.Variables.S3_OUTPUT_BUCKET_NAME == $o' <<< "$config" >/dev/null || \
        die "Lambda configuration does not match the KO benchmark contract"
    log "Preflight passed: direct cutoff=$DIRECT_GZIP_MAX_BYTES bytes, expected shards=$EXPECTED_SHARDS"
}

run_benchmark() {
    local start_ns upload_end_ns materialize_start_ns end_ns marker_count map_count
    local last_marker_iso last_marker_ns first_decompressor_ns
    local sample rad aggregate async_reads async_mapped baseline_reads baseline_mapped status
    local -a folders files
    preflight
    mkdir -p "$RUN_DIR"
    (
        set -o noclobber
        date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN_DIR/started"
    ) 2>/dev/null || die "one-shot marker already exists: $RUN_DIR/started"
    [[ $(bucket_object_count "$FASTQ_BUCKET" "$PREFIX/") == 0 ]] || die "FASTQ prefix is not empty"
    [[ $(bucket_object_count "$INPUT_TXT_BUCKET" "$PREFIX/") == 0 ]] || die "manifest prefix is not empty"
    [[ $(bucket_object_count "$OUTPUT_MAP_BUCKET" "") == 0 ]] || die "output bucket is not empty"

    start_ns=$(date +%s%N)
    printf '%s\n' "$start_ns" > "$RUN_DIR/scheduler-start.ns"
    log "Starting one KO async run; uploads and Lambda mapping will overlap"
    RUN_ID="$BENCHMARK_ID-upload" RUN_DIR="$UPLOAD_DIR" \
        DIRECT_GZIP_MAX_BYTES="$DIRECT_GZIP_MAX_BYTES" \
        ASYNC_LAMBDA_FUNCTION="$FUNCTION_NAME" \
        AWS_REGION="$REGION" S3_PREFIX="$PREFIX" \
        bash "$SCRIPT_DIR/benchmark_ko_upload_only.sh" "$FASTQ_BUCKET" "$INPUT_TXT_BUCKET" \
        2>&1 | tee "$RUN_DIR/upload.log"
    upload_end_ns=$(<"$UPLOAD_DIR/end_ns.txt")
    printf '%s\n' "$upload_end_ns" > "$RUN_DIR/upload-complete.ns"

    awk -F '\t' '{key=$1; sub(/^.*\//,"",key); sub(/_input[.]txt$/,"",key); if (key != "") print key}' \
        "$UPLOAD_DIR/manifest_s3_inventory.tsv" | LC_ALL=C sort -V -u \
        > "$RUN_DIR/expected_rad_folders.txt"
    [[ $(awk 'NF {n++} END {print n+0}' "$RUN_DIR/expected_rad_folders.txt") -eq "$EXPECTED_SHARDS" ]] || \
        die "expected-folder contract is not $EXPECTED_SHARDS shards"
    python3 "$SCRIPT_DIR/build_sample_rad_contract.py" \
        --sample-manifest "$SAMPLE_MANIFEST" \
        --expected-folders "$RUN_DIR/expected_rad_folders.txt" \
        > "$RUN_DIR/sample_rad_contract.tsv"

    cat > "$RUN_DIR/async_state.env" <<EOF
RUN_ID=$BENCHMARK_ID
AWS_REGION=$REGION
OUTPUT_MAP_BUCKET=$OUTPUT_MAP_BUCKET
OUTPUT_QUANT_BUCKET=$OUTPUT_QUANT_BUCKET
EXPECTED_FOLDERS_FILE=$RUN_DIR/expected_rad_folders.txt
NOT_BEFORE=$(date -u -d "@$((start_ns / 1000000000))" +%Y-%m-%dT%H:%M:%SZ)
LAMBDA_FUNCTION=$FUNCTION_NAME
S3_CLAIM_PREFIX=piscem_claims
EOF

    materialize_start_ns=$(date +%s%N)
    printf '%s\n' "$materialize_start_ns" > "$RUN_DIR/materialize-start.ns"
    bash "$SCRIPT_DIR/async_lambda_control.sh" --state "$RUN_DIR/async_state.env" materialize \
        --sample-manifest "$SAMPLE_MANIFEST" --output-dir "$RUN_DIR/samples" \
        --threads 32 --poll-seconds 1 --timeout-seconds 43200 --rad-only \
        2>&1 | tee "$RUN_DIR/materialize.log"
    end_ns=$(date +%s%N)
    printf '%s\n' "$end_ns" > "$RUN_DIR/final-rads-complete.ns"

    aws s3api list-objects-v2 --bucket "$OUTPUT_MAP_BUCKET" --prefix piscem_output/ \
        --region "$REGION" --query 'Contents[].[Key,LastModified,Size]' --output text \
        > "$RUN_DIR/output_s3_inventory.tsv"
    awk -F '\t' '$1 ~ /\/output[.]txt$/ {print}' "$RUN_DIR/output_s3_inventory.tsv" \
        > "$RUN_DIR/output_markers.tsv"
    marker_count=$(wc -l < "$RUN_DIR/output_markers.tsv")
    [[ "$marker_count" -eq "$EXPECTED_SHARDS" ]] || die "only $marker_count completion markers exist"
    last_marker_iso=$(sort -t $'\t' -k2,2 "$RUN_DIR/output_markers.tsv" | tail -n 1 | cut -f2)
    last_marker_ns=$(date -d "$last_marker_iso" +%s%N)
    printf '%s\n' "$last_marker_ns" > "$RUN_DIR/last-lambda-marker.ns"

    mkdir -p "$RUN_DIR/map-info"
    aws s3 sync "s3://${OUTPUT_MAP_BUCKET}/piscem_output/" "$RUN_DIR/map-info/" \
        --region "$REGION" --exclude '*' --include '*/map_info.json' --only-show-errors
    map_count=$(find "$RUN_DIR/map-info" -type f -name map_info.json | wc -l)
    [[ "$map_count" -eq "$EXPECTED_SHARDS" ]] || die "only $map_count map_info.json objects downloaded"
    find "$RUN_DIR/map-info" -type f -name map_info.json -print0 | sort -z | xargs -0 jq -s \
        '{num_shards:length,num_reads:(map(.num_reads)|add),num_mapped:(map(.num_mapped)|add),input_bytes:(map(.input_bytes // 0)|add),map_rad_bytes:(map(.map_rad_bytes // 0)|add)}' \
        > "$RUN_DIR/aggregate-map-info.json"
    jq -e --argjson shards "$EXPECTED_SHARDS" --argjson reads "$EXPECTED_READS" --argjson mapped "$EXPECTED_MAPPED" \
        '.num_shards == $shards and .num_reads == $reads and .num_mapped == $mapped' \
        "$RUN_DIR/aggregate-map-info.json" >/dev/null || die "aggregate mapping counts differ from the local baseline"

    printf 'sample\tshards\tasync_reads\tbaseline_reads\tasync_mapped\tbaseline_mapped\tstatus\n' \
        > "$RUN_DIR/per-sample-count-validation.tsv"
    for sample in A B C D E F G_1 G_2 H I J L_1 L_2; do
        mapfile -t folders < <(awk -F '\t' -v wanted="$sample" \
            'NR > 1 && $1 == wanted {print $2}' "$RUN_DIR/sample_rad_contract.tsv")
        files=()
        for folder in "${folders[@]}"; do
            files+=("$RUN_DIR/map-info/$folder/map_info.json")
        done
        aggregate=$(jq -s '{reads:(map(.num_reads)|add),mapped:(map(.num_mapped)|add)}' "${files[@]}")
        async_reads=$(jq -r .reads <<< "$aggregate")
        async_mapped=$(jq -r .mapped <<< "$aggregate")
        baseline_reads=$(jq -r .num_reads "$LOCAL_BASELINE_DIR/samples/$sample/output/map_info.json")
        baseline_mapped=$(jq -r .num_mapped "$LOCAL_BASELINE_DIR/samples/$sample/output/map_info.json")
        status=PASS
        [[ "$async_reads" == "$baseline_reads" && "$async_mapped" == "$baseline_mapped" ]] || status=FAIL
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sample" "${#folders[@]}" \
            "$async_reads" "$baseline_reads" "$async_mapped" "$baseline_mapped" "$status" \
            >> "$RUN_DIR/per-sample-count-validation.tsv"
    done
    [[ $(awk -F '\t' 'NR > 1 && $7 != "PASS" {n++} END {print n+0}' \
        "$RUN_DIR/per-sample-count-validation.tsv") -eq 0 ]] || \
        die "one or more grouped samples differ from the local baseline"

    : > "$RUN_DIR/rad-validation.tsv"
    for sample in A B C D E F G_1 G_2 H I J L_1 L_2; do
        rad="$RUN_DIR/samples/$sample/map.rad"
        [[ -s "$rad" ]] || die "missing sample RAD: $rad"
        radtk view --input "$rad" --rad-type single-cell --max-chunks 1 >/dev/null \
            2>"$RUN_DIR/samples/$sample/radtk.stderr"
        printf '%s\t%s\t%s\n' "$sample" "$(stat -c %s "$rad")" "$rad" >> "$RUN_DIR/rad-validation.tsv"
    done

    first_decompressor_ns=$(<"$UPLOAD_DIR/first_decompressor_start.ns")
    aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --region "$REGION" \
        > "$RUN_DIR/lambda-function-configuration.json"
    aws lambda get-function-concurrency --function-name "$FUNCTION_NAME" --region "$REGION" \
        > "$RUN_DIR/lambda-function-concurrency.json" || true
    aws lambda get-account-settings --region "$REGION" > "$RUN_DIR/lambda-account-settings.json"
    printf '%s\n' \
        "benchmark_id=$BENCHMARK_ID" \
        "policy_cutoff_bytes=$DIRECT_GZIP_MAX_BYTES" \
        "pairs=130" \
        "split_pairs=25" \
        "direct_pairs=105" \
        "lambda_invocations=$EXPECTED_SHARDS" \
        "scheduler_to_upload_complete_seconds=$(elapsed "$start_ns" "$upload_end_ns")" \
        "first_decompressor_to_upload_complete_seconds=$(elapsed "$first_decompressor_ns" "$upload_end_ns")" \
        "first_decompressor_to_last_lambda_marker_seconds=$(elapsed "$first_decompressor_ns" "$last_marker_ns")" \
        "post_upload_lambda_tail_seconds=$(elapsed "$upload_end_ns" "$last_marker_ns")" \
        "materialization_stage_seconds=$(elapsed "$materialize_start_ns" "$end_ns")" \
        "first_decompressor_to_final_sample_rads_seconds=$(elapsed "$first_decompressor_ns" "$end_ns")" \
        "local_baseline_seconds=$BASELINE_SECONDS" \
        "speedup_vs_local_baseline=$(awk -v base="$BASELINE_SECONDS" -v async="$(elapsed "$first_decompressor_ns" "$end_ns")" 'BEGIN {printf "%.6f",base/async}')" \
        "seconds_saved_vs_local_baseline=$(awk -v base="$BASELINE_SECONDS" -v async="$(elapsed "$first_decompressor_ns" "$end_ns")" 'BEGIN {printf "%.6f",base-async}')" \
        "percent_reduction_vs_local_baseline=$(awk -v base="$BASELINE_SECONDS" -v async="$(elapsed "$first_decompressor_ns" "$end_ns")" 'BEGIN {printf "%.6f",100*(1-async/base)}')" \
        "total_reads=$EXPECTED_READS" \
        "mapped_reads=$EXPECTED_MAPPED" \
        "total_rad_bytes=$(awk -F '\t' '{s+=$2} END {printf "%.0f",s}' "$RUN_DIR/rad-validation.tsv")" \
        "alevin_ran=no" \
        "cleanup_performed=no" \
        > "$RUN_DIR/result.txt"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN_DIR/completed"
    cat "$RUN_DIR/result.txt"
}

case "$ACTION" in
    --provision) mkdir -p "$RUN_DIR"; provision ;;
    --preflight) preflight ;;
    --run) run_benchmark ;;
esac
