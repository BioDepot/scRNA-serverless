#!/usr/bin/env bash

# Benchmark KO FASTQ materialization/upload from local NVMe without invoking
# Lambda. The input-manifest bucket must have no S3 event notifications.

set -euo pipefail

[[ $# -eq 2 ]] || {
    echo "Usage: $0 FASTQ_BUCKET INPUT_TXT_BUCKET" >&2
    exit 1
}

FASTQ_BUCKET="$1"
INPUT_TXT_BUCKET="$2"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MANIFEST="${MANIFEST:-$SCRIPT_DIR/ko_sample_pairs.tsv}"
FASTQ_DIR="${FASTQ_DIR:-/mnt/nvme/datasets/ko/fastqs}"
AWS_REGION_VALUE="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
S3_PREFIX="${S3_PREFIX:-ko}"
CORES="${CORES:-32}"
DIRECT_GZIP_MAX_BYTES="${DIRECT_GZIP_MAX_BYTES:-1073741824}"
SPLIT_LINES="${SPLIT_LINES:-16000000}"
RUN_ID="${RUN_ID:-ko-upload-only-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="${RUN_DIR:-/mnt/nvme/benchmark-runs/$RUN_ID}"
ASYNC_LAMBDA_FUNCTION="${ASYNC_LAMBDA_FUNCTION:-}"
LAMBDA_INVOKE_LOG_DIR="${LAMBDA_INVOKE_LOG_DIR:-$RUN_DIR/lambda-invocations}"

[[ "$CORES" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: CORES must be positive" >&2; exit 1; }
[[ "$DIRECT_GZIP_MAX_BYTES" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: DIRECT_GZIP_MAX_BYTES must be positive" >&2
    exit 1
}
[[ "$SPLIT_LINES" =~ ^[1-9][0-9]*$ ]] && (( SPLIT_LINES % 4 == 0 )) || {
    echo "ERROR: SPLIT_LINES must be positive and divisible by four" >&2
    exit 1
}
[[ -f "$MANIFEST" ]] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; }
[[ -d "$FASTQ_DIR" ]] || { echo "ERROR: FASTQ directory not found: $FASTQ_DIR" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "ERROR: gzip not found" >&2; exit 1; }

mkdir -p "$RUN_DIR/logs" "$RUN_DIR/parts" "$RUN_DIR/split_timings" "$RUN_DIR/direct_manifests"
if [[ -n "$ASYNC_LAMBDA_FUNCTION" ]]; then
    mkdir -p "$LAMBDA_INVOKE_LOG_DIR"
    aws lambda get-function --function-name "$ASYNC_LAMBDA_FUNCTION" \
        --region "$AWS_REGION_VALUE" >/dev/null
fi

for bucket in "$FASTQ_BUCKET" "$INPUT_TXT_BUCKET"; do
    aws s3api head-bucket --bucket "$bucket" --region "$AWS_REGION_VALUE"
done

# Direct invocation is explicit and occurs after the manifest is durable.  An
# S3 notification would add a second invocation path, so refuse either mode
# when the input bucket has any notification configuration.
NOTIFICATION_JSON=$(aws s3api get-bucket-notification-configuration \
    --bucket "$INPUT_TXT_BUCKET" --region "$AWS_REGION_VALUE")
if ! jq -e 'length == 0' <<< "$NOTIFICATION_JSON" >/dev/null; then
    echo "ERROR: $INPUT_TXT_BUCKET has an event notification configuration; refusing upload-only run" >&2
    jq . <<< "$NOTIFICATION_JSON" >&2
    exit 1
fi

python3 "$SCRIPT_DIR/plan_ko_s3_transfers.py" \
    --manifest "$MANIFEST" --fastq-dir "$FASTQ_DIR" --check-local \
    --fastq-bucket "$FASTQ_BUCKET" --input-txt-bucket "$INPUT_TXT_BUCKET" \
    --s3-prefix "$S3_PREFIX" --region "$AWS_REGION_VALUE" --cores "$CORES" \
    --direct-gzip-max-bytes "$DIRECT_GZIP_MAX_BYTES" --split-lines "$SPLIT_LINES" \
    > "$RUN_DIR/transfer_plan.sh"

mapfile -t ORDERED_ROWS < <(
    tail -n +2 "$MANIFEST" | LC_ALL=C sort -t $'\t' -k11,11nr -k4,4
)
(( ${#ORDERED_ROWS[@]} == 130 )) || {
    echo "ERROR: expected 130 manifest rows, found ${#ORDERED_ROWS[@]}" >&2
    exit 1
}

declare -a SPLIT_ROWS=() DIRECT_ROWS=()
for row in "${ORDERED_ROWS[@]}"; do
    IFS=$'\t' read -r priority sample condition pair_name r1_name r1_bytes r1_url \
        r2_name r2_bytes r2_url combined_bytes <<< "$row"
    if (( combined_bytes < DIRECT_GZIP_MAX_BYTES )); then
        DIRECT_ROWS+=("$row")
    else
        SPLIT_ROWS+=("$row")
    fi
done

SPLIT_FILE_COUNT=$(( ${#SPLIT_ROWS[@]} * 2 ))
DECOMP_THREADS=1
FASTQ_DECOMPRESSOR=gzip
if (( SPLIT_FILE_COUNT < CORES )); then
    DECOMP_THREADS=$(( CORES / SPLIT_FILE_COUNT ))
    (( DECOMP_THREADS > 8 )) && DECOMP_THREADS=8
    if (( DECOMP_THREADS > 1 )) && command -v rapidgzip >/dev/null 2>&1; then
        FASTQ_DECOMPRESSOR=rapidgzip
    else
        DECOMP_THREADS=1
    fi
fi
PAIR_CORE_COST=$((2 * DECOMP_THREADS))
MAX_PAIR_WORKERS=$((CORES / PAIR_CORE_COST))
(( MAX_PAIR_WORKERS > 0 )) || MAX_PAIR_WORKERS=1

printf '%s\n' \
    "run_id=$RUN_ID" \
    "fastq_bucket=$FASTQ_BUCKET" \
    "input_txt_bucket=$INPUT_TXT_BUCKET" \
    "region=$AWS_REGION_VALUE" \
    "manifest=$MANIFEST" \
    "fastq_dir=$FASTQ_DIR" \
    "pairs=${#ORDERED_ROWS[@]}" \
    "split_pairs=${#SPLIT_ROWS[@]}" \
    "direct_pairs=${#DIRECT_ROWS[@]}" \
    "cores=$CORES" \
    "decompressor=$FASTQ_DECOMPRESSOR" \
    "threads_per_file=$DECOMP_THREADS" \
    "max_pair_workers=$MAX_PAIR_WORKERS" \
    "direct_gzip_max_bytes=$DIRECT_GZIP_MAX_BYTES" \
    "split_lines=$SPLIT_LINES" \
    "reads_per_shard=$((SPLIT_LINES / 4))" \
    "lambda_invocation=$([[ -n "$ASYNC_LAMBDA_FUNCTION" ]] && printf 'direct_async:%s' "$ASYNC_LAMBDA_FUNCTION" || printf 'disabled')" \
    > "$RUN_DIR/config.txt"

echo "Run: $RUN_ID"
echo "Pairs: ${#ORDERED_ROWS[@]} (${#SPLIT_ROWS[@]} split, ${#DIRECT_ROWS[@]} direct)"
echo "Static decompressor policy: $FASTQ_DECOMPRESSOR, $DECOMP_THREADS thread(s) per file"
echo "Pair admission: $MAX_PAIR_WORKERS initially; each stream releases cores independently"
echo "S3 notifications: disabled on $INPUT_TXT_BUCKET"
if [[ -n "$ASYNC_LAMBDA_FUNCTION" ]]; then
    echo "Lambda invocation: direct asynchronous Event invoke to $ASYNC_LAMBDA_FUNCTION"
else
    echo "Lambda invocation: disabled"
fi

invoke_lambda_async() {
    local manifest_key="$1" output_folder="$2" payload response status
    [[ -n "$ASYNC_LAMBDA_FUNCTION" ]] || return 0
    payload=$(jq -cn \
        --arg bucket "$INPUT_TXT_BUCKET" \
        --arg key "$manifest_key" \
        '{"version":"0","id":"direct-async-benchmark","detail-type":"Object Created","source":"aws.s3","detail":{"bucket":{"name":$bucket},"object":{"key":$key}}}')
    response=$(aws lambda invoke \
        --function-name "$ASYNC_LAMBDA_FUNCTION" \
        --invocation-type Event \
        --cli-binary-format raw-in-base64-out \
        --payload "$payload" \
        --region "$AWS_REGION_VALUE" \
        /dev/null)
    status=$(jq -r '.StatusCode // 0' <<< "$response")
    [[ "$status" == "202" ]] || {
        echo "ERROR: Lambda rejected async invocation for $manifest_key: $response" >&2
        return 1
    }
    printf '%s\n' "$response" > "$LAMBDA_INVOKE_LOG_DIR/${output_folder}.json"
}

publish_direct_pairs() {
    local row priority sample condition pair_name r1_name r1_bytes r1_url
    local r2_name r2_bytes r2_url combined_bytes r1_uri r2_uri manifest_path
    local r1_pid r2_pid
    for row in "${DIRECT_ROWS[@]}"; do
        IFS=$'\t' read -r priority sample condition pair_name r1_name r1_bytes r1_url \
            r2_name r2_bytes r2_url combined_bytes <<< "$row"
        r1_uri="s3://${FASTQ_BUCKET}/${S3_PREFIX}/${r1_name}"
        r2_uri="s3://${FASTQ_BUCKET}/${S3_PREFIX}/${r2_name}"
        aws s3 cp "$FASTQ_DIR/$r1_name" "$r1_uri" --region "$AWS_REGION_VALUE" \
            --only-show-errors --no-progress &
        r1_pid=$!
        aws s3 cp "$FASTQ_DIR/$r2_name" "$r2_uri" --region "$AWS_REGION_VALUE" \
            --only-show-errors --no-progress &
        r2_pid=$!
        wait "$r1_pid"
        wait "$r2_pid"
        manifest_path="$RUN_DIR/direct_manifests/${pair_name}_p0_input.txt"
        printf '%s\n%s\n' "$r1_uri" "$r2_uri" > "$manifest_path"
        manifest_key="${S3_PREFIX}/${pair_name}_p0_input.txt"
        aws s3 cp "$manifest_path" \
            "s3://${INPUT_TXT_BUCKET}/${manifest_key}" \
            --region "$AWS_REGION_VALUE" --only-show-errors --no-progress
        invoke_lambda_async "$manifest_key" "${pair_name}_p0"
        echo "$pair_name" >> "$RUN_DIR/direct_complete.txt"
    done
}

CORE_RELEASE_DIR=$(mktemp -d "$RUN_DIR/core_release.XXXXXX")
CORE_RELEASE_FIFO="$CORE_RELEASE_DIR/releases.fifo"
mkfifo "$CORE_RELEASE_FIFO"
exec {CORE_RELEASE_FD}<>"$CORE_RELEASE_FIFO"
AVAILABLE_CORES=$CORES
declare -a SPLIT_PIDS=()
DIRECT_PID=""

START_NS=$(date +%s%N)
printf '%s\n' "$START_NS" > "$RUN_DIR/start_ns.txt"
PIPELINE_START_FILE="$RUN_DIR/first_decompressor_start.ns"

for row in "${SPLIT_ROWS[@]}"; do
    while (( AVAILABLE_CORES < PAIR_CORE_COST )); do
        IFS= read -r released <&"$CORE_RELEASE_FD" || {
            echo "ERROR: core-release scheduler pipe closed unexpectedly" >&2
            exit 1
        }
        [[ "$released" =~ ^[1-9][0-9]*$ ]] || {
            echo "ERROR: invalid core-release notification: $released" >&2
            exit 1
        }
        AVAILABLE_CORES=$((AVAILABLE_CORES + released))
    done
    AVAILABLE_CORES=$((AVAILABLE_CORES - PAIR_CORE_COST))
    IFS=$'\t' read -r priority sample condition pair_name r1_name r1_bytes r1_url \
        r2_name r2_bytes r2_url combined_bytes <<< "$row"
    (
        CORE_RELEASE_FIFO="$CORE_RELEASE_FIFO" \
        FASTQ_DECOMPRESSOR="$FASTQ_DECOMPRESSOR" \
        DECOMP_THREADS="$DECOMP_THREADS" \
        PIPELINE_START_FILE="$PIPELINE_START_FILE" \
        ASYNC_LAMBDA_FUNCTION="$ASYNC_LAMBDA_FUNCTION" \
        LAMBDA_INVOKE_LOG_DIR="$LAMBDA_INVOKE_LOG_DIR" \
        SPLIT_TIMINGS_FILE="$RUN_DIR/split_timings/${pair_name}.csv" \
        bash "$SCRIPT_DIR/split_upload_trigger_local.sh" \
            "$FASTQ_BUCKET" "$FASTQ_DIR/$r1_name" "$FASTQ_DIR/$r2_name" \
            "$S3_PREFIX/$pair_name" "$INPUT_TXT_BUCKET" "$SPLIT_LINES" \
            > "$RUN_DIR/logs/${pair_name}.log" 2>&1
    ) &
    SPLIT_PIDS+=("$!")

    # Direct gzip pairs consume S3/network capacity, not decompressor cores.
    # Start them after the first full split batch has claimed its cores.
    if [[ -z "$DIRECT_PID" && ${#DIRECT_ROWS[@]} -gt 0 ]] && \
       (( ${#SPLIT_PIDS[@]} >= MAX_PAIR_WORKERS )); then
        publish_direct_pairs > "$RUN_DIR/logs/direct.log" 2>&1 &
        DIRECT_PID=$!
    fi
done

if [[ -z "$DIRECT_PID" && ${#DIRECT_ROWS[@]} -gt 0 ]]; then
    publish_direct_pairs > "$RUN_DIR/logs/direct.log" 2>&1 &
    DIRECT_PID=$!
fi

RC=0
for pid in "${SPLIT_PIDS[@]}"; do
    wait "$pid" || RC=1
done
if [[ -n "$DIRECT_PID" ]]; then
    wait "$DIRECT_PID" || RC=1
fi
exec {CORE_RELEASE_FD}>&-
rm -f -- "$CORE_RELEASE_FIFO"
rmdir -- "$CORE_RELEASE_DIR"
(( RC == 0 )) || { echo "ERROR: one or more upload workers failed; see $RUN_DIR/logs" >&2; exit 1; }

END_NS=$(date +%s%N)
printf '%s\n' "$END_NS" > "$RUN_DIR/end_ns.txt"
ELAPSED=$(awk -v start="$START_NS" -v end="$END_NS" \
    'BEGIN { printf "%.6f", (end - start) / 1000000000 }')
printf '%s\n' "$ELAPSED" > "$RUN_DIR/upload_wall_seconds.txt"
if [[ -f "$PIPELINE_START_FILE" ]]; then
    FIRST_DECOMPRESSOR_NS=$(<"$PIPELINE_START_FILE")
    elapsed_seconds=$(awk -v start="$FIRST_DECOMPRESSOR_NS" -v end="$END_NS" \
        'BEGIN { printf "%.6f", (end - start) / 1000000000 }')
    printf '%s\n' "$elapsed_seconds" > "$RUN_DIR/first_decompressor_to_upload_complete_seconds.txt"
fi

EXPECTED_MANIFESTS=${#DIRECT_ROWS[@]}
EXPECTED_FASTQS=$((${#DIRECT_ROWS[@]} * 2))
for row in "${SPLIT_ROWS[@]}"; do
    IFS=$'\t' read -r priority sample condition pair_name rest <<< "$row"
    parts=$(tail -n 1 "$RUN_DIR/logs/${pair_name}.log")
    [[ "$parts" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: missing part count for $pair_name" >&2
        exit 1
    }
    EXPECTED_MANIFESTS=$((EXPECTED_MANIFESTS + parts))
    EXPECTED_FASTQS=$((EXPECTED_FASTQS + 2 * parts))
done

aws s3api list-objects-v2 --bucket "$FASTQ_BUCKET" --prefix "$S3_PREFIX/" \
    --region "$AWS_REGION_VALUE" --query 'Contents[].[Key,Size]' --output text \
    > "$RUN_DIR/fastq_s3_inventory.tsv"
aws s3api list-objects-v2 --bucket "$INPUT_TXT_BUCKET" --prefix "$S3_PREFIX/" \
    --region "$AWS_REGION_VALUE" --query 'Contents[].[Key,Size]' --output text \
    > "$RUN_DIR/manifest_s3_inventory.tsv"
ACTUAL_FASTQS=$(wc -l < "$RUN_DIR/fastq_s3_inventory.tsv")
ACTUAL_MANIFESTS=$(wc -l < "$RUN_DIR/manifest_s3_inventory.tsv")
[[ "$ACTUAL_FASTQS" -eq "$EXPECTED_FASTQS" ]] || {
    echo "ERROR: expected $EXPECTED_FASTQS FASTQ objects, found $ACTUAL_FASTQS" >&2
    exit 1
}
[[ "$ACTUAL_MANIFESTS" -eq "$EXPECTED_MANIFESTS" ]] || {
    echo "ERROR: expected $EXPECTED_MANIFESTS manifest objects, found $ACTUAL_MANIFESTS" >&2
    exit 1
}
if [[ -n "$ASYNC_LAMBDA_FUNCTION" ]]; then
    ACTUAL_INVOCATIONS=$(find "$LAMBDA_INVOKE_LOG_DIR" -maxdepth 1 -type f -name '*.json' | wc -l)
    [[ "$ACTUAL_INVOCATIONS" -eq "$EXPECTED_MANIFESTS" ]] || {
        echo "ERROR: expected $EXPECTED_MANIFESTS accepted Lambda invocations, found $ACTUAL_INVOCATIONS" >&2
        exit 1
    }
else
    ACTUAL_INVOCATIONS=0
fi

FASTQ_BYTES=$(awk '{sum += $2} END {printf "%.0f", sum}' "$RUN_DIR/fastq_s3_inventory.tsv")
printf '%s\n' \
    "run_id=$RUN_ID" \
    "upload_wall_seconds=$ELAPSED" \
    "fastq_objects=$ACTUAL_FASTQS" \
    "manifest_objects=$ACTUAL_MANIFESTS" \
    "fastq_bytes=$FASTQ_BYTES" \
    "fastq_bucket=s3://$FASTQ_BUCKET/$S3_PREFIX/" \
    "manifest_bucket=s3://$INPUT_TXT_BUCKET/$S3_PREFIX/" \
    "lambda_invocations=$ACTUAL_INVOCATIONS" \
    "lambda_function=${ASYNC_LAMBDA_FUNCTION:-none}" \
    "cleanup_performed=no" \
    > "$RUN_DIR/result.txt"

echo "Upload-only wall time: $ELAPSED seconds"
echo "Validated: $ACTUAL_FASTQS FASTQ objects, $ACTUAL_MANIFESTS manifests, $FASTQ_BYTES FASTQ bytes"
echo "Evidence: $RUN_DIR"
