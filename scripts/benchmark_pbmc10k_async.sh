#!/usr/bin/env bash

# Reproduce one PBMC 10K local Piscem baseline and one optimized asynchronous
# serverless run from the four R1/R2 gzip files already on NVMe.  The serverless
# clock begins immediately before the first rapidgzip worker starts and ends
# after the final RAD has been materialized from S3.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  benchmark_pbmc10k_async.sh --preflight
  benchmark_pbmc10k_async.sh --run
  benchmark_pbmc10k_async.sh --finish-async

Options are selected with environment variables:
  BENCHMARK_ID       Unique evidence name (default: UTC timestamp).
  RESULTS_ROOT       Evidence parent (default: /mnt/nvme/benchmark-runs).
  FASTQ_DIR          PBMC 10K FASTQ directory on NVMe.
  PISCEM_BIN         Piscem 0.10.3 executable.
  INDEX_PREFIX       Existing Piscem index prefix.
  AWS_REGION         AWS region (default: us-east-2).
  LAMBDA_CONCURRENCY Requested Lambda reservation (default: 750; driver may
                     fall back to the available account quota).

The --run action is deliberately one-shot.  Stage markers prevent accidentally
executing either measured arm twice in the same BENCHMARK_ID.  --finish-async
can join/materialize an already-submitted run without publishing manifests a
second time.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2
}

now_ns() {
    date +%s%N
}

elapsed_seconds() {
    awk -v start="$1" -v end="$2" \
        'BEGIN { printf "%.6f", (end - start) / 1000000000 }'
}

write_once() {
    local path="$1" value="$2"
    (
        set -o noclobber
        printf '%s\n' "$value" > "$path"
    ) 2>/dev/null || die "one-shot marker already exists: $path"
}

state_value() {
    local key="$1" state="$2"
    awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$state"
}

ceil_div() {
    awk -v numerator="$1" -v denominator="$2" \
        'BEGIN { printf "%.0f", int((numerator + denominator - 1) / denominator) }'
}

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ACTION="${1:---preflight}"
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$ACTION" in
    --preflight|--run|--finish-async) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

AWS_REGION="${AWS_REGION:-us-east-2}"
FASTQ_DIR="${FASTQ_DIR:-/mnt/nvme/datasets/pbmc10k/pbmc_10k_v3_fastqs}"
PISCEM_BIN="${PISCEM_BIN:-/mnt/nvme/benchmark-runs/piscem-cloud-profile.um6E5m/piscem-x86_64-unknown-linux-gnu/piscem}"
INDEX_PREFIX="${INDEX_PREFIX:-/mnt/nvme/benchmark-runs/piscem-cloud-profile.um6E5m/index_output_transcriptome/index_output_transcriptome}"
RADTK_BIN="${RADTK_BIN:-/usr/local/bin/radtk}"
RESULTS_ROOT="${RESULTS_ROOT:-/mnt/nvme/benchmark-runs}"
BENCHMARK_ID="${BENCHMARK_ID:-pbmc10k-$(date -u +%Y%m%d-%H%M%S)}"
BENCHMARK_DIR="${RESULTS_ROOT}/${BENCHMARK_ID}"
BASELINE_DIR="${BENCHMARK_DIR}/baseline-piscem-32t"
ASYNC_DIR="${BENCHMARK_DIR}/async-serverless"
BENCHMARK_TOKEN=$(printf '%s' "$BENCHMARK_ID" | tr '[:upper:]_' '[:lower:]-' | \
    sed -E 's/^pbmc10k-//; s/[^a-z0-9-]//g')
ASYNC_RUN_ID="${ASYNC_RUN_ID:-p10k-${BENCHMARK_TOKEN:0:20}}"
ASYNC_RUN_DIR="/mnt/nvme/runs/${ASYNC_RUN_ID}"
ASYNC_STATE_FILE="${ASYNC_RUN_DIR}/async_state.env"

THREADS=32
MATERIALIZER_THREADS=32
DECOMP_THREADS=8
READS_PER_SHARD=4000000
SPLIT_LINES=$((READS_PER_SHARD * 4))
L001_READS=320936855
L002_READS=317964164
EXPECTED_TOTAL_READS=$((L001_READS + L002_READS))
EXPECTED_L001_SHARDS=$(ceil_div "$L001_READS" "$READS_PER_SHARD")
EXPECTED_L002_SHARDS=$(ceil_div "$L002_READS" "$READS_PER_SHARD")
EXPECTED_SHARDS=$((EXPECTED_L001_SHARDS + EXPECTED_L002_SHARDS))

R1_FILES=(
    "${FASTQ_DIR}/pbmc_10k_v3_S1_L001_R1_001.fastq.gz"
    "${FASTQ_DIR}/pbmc_10k_v3_S1_L002_R1_001.fastq.gz"
)
R2_FILES=(
    "${FASTQ_DIR}/pbmc_10k_v3_S1_L001_R2_001.fastq.gz"
    "${FASTQ_DIR}/pbmc_10k_v3_S1_L002_R2_001.fastq.gz"
)
R1_COMMA=$(IFS=,; echo "${R1_FILES[*]}")
R2_COMMA=$(IFS=,; echo "${R2_FILES[*]}")

preflight() {
    local f index_file cores
    [[ -d "$FASTQ_DIR" ]] || die "FASTQ directory not found: $FASTQ_DIR"
    for f in "${R1_FILES[@]}" "${R2_FILES[@]}"; do
        [[ -f "$f" ]] || die "FASTQ missing: $f"
        [[ $(head -c 2 "$f" | od -An -tx1 | tr -d ' \n') == "1f8b" ]] || \
            die "not a gzip stream: $f"
    done
    [[ -x "$PISCEM_BIN" ]] || die "Piscem executable not found: $PISCEM_BIN"
    for index_file in sshash ctab ectab refinfo; do
        [[ -f "${INDEX_PREFIX}.${index_file}" ]] || \
            die "Piscem index component missing: ${INDEX_PREFIX}.${index_file}"
    done
    [[ -x "$RADTK_BIN" ]] || die "radtk executable not found: $RADTK_BIN"
    command -v rapidgzip >/dev/null 2>&1 || die "rapidgzip not found"
    command -v aws >/dev/null 2>&1 || die "aws CLI not found"
    command -v jq >/dev/null 2>&1 || die "jq not found"
    command -v /usr/bin/time >/dev/null 2>&1 || die "/usr/bin/time not found"
    command -v s3-rad-materialize >/dev/null 2>&1 || \
        die "s3-rad-materialize not found"
    aws sts get-caller-identity --region "$AWS_REGION" >/dev/null

    cores=$(nproc)
    (( cores >= THREADS )) || die "PBMC 10K benchmark requires at least $THREADS cores; found $cores"
    [[ "$EXPECTED_TOTAL_READS" -eq 638901019 ]] || die "internal read-count contract is inconsistent"
    [[ "$EXPECTED_L001_SHARDS" -eq 81 && "$EXPECTED_L002_SHARDS" -eq 80 ]] || \
        die "derived shard contract is inconsistent"
    [[ "$ASYNC_RUN_ID" =~ ^[a-z0-9][a-z0-9-]{0,27}$ ]] || \
        die "ASYNC_RUN_ID must be lowercase, S3-safe, and at most 28 characters: $ASYNC_RUN_ID"

    log "PBMC 10K inputs: 2 lane pairs / 4 R1-R2 gzip files (I1 excluded)"
    log "Read contract: L001=$L001_READS, L002=$L002_READS, total=$EXPECTED_TOTAL_READS"
    log "Shard plan: $READS_PER_SHARD reads ($SPLIT_LINES FASTQ lines), derived $EXPECTED_L001_SHARDS+$EXPECTED_L002_SHARDS=$EXPECTED_SHARDS manifests"
    log "Decompression plan: 4 files on $cores cores -> rapidgzip -P $DECOMP_THREADS per file; lanes are not concatenated"
    log "Safety: ALLOW_DESTRUCTIVE_CLEANUP=0, ALLOW_S3_DELETE=0, CLEANUP_AWS=0, CLEANUP_RESULTS=0, DELETE_CLOUDWATCH_LOGS=0"
}

record_inputs() {
    mkdir -p "$BENCHMARK_DIR"
    {
        printf 'dataset\tpbmc10k\n'
        printf 'fastq_dir\t%s\n' "$FASTQ_DIR"
        printf 'r1r2_files\t4\n'
        printf 'l001_reads\t%s\n' "$L001_READS"
        printf 'l002_reads\t%s\n' "$L002_READS"
        printf 'total_reads\t%s\n' "$EXPECTED_TOTAL_READS"
        printf 'reads_per_shard\t%s\n' "$READS_PER_SHARD"
        printf 'split_lines\t%s\n' "$SPLIT_LINES"
        printf 'expected_l001_shards\t%s\n' "$EXPECTED_L001_SHARDS"
        printf 'expected_l002_shards\t%s\n' "$EXPECTED_L002_SHARDS"
        printf 'expected_shards\t%s\n' "$EXPECTED_SHARDS"
        printf 'threads\t%s\n' "$THREADS"
        printf 'decomp_threads_per_file\t%s\n' "$DECOMP_THREADS"
        printf 'aws_region\t%s\n' "$AWS_REGION"
        printf 'git_commit\t%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD)"
        printf 'piscem_version\t%s\n' "$($PISCEM_BIN --version 2>&1 | head -1)"
        printf 'radtk_version\t%s\n' "$($RADTK_BIN --version 2>&1 | head -1)"
        printf 'rapidgzip_version\t%s\n' "$(rapidgzip --version 2>&1 | head -1)"
    } > "$BENCHMARK_DIR/contract.tsv"

    {
        printf 'mate\tlane\tbytes\tpath\n'
        printf 'R1\tL001\t%s\t%s\n' "$(stat -c %s "${R1_FILES[0]}")" "${R1_FILES[0]}"
        printf 'R1\tL002\t%s\t%s\n' "$(stat -c %s "${R1_FILES[1]}")" "${R1_FILES[1]}"
        printf 'R2\tL001\t%s\t%s\n' "$(stat -c %s "${R2_FILES[0]}")" "${R2_FILES[0]}"
        printf 'R2\tL002\t%s\t%s\n' "$(stat -c %s "${R2_FILES[1]}")" "${R2_FILES[1]}"
    } > "$BENCHMARK_DIR/input-files.tsv"

    aws lambda get-account-settings --region "$AWS_REGION" > "$BENCHMARK_DIR/lambda-account-settings-before.json"
}

validate_rad() {
    local rad="$1" evidence="$2"
    [[ -s "$rad" ]] || die "RAD file missing or empty: $rad"
    "$RADTK_BIN" view --input "$rad" --rad-type single-cell --max-chunks 1 \
        >/dev/null 2>"${evidence}.stderr"
    printf 'PASS\tbytes=%s\tpath=%s\n' "$(stat -c %s "$rad")" "$rad" > "$evidence"
}

run_baseline() {
    local start_ns end_ns rc=0
    mkdir -p "$BASELINE_DIR/output"
    write_once "$BASELINE_DIR/started" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf '%q ' "$PISCEM_BIN" map-sc -i "$INDEX_PREFIX" -g chromium_v3 \
        -1 "$R1_COMMA" -2 "$R2_COMMA" -t "$THREADS" -o "$BASELINE_DIR/output" \
        > "$BASELINE_DIR/command.sh"
    printf '\n' >> "$BASELINE_DIR/command.sh"

    start_ns=$(now_ns)
    printf '%s\n' "$start_ns" > "$BASELINE_DIR/start.ns"
    log "Starting the one local Piscem 32-thread baseline"
    set +e
    /usr/bin/time -v -o "$BASELINE_DIR/time.txt" \
        "$PISCEM_BIN" map-sc \
        -i "$INDEX_PREFIX" \
        -g chromium_v3 \
        -1 "$R1_COMMA" \
        -2 "$R2_COMMA" \
        -t "$THREADS" \
        -o "$BASELINE_DIR/output" \
        2>&1 | tee "$BASELINE_DIR/piscem.log"
    rc=${PIPESTATUS[0]}
    set -e
    end_ns=$(now_ns)
    printf '%s\n' "$end_ns" > "$BASELINE_DIR/end.ns"
    printf '%s\n' "$rc" > "$BASELINE_DIR/exit-code.txt"
    (( rc == 0 )) || die "local Piscem baseline failed with exit $rc"

    jq -e --argjson expected "$EXPECTED_TOTAL_READS" \
        '.num_reads == $expected and (.num_mapped | type == "number")' \
        "$BASELINE_DIR/output/map_info.json" >/dev/null || \
        die "baseline map_info.json failed the read-count contract"
    validate_rad "$BASELINE_DIR/output/map.rad" "$BASELINE_DIR/rad-validation.txt"
    sha256sum "$BASELINE_DIR/output/map.rad" > "$BASELINE_DIR/map.rad.sha256"
    elapsed_seconds "$start_ns" "$end_ns" > "$BASELINE_DIR/wall-seconds.txt"
    write_once "$BASELINE_DIR/completed" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log "Baseline complete: $(cat "$BASELINE_DIR/wall-seconds.txt") seconds"
}

submit_async() {
    local rc=0
    mkdir -p "$ASYNC_DIR/final"
    write_once "$ASYNC_DIR/started" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ ! -e "$ASYNC_RUN_DIR" ]] || die "async run directory already exists: $ASYNC_RUN_DIR"

    log "Provisioning and submitting the one optimized asynchronous serverless run"
    set +e
    (
        export RUN_ID="$ASYNC_RUN_ID"
        export AWS_REGION
        export LOCAL_FASTQ_DIR="$FASTQ_DIR"
        export EXECUTION_MODE=async-submit
        export SPLIT_LINES
        export PIPELINE_START_FILE="$ASYNC_DIR/rapidgzip-start.ns"
        export LAMBDA_CONCURRENCY="${LAMBDA_CONCURRENCY:-750}"
        export LAMBDA_MEMORY_MB=10240
        export LAMBDA_EPHEMERAL_MB=10240
        export LAMBDA_TIMEOUT_SEC=900
        export PROCESS_FASTQ_TIMEOUT_SEC=43200
        export POLL_INTERVAL_SECONDS=1
        export POST_UPLOAD_PROPAGATION_WAIT_SECONDS=0
        export MATERIALIZER_THREADS="$MATERIALIZER_THREADS"
        export USE_RAPIDGZIP=1
        export RUN_QC=0
        export ALLOW_DESTRUCTIVE_CLEANUP=0
        export ALLOW_S3_DELETE=0
        export CLEANUP_AWS=0
        export CLEANUP_RESULTS=0
        export DELETE_CLOUDWATCH_LOGS=0
        export SKIP_PREFLIGHT_CLEANUP=1
        bash "$REPO_ROOT/scripts/e2e_serverless_pbmc.sh" pbmc10k --run
    ) 2>&1 | tee "$ASYNC_DIR/submit.log"
    rc=${PIPESTATUS[0]}
    set -e
    printf '%s\n' "$rc" > "$ASYNC_DIR/submit-exit-code.txt"
    (( rc == 0 )) || die "async submission failed with exit $rc; resources and evidence were retained"
    [[ -s "$ASYNC_DIR/rapidgzip-start.ns" ]] || die "first-rapidgzip timestamp was not recorded"
    [[ -f "$ASYNC_STATE_FILE" ]] || die "async state file not found: $ASYNC_STATE_FILE"
    cp "$ASYNC_STATE_FILE" "$ASYNC_DIR/async_state.env"
    cp "$ASYNC_RUN_DIR/expected_rad_folders.txt" "$ASYNC_DIR/expected_rad_folders.txt"

    local actual_shards
    actual_shards=$(awk 'NF {n++} END {print n+0}' "$ASYNC_DIR/expected_rad_folders.txt")
    [[ "$actual_shards" -eq "$EXPECTED_SHARDS" ]] || \
        die "splitter published $actual_shards shards; derived contract expected $EXPECTED_SHARDS"
    log "Async submission published the expected $actual_shards manifests"
}

finish_async() {
    local state="$ASYNC_DIR/async_state.env" end_ns start_ns output_bucket
    [[ -f "$state" ]] || {
        [[ -f "$ASYNC_STATE_FILE" ]] || die "no submitted async state found"
        mkdir -p "$ASYNC_DIR"
        cp "$ASYNC_STATE_FILE" "$state"
    }
    [[ ! -e "$ASYNC_DIR/completed" ]] || die "async stage is already complete: $ASYNC_DIR/completed"
    mkdir -p "$ASYNC_DIR/final"

    log "Waiting for all Lambdas and materializing the final RAD directly from S3"
    bash "$REPO_ROOT/scripts/async_lambda_control.sh" \
        --state "$state" materialize \
        --output "$ASYNC_DIR/final/map.rad" \
        --threads "$MATERIALIZER_THREADS" \
        --poll-seconds 1 \
        --timeout-seconds 43200 \
        --timings-file "$ASYNC_DIR/materializer-timings.csv" \
        2>&1 | tee "$ASYNC_DIR/materialize.log"
    end_ns=$(now_ns)
    printf '%s\n' "$end_ns" > "$ASYNC_DIR/final-rad-end.ns"

    start_ns=$(<"$ASYNC_DIR/rapidgzip-start.ns")
    elapsed_seconds "$start_ns" "$end_ns" > "$ASYNC_DIR/rapidgzip-to-final-rad-seconds.txt"
    validate_rad "$ASYNC_DIR/final/map.rad" "$ASYNC_DIR/rad-validation.txt"
    sha256sum "$ASYNC_DIR/final/map.rad" > "$ASYNC_DIR/map.rad.sha256"

    output_bucket=$(state_value OUTPUT_MAP_BUCKET "$state")
    [[ -n "$output_bucket" ]] || die "OUTPUT_MAP_BUCKET missing from $state"
    mkdir -p "$ASYNC_DIR/map-info"
    aws s3 sync "s3://${output_bucket}/piscem_output/" "$ASYNC_DIR/map-info/" \
        --region "$AWS_REGION" --exclude '*' --include '*/map_info.json' --only-show-errors
    find "$ASYNC_DIR/map-info" -name map_info.json -type f -print0 | \
        sort -z | xargs -0 jq -s \
        '{num_shards:length, num_reads:(map(.num_reads)|add), num_mapped:(map(.num_mapped)|add)}' \
        > "$ASYNC_DIR/aggregate-map-info.json"

    jq -e --argjson shards "$EXPECTED_SHARDS" --argjson reads "$EXPECTED_TOTAL_READS" \
        '.num_shards == $shards and .num_reads == $reads and (.num_mapped | type == "number")' \
        "$ASYNC_DIR/aggregate-map-info.json" >/dev/null || \
        die "serverless aggregate map metadata failed the shard/read contract"
    [[ $(jq -r .num_mapped "$ASYNC_DIR/aggregate-map-info.json") == \
       $(jq -r .num_mapped "$BASELINE_DIR/output/map_info.json") ]] || \
        die "serverless and baseline mapped-read counts differ"

    aws lambda get-function-configuration \
        --function-name "$(state_value LAMBDA_FUNCTION "$state")" \
        --region "$AWS_REGION" > "$ASYNC_DIR/lambda-function-configuration.json"
    aws lambda get-function-concurrency \
        --function-name "$(state_value LAMBDA_FUNCTION "$state")" \
        --region "$AWS_REGION" > "$ASYNC_DIR/lambda-function-concurrency.json" || true

    write_once "$ASYNC_DIR/completed" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log "Async final RAD complete: $(cat "$ASYNC_DIR/rapidgzip-to-final-rad-seconds.txt") seconds"
}

write_summary() {
    local baseline_seconds async_seconds saved speedup reduction baseline_mapped
    baseline_seconds=$(<"$BASELINE_DIR/wall-seconds.txt")
    async_seconds=$(<"$ASYNC_DIR/rapidgzip-to-final-rad-seconds.txt")
    baseline_mapped=$(jq -r .num_mapped "$BASELINE_DIR/output/map_info.json")
    read -r saved speedup reduction < <(
        awk -v baseline="$baseline_seconds" -v async="$async_seconds" \
            'BEGIN { printf "%.6f %.6f %.4f\n", baseline-async, baseline/async, 100*(baseline-async)/baseline }'
    )
    cat > "$BENCHMARK_DIR/RESULTS.md" <<EOF
# PBMC 10K local versus asynchronous serverless benchmark

- Local Piscem baseline (32 threads): **${baseline_seconds} seconds**
- Async serverless, first rapidgzip start through final RAD: **${async_seconds} seconds**
- Time saved: **${saved} seconds**
- Speedup relative to local Piscem: **${speedup}x**
- Wall-time reduction: **${reduction}%**
- Input reads: **${EXPECTED_TOTAL_READS}**
- Mapped reads in both arms: **${baseline_mapped}**
- Shards/manifests: **${EXPECTED_SHARDS}** (${EXPECTED_L001_SHARDS} L001 + ${EXPECTED_L002_SHARDS} L002)

Both final RAD files passed \`radtk view --rad-type single-cell --max-chunks 1\`.
Read and mapped-read counts are identical. Byte identity is not expected because
Piscem worker scheduling changes record order and chunk boundaries. Full
canonical sorting of hundreds of millions of RAD records is intentionally not
part of this development benchmark; the retained RADs make that optional audit
possible later.

No cleanup ran. S3 objects, Lambda/ECR/IAM/EventBridge resources, S3 claims,
CloudWatch logs, local outputs, and timing evidence were retained.
EOF
    log "Benchmark summary: $BENCHMARK_DIR/RESULTS.md"
}

preflight
case "$ACTION" in
    --preflight)
        exit 0
        ;;
    --run)
        [[ ! -e "$BENCHMARK_DIR" ]] || die "benchmark evidence directory already exists: $BENCHMARK_DIR"
        record_inputs
        run_baseline
        submit_async
        finish_async
        write_summary
        ;;
    --finish-async)
        finish_async
        [[ -f "$BASELINE_DIR/completed" ]] && write_summary
        ;;
esac
