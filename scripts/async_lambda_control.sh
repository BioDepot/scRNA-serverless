#!/usr/bin/env bash

# Inspect or join an async-submit run. This script is non-destructive: it only
# reads S3 state, waits for completion markers, and optionally materializes the
# final RAD file.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  async_lambda_control.sh --state FILE status [--verbose]
  async_lambda_control.sh --state FILE wait [--poll-seconds N] [--timeout-seconds N]
  async_lambda_control.sh --state FILE materialize --output FILE [options]

Commands:
  status          Report expected, claimed, RAD-ready, and completed shards.
  wait            Poll until every expected completion marker is present.
  materialize     Wait and build the final RAD with s3-rad-materialize.

Options:
  --state FILE              async_state.env written by e2e_serverless_pbmc.sh.
  --output FILE             Required for materialize; preferably on NVMe.
  --threads N               Materializer threads (default: 32).
  --poll-seconds N          Poll interval (default: 1).
  --timeout-seconds N       Wait timeout (default: 43200).
  --timings-file FILE       Materializer stage timings.
  --overwrite               Atomically replace an existing local RAD.
  --verbose                 List incomplete folders during status/wait.
  -h, --help                Show this help.

If EXPECTED_FOLDERS_FILE no longer exists locally, the controller retrieves the
copy published under s3://OUTPUT_QUANT_BUCKET/RUN_ID/expected_rad_folders.txt.
No command deletes or overwrites an S3 object.
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

STATE_FILE=""
COMMAND=""
OUTPUT_FILE=""
THREADS="${MATERIALIZER_THREADS:-32}"
POLL_SECONDS="${POLL_INTERVAL_SECONDS:-1}"
TIMEOUT_SECONDS="${PROCESS_FASTQ_TIMEOUT_SEC:-43200}"
TIMINGS_FILE=""
OVERWRITE=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            STATE_FILE="$2"; shift 2 ;;
        --output)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            OUTPUT_FILE="$2"; shift 2 ;;
        --threads)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            THREADS="$2"; shift 2 ;;
        --poll-seconds)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            POLL_SECONDS="$2"; shift 2 ;;
        --timeout-seconds)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            TIMEOUT_SECONDS="$2"; shift 2 ;;
        --timings-file)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            TIMINGS_FILE="$2"; shift 2 ;;
        --overwrite)
            OVERWRITE=1; shift ;;
        --verbose)
            VERBOSE=1; shift ;;
        status|wait|materialize)
            [[ -z "$COMMAND" ]] || die "only one command may be selected"
            COMMAND="$1"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "unknown argument: $1" ;;
    esac
done

[[ -n "$STATE_FILE" ]] || die "--state is required"
[[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE"
[[ -n "$COMMAND" ]] || die "status, wait, or materialize is required"
is_positive_integer "$THREADS" || die "--threads must be a positive integer"
is_positive_integer "$POLL_SECONDS" || die "--poll-seconds must be a positive integer"
is_positive_integer "$TIMEOUT_SECONDS" || die "--timeout-seconds must be a positive integer"
command -v aws >/dev/null 2>&1 || die "required command not found: aws"

RUN_ID=""
AWS_REGION_VALUE=""
OUTPUT_MAP_BUCKET=""
OUTPUT_QUANT_BUCKET=""
EXPECTED_FOLDERS_FILE=""
NOT_BEFORE=""
LAMBDA_FUNCTION=""
S3_CLAIM_PREFIX="piscem_claims"

# Parse only the known keys; do not source executable shell from a state file.
while IFS='=' read -r key value; do
    case "$key" in
        RUN_ID) RUN_ID="$value" ;;
        AWS_REGION) AWS_REGION_VALUE="$value" ;;
        OUTPUT_MAP_BUCKET) OUTPUT_MAP_BUCKET="$value" ;;
        OUTPUT_QUANT_BUCKET) OUTPUT_QUANT_BUCKET="$value" ;;
        EXPECTED_FOLDERS_FILE) EXPECTED_FOLDERS_FILE="$value" ;;
        NOT_BEFORE) NOT_BEFORE="$value" ;;
        LAMBDA_FUNCTION) LAMBDA_FUNCTION="$value" ;;
        S3_CLAIM_PREFIX) S3_CLAIM_PREFIX="${value%/}" ;;
    esac
done < "$STATE_FILE"

[[ -n "$RUN_ID" ]] || die "RUN_ID missing from $STATE_FILE"
[[ -n "$AWS_REGION_VALUE" ]] || die "AWS_REGION missing from $STATE_FILE"
[[ -n "$OUTPUT_MAP_BUCKET" ]] || die "OUTPUT_MAP_BUCKET missing from $STATE_FILE"
[[ -n "$OUTPUT_QUANT_BUCKET" ]] || die "OUTPUT_QUANT_BUCKET missing from $STATE_FILE"

if [[ ! -f "$EXPECTED_FOLDERS_FILE" ]]; then
    STATE_DIR=$(cd "$(dirname "$STATE_FILE")" && pwd)
    EXPECTED_FOLDERS_FILE="$STATE_DIR/expected_rad_folders.txt"
    log "Retrieving expected-folder contract from S3"
    aws s3 cp \
        "s3://${OUTPUT_QUANT_BUCKET}/${RUN_ID}/expected_rad_folders.txt" \
        "$EXPECTED_FOLDERS_FILE" --region "$AWS_REGION_VALUE" --only-show-errors
fi

mapfile -t EXPECTED_FOLDERS < <(
    sed 's/\r$//' "$EXPECTED_FOLDERS_FILE" | awk 'NF {print}' | LC_ALL=C sort -V -u
)
[[ ${#EXPECTED_FOLDERS[@]} -gt 0 ]] || die "no expected folders found"

declare -A EXPECTED_SET=()
for folder in "${EXPECTED_FOLDERS[@]}"; do
    EXPECTED_SET["$folder"]=1
done

READY=0
RAD_COUNT=0
MARKER_COUNT=0
CLAIM_COUNT=0
INCOMPLETE=()

status_once() {
    local listing key relative folder claim_glob
    claim_glob="${S3_CLAIM_PREFIX}/*.json"
    listing=$(aws s3api list-objects-v2 \
        --bucket "$OUTPUT_MAP_BUCKET" \
        --query 'Contents[].[Key,LastModified]' \
        --output text --region "$AWS_REGION_VALUE")

    declare -A have_rad=() have_marker=() have_claim=()
    while IFS=$'\t' read -r key _modified _rest; do
        [[ -n "${key:-}" ]] || continue
        if [[ "$key" == piscem_output/*/map.rad ]]; then
            relative="${key#piscem_output/}"
            folder="${relative%/map.rad}"
            [[ -n "${EXPECTED_SET[$folder]:-}" ]] && have_rad["$folder"]=1
        elif [[ "$key" == piscem_output/*/output.txt ]]; then
            relative="${key#piscem_output/}"
            folder="${relative%/output.txt}"
            [[ -n "${EXPECTED_SET[$folder]:-}" ]] && have_marker["$folder"]=1
        elif [[ "$key" == $claim_glob ]]; then
            folder="${key#${S3_CLAIM_PREFIX}/}"
            folder="${folder%.json}"
            [[ -n "${EXPECTED_SET[$folder]:-}" ]] && have_claim["$folder"]=1
        fi
    done <<< "$listing"

    READY=0
    RAD_COUNT=0
    MARKER_COUNT=0
    CLAIM_COUNT=0
    INCOMPLETE=()
    for folder in "${EXPECTED_FOLDERS[@]}"; do
        [[ -n "${have_rad[$folder]:-}" ]] && RAD_COUNT=$((RAD_COUNT + 1))
        [[ -n "${have_marker[$folder]:-}" ]] && MARKER_COUNT=$((MARKER_COUNT + 1))
        [[ -n "${have_claim[$folder]:-}" ]] && CLAIM_COUNT=$((CLAIM_COUNT + 1))
        if [[ -n "${have_rad[$folder]:-}" && -n "${have_marker[$folder]:-}" ]]; then
            READY=$((READY + 1))
        else
            INCOMPLETE+=("$folder")
        fi
    done

    log "Async progress: ready=${READY}/${#EXPECTED_FOLDERS[@]} rad=${RAD_COUNT} marker=${MARKER_COUNT} claims=${CLAIM_COUNT}"
    if (( VERBOSE == 1 && ${#INCOMPLETE[@]} > 0 )); then
        printf '  incomplete: %s\n' "${INCOMPLETE[@]}"
    fi
}

wait_for_completion() {
    local started now elapsed last_ready=-1
    started=$(date +%s)
    while true; do
        status_once
        if (( READY == ${#EXPECTED_FOLDERS[@]} )); then
            log "All asynchronous Lambda shards are complete"
            return 0
        fi
        now=$(date +%s)
        elapsed=$((now - started))
        (( elapsed < TIMEOUT_SECONDS )) || \
            die "timeout after ${elapsed}s; ${#INCOMPLETE[@]} shard(s) incomplete"
        if (( READY == last_ready )); then
            sleep "$POLL_SECONDS"
        else
            last_ready=$READY
            sleep "$POLL_SECONDS"
        fi
    done
}

case "$COMMAND" in
    status)
        status_once
        (( READY == ${#EXPECTED_FOLDERS[@]} ))
        ;;
    wait)
        wait_for_completion
        ;;
    materialize)
        [[ -n "$OUTPUT_FILE" ]] || die "--output is required for materialize"
        args=(
            --output-bucket "$OUTPUT_MAP_BUCKET"
            --expected-folders "$EXPECTED_FOLDERS_FILE"
            --output "$OUTPUT_FILE"
            --region "$AWS_REGION_VALUE"
            --threads "$THREADS"
            --poll-seconds "$POLL_SECONDS"
            --timeout-seconds "$TIMEOUT_SECONDS"
        )
        [[ -n "$NOT_BEFORE" ]] && args+=(--not-before "$NOT_BEFORE")
        [[ -n "$TIMINGS_FILE" ]] && args+=(--timings-file "$TIMINGS_FILE")
        (( OVERWRITE == 1 )) && args+=(--overwrite)
        exec bash "$(dirname "$0")/synchronous_s3_rad_materialize.sh" "${args[@]}"
        ;;
esac
