#!/usr/bin/env bash

# Wait synchronously for a known set of Lambda Piscem shards and materialize
# their S3 map.rad objects directly into one local RAD file.
#
# This script is deliberately non-destructive: it never removes or overwrites
# an S3 object.  The Lambda output.txt object is treated as the completion
# marker because map.py uploads it only after all files in that shard have been
# uploaded.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  synchronous_s3_rad_materialize.sh \
    --output-bucket BUCKET \
    --expected-folders FILE \
    --output FILE \
    [options]

Required arguments:
  --output-bucket BUCKET     Lambda Piscem output bucket.
  --expected-folders FILE    One expected Lambda output folder per line, for
                             example pbmc_1k_v3_S1_L001_p0.
  --output FILE              Final local map.rad path (preferably on NVMe).

Options:
  --region REGION            AWS region (default: AWS_REGION or us-east-2).
  --profile PROFILE          Named AWS profile. Omit on an EC2 instance role.
  --rad-prefix PREFIX        Prefix above each shard folder
                             (default: piscem_output).
  --threads N                Materializer threads (default: 32).
  --poll-seconds N           S3 polling interval (default: 5).
  --timeout-seconds N        Maximum Lambda readiness wait (default: 1800).
  --not-before TIME          Ignore output objects older than this ISO-8601
                             time. Use the time recorded before input.txt files
                             were uploaded when a bucket may contain old data.
  --manifest FILE            Ordered RAD URI manifest output
                             (default: OUTPUT.shards.txt).
  --timings-file FILE        Stage timing CSV
                             (default: OUTPUT.timings.csv).
  --materializer FILE        Materializer executable
                             (default: s3-rad-materialize).
  --overwrite                Replace an existing local output atomically.
  --fsync                    Ask the materializer to fsync before publication.
  -h, --help                 Show this help.

The expected-folder file is the synchronization contract. The script waits
for both piscem_output/FOLDER/map.rad and the later FOLDER/output.txt marker
for every listed folder, writes an ordered manifest using sort -V ordering,
and then invokes the parallel ranged-S3 materializer.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

now_ns() {
    date +%s%N
}

elapsed_seconds() {
    local start_ns="$1" end_ns="$2"
    awk -v start="$start_ns" -v end="$end_ns" \
        'BEGIN { printf "%.6f", (end - start) / 1000000000 }'
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

OUTPUT_BUCKET=""
EXPECTED_FOLDERS_FILE=""
OUTPUT_FILE=""
AWS_REGION_VALUE="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
AWS_PROFILE_VALUE="${AWS_PROFILE:-}"
RAD_PREFIX="piscem_output"
THREADS="${THREADS:-32}"
POLL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
TIMEOUT_SECONDS="${PROCESS_FASTQ_TIMEOUT_SEC:-1800}"
NOT_BEFORE=""
MANIFEST_FILE=""
TIMINGS_FILE=""
MATERIALIZER="${MATERIALIZER:-s3-rad-materialize}"
OVERWRITE=0
DO_FSYNC=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-bucket)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            OUTPUT_BUCKET="$2"; shift 2 ;;
        --expected-folders)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            EXPECTED_FOLDERS_FILE="$2"; shift 2 ;;
        --output)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            OUTPUT_FILE="$2"; shift 2 ;;
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
        --manifest)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            MANIFEST_FILE="$2"; shift 2 ;;
        --timings-file)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            TIMINGS_FILE="$2"; shift 2 ;;
        --materializer)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            MATERIALIZER="$2"; shift 2 ;;
        --overwrite)
            OVERWRITE=1; shift ;;
        --fsync)
            DO_FSYNC=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "unknown argument: $1" ;;
    esac
done

[[ -n "$OUTPUT_BUCKET" ]] || die "--output-bucket is required"
[[ -n "$EXPECTED_FOLDERS_FILE" ]] || die "--expected-folders is required"
[[ -n "$OUTPUT_FILE" ]] || die "--output is required"
[[ -n "$AWS_REGION_VALUE" ]] || die "--region or AWS_REGION is required"
[[ -n "$RAD_PREFIX" ]] || die "--rad-prefix cannot be empty"
[[ -f "$EXPECTED_FOLDERS_FILE" ]] || die "expected-folder file not found: $EXPECTED_FOLDERS_FILE"
is_positive_integer "$THREADS" || die "--threads must be a positive integer"
is_positive_integer "$POLL_SECONDS" || die "--poll-seconds must be a positive integer"
is_positive_integer "$TIMEOUT_SECONDS" || die "--timeout-seconds must be a positive integer"
command -v aws >/dev/null 2>&1 || die "required command not found: aws"
command -v "$MATERIALIZER" >/dev/null 2>&1 || \
    die "materializer not found: $MATERIALIZER (run install_scripts/install_s3_rad_materializer.sh)"

if [[ -e "$OUTPUT_FILE" && "$OVERWRITE" -ne 1 ]]; then
    die "output already exists: $OUTPUT_FILE (pass --overwrite to replace it)"
fi

NOT_BEFORE_EPOCH=""
if [[ -n "$NOT_BEFORE" ]]; then
    NOT_BEFORE_EPOCH=$(date -u -d "$NOT_BEFORE" +%s 2>/dev/null) || \
        die "--not-before is not a valid date: $NOT_BEFORE"
fi

OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
mkdir -p "$OUTPUT_DIR"
MANIFEST_FILE="${MANIFEST_FILE:-${OUTPUT_FILE}.shards.txt}"
TIMINGS_FILE="${TIMINGS_FILE:-${OUTPUT_FILE}.timings.csv}"
mkdir -p "$(dirname "$MANIFEST_FILE")" "$(dirname "$TIMINGS_FILE")"

mapfile -t EXPECTED_FOLDERS < <(
    sed 's/\r$//' "$EXPECTED_FOLDERS_FILE" | awk 'NF { print }' | LC_ALL=C sort -V -u
)
[[ ${#EXPECTED_FOLDERS[@]} -gt 0 ]] || die "no expected folders in $EXPECTED_FOLDERS_FILE"

declare -A EXPECTED_SET=()
for folder in "${EXPECTED_FOLDERS[@]}"; do
    [[ "$folder" != */* ]] || die "expected folder must not contain '/': $folder"
    [[ "$folder" != "." && "$folder" != ".." ]] || die "invalid expected folder: $folder"
    EXPECTED_SET["$folder"]=1
done

AWS_ARGS=(--region "$AWS_REGION_VALUE")
MATERIALIZER_AWS_ARGS=(--region "$AWS_REGION_VALUE")
if [[ -n "$AWS_PROFILE_VALUE" ]]; then
    AWS_ARGS+=(--profile "$AWS_PROFILE_VALUE")
    MATERIALIZER_AWS_ARGS+=(--profile "$AWS_PROFILE_VALUE")
fi

printf 'stage,start_utc,end_utc,seconds\n' > "$TIMINGS_FILE"
record_timing() {
    local stage="$1" start_ns="$2" start_utc="$3" end_ns end_utc seconds
    end_ns=$(now_ns)
    end_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    seconds=$(elapsed_seconds "$start_ns" "$end_ns")
    printf '%s,%s,%s,%s\n' "$stage" "$start_utc" "$end_utc" "$seconds" >> "$TIMINGS_FILE"
    log "TIMING $stage=${seconds}s"
}

TOTAL_START_NS=$(now_ns)
TOTAL_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

WAIT_START_NS=$(now_ns)
WAIT_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WAIT_START_EPOCH=$(date +%s)
LAST_PROGRESS=""

log "Waiting for ${#EXPECTED_FOLDERS[@]} Lambda RAD shard(s) in s3://${OUTPUT_BUCKET}/${RAD_PREFIX}/"
if [[ -n "$NOT_BEFORE" ]]; then
    log "Ignoring output objects older than $NOT_BEFORE"
fi

while true; do
    LISTING=""
    if ! LISTING=$(aws s3api list-objects-v2 \
        --bucket "$OUTPUT_BUCKET" \
        --prefix "${RAD_PREFIX}/" \
        --query 'Contents[].[Key,LastModified]' \
        --output text "${AWS_ARGS[@]}" 2>&1); then
        log "S3 listing failed; retrying: $(printf '%s' "$LISTING" | tail -1)"
        sleep "$POLL_SECONDS"
        continue
    fi

    declare -A HAVE_RAD=() HAVE_MARKER=()
    while IFS=$'\t' read -r key modified _rest; do
        [[ -n "${key:-}" && -n "${modified:-}" ]] || continue

        if [[ -n "$NOT_BEFORE_EPOCH" ]]; then
            object_epoch=$(date -u -d "$modified" +%s 2>/dev/null || echo 0)
            (( object_epoch >= NOT_BEFORE_EPOCH )) || continue
        fi

        relative="${key#${RAD_PREFIX}/}"
        if [[ "$relative" == */map.rad ]]; then
            folder="${relative%/map.rad}"
            [[ -n "${EXPECTED_SET[$folder]:-}" ]] && HAVE_RAD["$folder"]=1
        elif [[ "$relative" == */output.txt ]]; then
            folder="${relative%/output.txt}"
            [[ -n "${EXPECTED_SET[$folder]:-}" ]] && HAVE_MARKER["$folder"]=1
        fi
    done <<< "$LISTING"

    READY=0
    for folder in "${EXPECTED_FOLDERS[@]}"; do
        if [[ -n "${HAVE_RAD[$folder]:-}" && -n "${HAVE_MARKER[$folder]:-}" ]]; then
            READY=$((READY + 1))
        fi
    done

    PROGRESS="${READY}/${#EXPECTED_FOLDERS[@]} (RAD=${#HAVE_RAD[@]}, marker=${#HAVE_MARKER[@]})"
    if [[ "$PROGRESS" != "$LAST_PROGRESS" ]]; then
        log "Lambda output progress: $PROGRESS"
        LAST_PROGRESS="$PROGRESS"
    fi

    if (( READY == ${#EXPECTED_FOLDERS[@]} )); then
        break
    fi

    ELAPSED=$(( $(date +%s) - WAIT_START_EPOCH ))
    if (( ELAPSED >= TIMEOUT_SECONDS )); then
        echo "Missing or incomplete Lambda shards:" >&2
        for folder in "${EXPECTED_FOLDERS[@]}"; do
            if [[ -z "${HAVE_RAD[$folder]:-}" || -z "${HAVE_MARKER[$folder]:-}" ]]; then
                printf '  %s (map.rad=%s, output.txt=%s)\n' \
                    "$folder" \
                    "$([[ -n "${HAVE_RAD[$folder]:-}" ]] && echo yes || echo no)" \
                    "$([[ -n "${HAVE_MARKER[$folder]:-}" ]] && echo yes || echo no)" >&2
            fi
        done
        die "timed out after ${TIMEOUT_SECONDS}s waiting for Lambda RAD outputs"
    fi
    sleep "$POLL_SECONDS"
done

record_timing "wait_for_lambda_rad_outputs" "$WAIT_START_NS" "$WAIT_START_UTC"

MANIFEST_START_NS=$(now_ns)
MANIFEST_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    for folder in "${EXPECTED_FOLDERS[@]}"; do
        printf 's3://%s/%s/%s/map.rad\n' "$OUTPUT_BUCKET" "$RAD_PREFIX" "$folder"
    done
} > "$MANIFEST_FILE"
record_timing "build_ordered_rad_manifest" "$MANIFEST_START_NS" "$MANIFEST_START_UTC"

MATERIALIZE_START_NS=$(now_ns)
MATERIALIZE_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MATERIALIZER_CMD=(
    "$MATERIALIZER"
    --manifest "$MANIFEST_FILE"
    --output "$OUTPUT_FILE"
    "${MATERIALIZER_AWS_ARGS[@]}"
    --threads "$THREADS"
)
(( OVERWRITE == 1 )) && MATERIALIZER_CMD+=(--overwrite)
(( DO_FSYNC == 1 )) && MATERIALIZER_CMD+=(--fsync)

log "Materializing ${#EXPECTED_FOLDERS[@]} S3 RAD shard(s) with $THREADS threads"
"${MATERIALIZER_CMD[@]}"
record_timing "parallel_s3_rad_materializer" "$MATERIALIZE_START_NS" "$MATERIALIZE_START_UTC"

[[ -s "$OUTPUT_FILE" ]] || die "materializer returned success but output is missing or empty: $OUTPUT_FILE"
record_timing "synchronous_rad_total" "$TOTAL_START_NS" "$TOTAL_START_UTC"

OUTPUT_BYTES=$(stat --format=%s "$OUTPUT_FILE" 2>/dev/null || stat -f%z "$OUTPUT_FILE")
log "Final RAD: $OUTPUT_FILE ($OUTPUT_BYTES bytes)"
log "Ordered manifest: $MANIFEST_FILE"
log "Stage timings: $TIMINGS_FILE"
