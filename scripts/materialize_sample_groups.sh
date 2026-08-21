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
  --threads N                Total RAD and companion transfer concurrency
                             across all samples (default: 32).
  --sample-workers N         Maximum samples materialized concurrently
                             (default: 4). Threads are divided evenly among
                             active sample slots.
  --poll-seconds N           S3 polling interval (default: 1).
  --timeout-seconds N        Global readiness timeout (default: 43200).
  --not-before TIME          Ignore output objects older than this time.
  --readiness-inventory FILE Use a previously captured complete global
                             readiness inventory instead of polling S3.
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
SAMPLE_WORKERS="${SAMPLE_MATERIALIZER_WORKERS:-4}"
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
        --sample-workers)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            SAMPLE_WORKERS="$2"; shift 2 ;;
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
is_positive_integer "$SAMPLE_WORKERS" || die "--sample-workers must be a positive integer"
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

if (( SAMPLE_WORKERS > ${#SAMPLES[@]} )); then
    SAMPLE_WORKERS=${#SAMPLES[@]}
fi
if (( SAMPLE_WORKERS > THREADS )); then
    SAMPLE_WORKERS=$THREADS
fi
SAMPLE_THREADS=$((THREADS / SAMPLE_WORKERS))
(( SAMPLE_THREADS > 0 )) || SAMPLE_THREADS=1

declare -A SAMPLE_SHARDS=()

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
    mkdir -p "$sample_dir"
    expected_file="$sample_dir/expected_rad_folders.txt"
    awk -F '\t' -v sample="$sample" \
        'NR > 1 && $1 == sample { print $2 }' "$CONTRACT_FILE" > "$expected_file"
    shard_count=$(awk 'NF {n++} END {print n+0}' "$expected_file")
    (( shard_count > 0 )) || die "sample $sample has no expected folders"
    SAMPLE_SHARDS["$sample"]=$shard_count
done

AWS_ARGS=(--region "$AWS_REGION_VALUE")
[[ -n "$AWS_PROFILE_VALUE" ]] && AWS_ARGS+=(--profile "$AWS_PROFILE_VALUE")

download_unmapped_counts() {
    local expected_file="$1" output_file="$2" transfer_threads="$3"
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
        if (( ${#pids[@]} >= transfer_threads )); then
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

materialize_one_sample() {
    local sample="$1" readiness_inventory="$2"
    local sample_dir="$OUTPUT_DIR/$sample"
    local expected_file="$sample_dir/expected_rad_folders.txt"
    local shard_count="${SAMPLE_SHARDS[$sample]}"
    local -a materialize_args
    materialize_args=(
        --output-bucket "$OUTPUT_BUCKET"
        --expected-folders "$expected_file"
        --output "$sample_dir/map.rad"
        --region "$AWS_REGION_VALUE"
        --rad-prefix "$RAD_PREFIX"
        --threads "$SAMPLE_THREADS"
        --poll-seconds "$POLL_SECONDS"
        --timeout-seconds "$TIMEOUT_SECONDS"
        --manifest "$sample_dir/map.rad.shards.txt"
        --timings-file "$sample_dir/map.rad.timings.csv"
        --materializer "$MATERIALIZER"
        --readiness-inventory "$readiness_inventory"
    )
    [[ -n "$AWS_PROFILE_VALUE" ]] && materialize_args+=(--profile "$AWS_PROFILE_VALUE")
    [[ -n "$NOT_BEFORE" ]] && materialize_args+=(--not-before "$NOT_BEFORE")
    (( OVERWRITE == 1 )) && materialize_args+=(--overwrite)

    log "Materializing sample $sample from $shard_count Lambda shard(s) with $SAMPLE_THREADS threads"
    bash "$SINGLE_MATERIALIZER" "${materialize_args[@]}" || return 1
    if (( RAD_ONLY == 0 )); then
        log "Combining sample $sample unmapped barcode counts"
        download_unmapped_counts "$expected_file" "$sample_dir/unmapped_bc_count.bin" \
            "$SAMPLE_THREADS" || return 1
    fi
}

declare -A EXPECTED=() HAVE_RAD=() HAVE_MARKER=()
declare -A SAMPLE_STATE=() SAMPLE_READY_NS=() SAMPLE_START_NS=()
declare -A SAMPLE_PID=() SAMPLE_STATUS_FILE=()
for sample in "${SAMPLES[@]}"; do
    SAMPLE_STATE["$sample"]=pending
done
while IFS= read -r folder; do
    [[ -n "$folder" ]] || continue
    EXPECTED["$folder"]=1
done < "$EXPECTED_FOLDERS_FILE"
(( ${#EXPECTED[@]} > 0 )) || die "expected-folder contract is empty"

NOT_BEFORE_EPOCH=""
if [[ -n "$NOT_BEFORE" ]]; then
    NOT_BEFORE_EPOCH=$(date -u -d "$NOT_BEFORE" +%s 2>/dev/null) || \
        die "--not-before is not a valid date: $NOT_BEFORE"
fi

COORDINATOR_START_NS=$(date +%s%N)
COORDINATOR_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COORDINATOR_START_EPOCH=$(date +%s)
LAST_LIST_EPOCH=0
LIST_CALLS=0
READY_SHARDS=0
LAST_READY_SHARDS=-1
ALL_SHARDS_READY=0
RUNNING=0
COMPLETED=0
MAX_RUNNING=0
FAILED_SAMPLE=""
LISTING=""
FIRST_SAMPLE_START_NS=""
ALL_SHARDS_READY_NS=""
LAST_SAMPLE_END_NS=""
SUPPLIED_INVENTORY=0
if [[ -n "$READINESS_INVENTORY" ]]; then
    SUPPLIED_INVENTORY=1
    log "Using supplied complete readiness inventory: $READINESS_INVENTORY"
fi

printf 'sample\tshards\tready_ns\tstart_ns\tend_ns\tseconds\tthreads\tstatus\n' \
    > "$OUTPUT_DIR/sample-materialization-timings.tsv"

refresh_readiness() {
    local key modified relative folder object_epoch object_kind sample sample_ready
    local now_ns_value partial
    if (( SUPPLIED_INVENTORY == 1 )); then
        LISTING=$(<"$READINESS_INVENTORY")
    elif ! LISTING=$(aws s3api list-objects-v2 \
        --bucket "$OUTPUT_BUCKET" --prefix "${RAD_PREFIX}/" \
        --query 'Contents[].[Key,LastModified]' --output text \
        "${AWS_ARGS[@]}" 2>&1); then
        log "Global S3 readiness listing failed; retrying: $(printf '%s' "$LISTING" | tail -1)"
        return 1
    else
        LIST_CALLS=$((LIST_CALLS + 1))
    fi

    HAVE_RAD=()
    HAVE_MARKER=()
    while IFS=$'\t' read -r key modified _rest; do
        [[ -n "${key:-}" && -n "${modified:-}" ]] || continue
        relative="${key#${RAD_PREFIX}/}"
        if [[ "$relative" == */map.rad ]]; then
            folder="${relative%/map.rad}"
            [[ -n "${EXPECTED[$folder]:-}" ]] || continue
            object_kind=rad
        elif [[ "$relative" == */output.txt ]]; then
            folder="${relative%/output.txt}"
            [[ -n "${EXPECTED[$folder]:-}" ]] || continue
            object_kind=marker
        else
            continue
        fi
        if [[ -n "$NOT_BEFORE_EPOCH" ]]; then
            object_epoch=$(date -u -d "$modified" +%s 2>/dev/null || echo 0)
            (( object_epoch >= NOT_BEFORE_EPOCH )) || continue
        fi
        if [[ "$object_kind" == rad ]]; then
            HAVE_RAD["$folder"]=1
        else
            HAVE_MARKER["$folder"]=1
        fi
    done <<< "$LISTING"

    READY_SHARDS=0
    for folder in "${!EXPECTED[@]}"; do
        [[ -n "${HAVE_RAD[$folder]:-}" && -n "${HAVE_MARKER[$folder]:-}" ]] && \
            READY_SHARDS=$((READY_SHARDS + 1))
    done
    now_ns_value=$(date +%s%N)
    for sample in "${SAMPLES[@]}"; do
        [[ "${SAMPLE_STATE[$sample]}" == pending ]] || continue
        sample_ready=1
        while IFS= read -r folder; do
            [[ -n "$folder" ]] || continue
            if [[ -z "${HAVE_RAD[$folder]:-}" || -z "${HAVE_MARKER[$folder]:-}" ]]; then
                sample_ready=0
                break
            fi
        done < "$OUTPUT_DIR/$sample/expected_rad_folders.txt"
        if (( sample_ready == 1 )); then
            SAMPLE_STATE["$sample"]=ready
            SAMPLE_READY_NS["$sample"]=$now_ns_value
            partial="$OUTPUT_DIR/$sample/readiness-inventory.tsv.partial.$$"
            printf '%s\n' "$LISTING" > "$partial"
            mv -f -- "$partial" "$OUTPUT_DIR/$sample/readiness-inventory.tsv"
        fi
    done
    if (( READY_SHARDS != LAST_READY_SHARDS )); then
        log "Global Lambda output progress: $READY_SHARDS/${#EXPECTED[@]} (S3 listings=$LIST_CALLS)"
        LAST_READY_SHARDS=$READY_SHARDS
    fi
    if (( READY_SHARDS == ${#EXPECTED[@]} )); then
        ALL_SHARDS_READY=1
        [[ -n "$ALL_SHARDS_READY_NS" ]] || ALL_SHARDS_READY_NS=$now_ns_value
        if (( SUPPLIED_INVENTORY == 0 )); then
            partial="$OUTPUT_DIR/s3-readiness-inventory.tsv.partial.$$"
            printf '%s\n' "$LISTING" > "$partial"
            mv -f -- "$partial" "$OUTPUT_DIR/s3-readiness-inventory.tsv"
        fi
    elif (( SUPPLIED_INVENTORY == 1 )); then
        die "supplied readiness inventory does not satisfy the complete expected-folder contract"
    fi
}

launch_ready_samples() {
    local sample sample_dir status_file snapshot start_ns
    local -a launch_order=()
    mapfile -t launch_order < <(
        for sample in "${SAMPLES[@]}"; do
            if [[ "${SAMPLE_STATE[$sample]}" == ready ]]; then
                printf '%012d\t%s\n' "${SAMPLE_SHARDS[$sample]}" "$sample"
            fi
        done | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2V | cut -f2
    )
    for sample in "${launch_order[@]}"; do
        (( RUNNING < SAMPLE_WORKERS )) || break
        sample_dir="$OUTPUT_DIR/$sample"
        snapshot="$sample_dir/readiness-inventory.tsv"
        status_file="$sample_dir/.materialize-status.$$"
        start_ns=$(date +%s%N)
        SAMPLE_START_NS["$sample"]=$start_ns
        SAMPLE_STATUS_FILE["$sample"]=$status_file
        [[ -n "$FIRST_SAMPLE_START_NS" ]] || FIRST_SAMPLE_START_NS=$start_ns
        (
            set +e
            materialize_one_sample "$sample" "$snapshot"
            rc=$?
            end_ns=$(date +%s%N)
            printf '%s\t%s\n' "$rc" "$end_ns" > "${status_file}.partial"
            mv -f -- "${status_file}.partial" "$status_file"
            exit "$rc"
        ) > "$sample_dir/materialize-group.log" 2>&1 &
        SAMPLE_PID["$sample"]=$!
        SAMPLE_STATE["$sample"]=running
        RUNNING=$((RUNNING + 1))
        if (( RUNNING > MAX_RUNNING )); then
            MAX_RUNNING=$RUNNING
        fi
        log "Launched sample $sample (${SAMPLE_SHARDS[$sample]} shards, $SAMPLE_THREADS threads; active=$RUNNING/$SAMPLE_WORKERS)"
    done
}

reap_finished_samples() {
    local sample status_file rc end_ns seconds
    for sample in "${SAMPLES[@]}"; do
        [[ "${SAMPLE_STATE[$sample]}" == running ]] || continue
        status_file="${SAMPLE_STATUS_FILE[$sample]}"
        [[ -f "$status_file" ]] || continue
        IFS=$'\t' read -r rc end_ns < "$status_file"
        if wait "${SAMPLE_PID[$sample]}"; then
            :
        elif [[ "$rc" == 0 ]]; then
            rc=1
        fi
        rm -f -- "$status_file"
        seconds=$(awk -v start="${SAMPLE_START_NS[$sample]}" -v end="$end_ns" \
            'BEGIN {printf "%.6f",(end-start)/1000000000}')
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$sample" "${SAMPLE_SHARDS[$sample]}" "${SAMPLE_READY_NS[$sample]}" \
            "${SAMPLE_START_NS[$sample]}" "$end_ns" "$seconds" "$SAMPLE_THREADS" \
            "$([[ "$rc" == 0 ]] && printf PASS || printf FAIL)" \
            >> "$OUTPUT_DIR/sample-materialization-timings.tsv"
        RUNNING=$((RUNNING - 1))
        LAST_SAMPLE_END_NS=$end_ns
        if [[ "$rc" == 0 ]]; then
            SAMPLE_STATE["$sample"]=done
            COMPLETED=$((COMPLETED + 1))
            log "Completed sample $sample in ${seconds}s (active=$RUNNING/$SAMPLE_WORKERS)"
        else
            SAMPLE_STATE["$sample"]=failed
            FAILED_SAMPLE=$sample
            log "Sample $sample failed; see $OUTPUT_DIR/$sample/materialize-group.log"
        fi
    done
}

log "Sample-eager materialization: ${#SAMPLES[@]} samples, $SAMPLE_WORKERS concurrent sample slots, $SAMPLE_THREADS threads per slot"
while (( COMPLETED < ${#SAMPLES[@]} )); do
    reap_finished_samples
    [[ -z "$FAILED_SAMPLE" ]] || break

    now_epoch=$(date +%s)
    if (( ALL_SHARDS_READY == 0 )) && \
       (( SUPPLIED_INVENTORY == 1 || LAST_LIST_EPOCH == 0 || now_epoch - LAST_LIST_EPOCH >= POLL_SECONDS )); then
        refresh_readiness || true
        LAST_LIST_EPOCH=$now_epoch
    fi
    launch_ready_samples
    reap_finished_samples
    [[ -z "$FAILED_SAMPLE" ]] || break
    (( COMPLETED == ${#SAMPLES[@]} )) && break

    elapsed=$((now_epoch - COORDINATOR_START_EPOCH))
    if (( ALL_SHARDS_READY == 0 && elapsed >= TIMEOUT_SECONDS )); then
        FAILED_SAMPLE="readiness-timeout"
        break
    fi
    sleep 0.1
done

if [[ -n "$FAILED_SAMPLE" ]]; then
    for sample in "${SAMPLES[@]}"; do
        if [[ "${SAMPLE_STATE[$sample]}" == running ]]; then
            kill "${SAMPLE_PID[$sample]}" 2>/dev/null || true
        fi
    done
    for sample in "${SAMPLES[@]}"; do
        if [[ "${SAMPLE_STATE[$sample]}" == running ]]; then
            wait "${SAMPLE_PID[$sample]}" 2>/dev/null || true
        fi
    done
    die "sample-eager materialization failed: $FAILED_SAMPLE"
fi

COORDINATOR_END_NS=$(date +%s%N)
COORDINATOR_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ALL_SHARDS_READY_UTC=$(date -u -d "@$((ALL_SHARDS_READY_NS / 1000000000))" +%Y-%m-%dT%H:%M:%SZ)
COORDINATOR_SECONDS=$(awk -v start="$COORDINATOR_START_NS" -v end="$COORDINATOR_END_NS" \
    'BEGIN {printf "%.6f",(end-start)/1000000000}')
ALL_READY_SECONDS=$(awk -v start="$COORDINATOR_START_NS" -v end="$ALL_SHARDS_READY_NS" \
    'BEGIN {printf "%.6f",(end-start)/1000000000}')
printf 'stage,start_utc,end_utc,seconds,s3_list_calls,max_sample_workers,threads_per_sample\n' \
    > "$OUTPUT_DIR/group-readiness.timings.csv"
printf 'all_lambda_outputs_ready,%s,%s,%s,%s,%s,%s\n' \
    "$COORDINATOR_START_UTC" "$ALL_SHARDS_READY_UTC" "$ALL_READY_SECONDS" \
    "$LIST_CALLS" "$MAX_RUNNING" "$SAMPLE_THREADS" \
    >> "$OUTPUT_DIR/group-readiness.timings.csv"
printf 'sample_eager_materialization_total,%s,%s,%s,%s,%s,%s\n' \
    "$COORDINATOR_START_UTC" "$COORDINATOR_END_UTC" "$COORDINATOR_SECONDS" \
    "$LIST_CALLS" "$MAX_RUNNING" "$SAMPLE_THREADS" \
    >> "$OUTPUT_DIR/group-readiness.timings.csv"

cp -- "$CONTRACT_FILE" "$OUTPUT_DIR/sample_materialization.tsv"
log "Materialized ${#SAMPLES[@]} sample(s) under $OUTPUT_DIR in ${COORDINATOR_SECONDS}s"
