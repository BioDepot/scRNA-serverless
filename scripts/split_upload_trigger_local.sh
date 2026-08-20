#!/usr/bin/env bash

# Stream one local-NVMe R1/R2 gzip pair into FASTQ shards. A shard pair is
# uploaded as soon as both mates are complete, then its input.txt manifest is
# published to trigger Lambda while later shards are still being produced.

set -euo pipefail

[[ $# -ge 5 ]] || {
    echo "Usage: $0 FASTQ_BUCKET LOCAL_R1_GZ LOCAL_R2_GZ S3_BASE INPUT_TXT_BUCKET [SPLIT_LINES]" >&2
    exit 1
}

FASTQ_BUCKET="$1"
R1_GZ="$2"
R2_GZ="$3"
S3_BASE="$4"
INPUT_TXT_BUCKET="$5"
SPLIT_LINES="${6:-${SPLIT_LINES:-16000000}}"
DECOMP_THREADS="${DECOMP_THREADS:-8}"
AWS_REGION_VALUE="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
SPLIT_TIMINGS_FILE="${SPLIT_TIMINGS_FILE:-}"

[[ -f "$R1_GZ" ]] || { echo "ERROR: R1 gzip not found: $R1_GZ" >&2; exit 1; }
[[ -f "$R2_GZ" ]] || { echo "ERROR: R2 gzip not found: $R2_GZ" >&2; exit 1; }
[[ "$SPLIT_LINES" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: SPLIT_LINES must be positive" >&2; exit 1; }
(( SPLIT_LINES % 4 == 0 )) || { echo "ERROR: SPLIT_LINES must be divisible by 4" >&2; exit 1; }
[[ "$DECOMP_THREADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: DECOMP_THREADS must be positive" >&2; exit 1; }
command -v rapidgzip >/dev/null 2>&1 || { echo "ERROR: rapidgzip not found" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws not found" >&2; exit 1; }

LANE=$(basename "$S3_BASE")
WORK_DIR=$(mktemp -d "/mnt/nvme/${LANE}.stream.XXXXXX")
SUCCESS=0

cleanup() {
    if [[ -d "$WORK_DIR" ]]; then
        find "$WORK_DIR" -type f -delete 2>/dev/null || true
        rmdir "$WORK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

now_ns() {
    date +%s%N
}

elapsed_seconds() {
    local start_ns="$1" end_ns="$2"
    awk -v start="$start_ns" -v end="$end_ns" \
        'BEGIN { printf "%.6f", (end - start) / 1000000000 }'
}

record_timing() {
    local stage="$1" start_ns="$2" end_ns="$3" seconds
    seconds=$(elapsed_seconds "$start_ns" "$end_ns")
    echo "TIMING $stage=${seconds}s"
    if [[ -n "$SPLIT_TIMINGS_FILE" ]]; then
        if [[ ! -f "$SPLIT_TIMINGS_FILE" ]]; then
            mkdir -p "$(dirname "$SPLIT_TIMINGS_FILE")"
            printf 'stage,seconds\n' > "$SPLIT_TIMINGS_FILE"
        fi
        printf '%s,%s\n' "$stage" "$seconds" >> "$SPLIT_TIMINGS_FILE"
    fi
}

status_rc() {
    awk '{print $1}' "$1"
}

status_end_ns() {
    awk '{print $2}' "$1"
}

is_complete_shard() {
    local current="$1" next="$2" status_file="$3"
    [[ -f "$current" ]] || return 1
    [[ -f "$next" || -f "$status_file" ]]
}

TOTAL_START_NS=$(now_ns)
DECOMPRESS_START_NS="$TOTAL_START_NS"
R1_STATUS="$WORK_DIR/r1.status"
R2_STATUS="$WORK_DIR/r2.status"
R1_PREFIX="$WORK_DIR/r1_p"
R2_PREFIX="$WORK_DIR/r2_p"

echo "Starting $LANE from local NVMe with two rapidgzip -P $DECOMP_THREADS processes"
(
    set +e
    set -o pipefail
    rapidgzip -d -c -P "$DECOMP_THREADS" "$R1_GZ" | \
        split -l "$SPLIT_LINES" -d -a 4 --additional-suffix=.fastq - "$R1_PREFIX"
    rc=$?
    printf '%s %s\n' "$rc" "$(now_ns)" > "$R1_STATUS"
) &
R1_PRODUCER_PID=$!

(
    set +e
    set -o pipefail
    rapidgzip -d -c -P "$DECOMP_THREADS" "$R2_GZ" | \
        split -l "$SPLIT_LINES" -d -a 4 --additional-suffix=.fastq - "$R2_PREFIX"
    rc=$?
    printf '%s %s\n' "$rc" "$(now_ns)" > "$R2_STATUS"
) &
R2_PRODUCER_PID=$!

PAIR_INDEX=0
FIRST_FASTQ_UPLOAD_NS=""
LAST_FASTQ_UPLOAD_NS=""
FIRST_MANIFEST_UPLOAD_NS=""
LAST_MANIFEST_UPLOAD_NS=""

while true; do
    printf -v PADDED '%04d' "$PAIR_INDEX"
    printf -v NEXT_PADDED '%04d' "$((PAIR_INDEX + 1))"
    R1_SHARD="${R1_PREFIX}${PADDED}.fastq"
    R2_SHARD="${R2_PREFIX}${PADDED}.fastq"
    R1_NEXT="${R1_PREFIX}${NEXT_PADDED}.fastq"
    R2_NEXT="${R2_PREFIX}${NEXT_PADDED}.fastq"

    if is_complete_shard "$R1_SHARD" "$R1_NEXT" "$R1_STATUS" && \
       is_complete_shard "$R2_SHARD" "$R2_NEXT" "$R2_STATUS"; then
        FASTQ_UPLOAD_START_NS=$(now_ns)
        [[ -n "$FIRST_FASTQ_UPLOAD_NS" ]] || FIRST_FASTQ_UPLOAD_NS="$FASTQ_UPLOAD_START_NS"

        R1_URI="s3://${FASTQ_BUCKET}/${S3_BASE}_R1_001_p${PAIR_INDEX}.fastq"
        R2_URI="s3://${FASTQ_BUCKET}/${S3_BASE}_R2_001_p${PAIR_INDEX}.fastq"
        aws s3 cp "$R1_SHARD" "$R1_URI" --region "$AWS_REGION_VALUE" \
            --only-show-errors --no-progress &
        R1_UPLOAD_PID=$!
        aws s3 cp "$R2_SHARD" "$R2_URI" --region "$AWS_REGION_VALUE" \
            --only-show-errors --no-progress &
        R2_UPLOAD_PID=$!
        wait "$R1_UPLOAD_PID" || { echo "ERROR: R1 shard upload failed: $R1_URI" >&2; exit 1; }
        wait "$R2_UPLOAD_PID" || { echo "ERROR: R2 shard upload failed: $R2_URI" >&2; exit 1; }
        LAST_FASTQ_UPLOAD_NS=$(now_ns)

        MANIFEST="$WORK_DIR/${LANE}_p${PAIR_INDEX}_input.txt"
        printf '%s\n%s\n' "$R1_URI" "$R2_URI" > "$MANIFEST"
        MANIFEST_UPLOAD_START_NS=$(now_ns)
        [[ -n "$FIRST_MANIFEST_UPLOAD_NS" ]] || FIRST_MANIFEST_UPLOAD_NS="$MANIFEST_UPLOAD_START_NS"
        aws s3 cp "$MANIFEST" \
            "s3://${INPUT_TXT_BUCKET}/${S3_BASE}_p${PAIR_INDEX}_input.txt" \
            --region "$AWS_REGION_VALUE" --only-show-errors --no-progress
        LAST_MANIFEST_UPLOAD_NS=$(now_ns)

        record_timing "shard_p${PAIR_INDEX}_fastq_upload" \
            "$FASTQ_UPLOAD_START_NS" "$LAST_FASTQ_UPLOAD_NS"
        record_timing "shard_p${PAIR_INDEX}_manifest_publish" \
            "$MANIFEST_UPLOAD_START_NS" "$LAST_MANIFEST_UPLOAD_NS"
        echo "Published ${LANE}_p${PAIR_INDEX}; Lambda may start now"

        find "$WORK_DIR" -maxdepth 1 -type f \
            \( -name "r1_p${PADDED}.fastq" -o -name "r2_p${PADDED}.fastq" \
               -o -name "${LANE}_p${PAIR_INDEX}_input.txt" \) -delete
        PAIR_INDEX=$((PAIR_INDEX + 1))
        continue
    fi

    if [[ -f "$R1_STATUS" && -f "$R2_STATUS" ]]; then
        R1_RC=$(status_rc "$R1_STATUS")
        R2_RC=$(status_rc "$R2_STATUS")
        (( R1_RC == 0 )) || { echo "ERROR: R1 rapidgzip/split failed with $R1_RC" >&2; exit 1; }
        (( R2_RC == 0 )) || { echo "ERROR: R2 rapidgzip/split failed with $R2_RC" >&2; exit 1; }

        if [[ ! -f "$R1_SHARD" && ! -f "$R2_SHARD" ]]; then
            break
        fi
        if [[ ! -f "$R1_SHARD" || ! -f "$R2_SHARD" ]]; then
            echo "ERROR: R1/R2 shard-count mismatch at p${PAIR_INDEX}" >&2
            exit 1
        fi
    fi
    sleep 0.1
done

wait "$R1_PRODUCER_PID"
wait "$R2_PRODUCER_PID"

R1_END_NS=$(status_end_ns "$R1_STATUS")
R2_END_NS=$(status_end_ns "$R2_STATUS")
if (( R1_END_NS > R2_END_NS )); then
    DECOMPRESS_END_NS="$R1_END_NS"
else
    DECOMPRESS_END_NS="$R2_END_NS"
fi

(( PAIR_INDEX > 0 )) || { echo "ERROR: no FASTQ shard pairs produced" >&2; exit 1; }
record_timing "decompress_and_split_fastq" "$DECOMPRESS_START_NS" "$DECOMPRESS_END_NS"
record_timing "fastq_upload_window" "$FIRST_FASTQ_UPLOAD_NS" "$LAST_FASTQ_UPLOAD_NS"
record_timing "lambda_manifest_publish_window" "$FIRST_MANIFEST_UPLOAD_NS" "$LAST_MANIFEST_UPLOAD_NS"
record_timing "nvme_to_last_lambda_trigger" "$TOTAL_START_NS" "$LAST_MANIFEST_UPLOAD_NS"
record_timing "lane_streaming_total" "$TOTAL_START_NS" "$(now_ns)"

SUCCESS=1
# Keep the part count as the last line; e2e_serverless_pbmc.sh consumes it.
echo "$PAIR_INDEX"
