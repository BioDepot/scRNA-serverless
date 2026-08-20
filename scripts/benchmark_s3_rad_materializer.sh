#!/usr/bin/env bash

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-uw}"
AWS_REGION="${AWS_REGION:-us-east-2}"
PBMC_RAD_BUCKET="${PBMC_RAD_BUCKET:-scrna-map-171440768238-us-east-2-p1krg-0819-1054}"
PBMC_RAD_PREFIX="${PBMC_RAD_PREFIX:-piscem_output/pbmc_1k_v3_S1_L001_p}"
EXPECTED_SHARDS="${EXPECTED_SHARDS:-17}"
THREADS="${THREADS:-32}"
BENCHMARK_ROOT="${BENCHMARK_ROOT:-/storage/s3-rad-materializer-benchmark}"
KEEP_BENCHMARK_DATA="${KEEP_BENCHMARK_DATA:-0}"
MATERIALIZER="${MATERIALIZER:-s3-rad-materialize}"

for command in aws radtk "$MATERIALIZER"; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

mkdir -p "$BENCHMARK_ROOT"
RUN_DIR=$(mktemp -d "$BENCHMARK_ROOT/run.XXXXXX")
RESULTS_FILE="$BENCHMARK_ROOT/results-$(date -u +%Y%m%dT%H%M%SZ).txt"
SUCCESS=0

cleanup() {
    if [[ "$SUCCESS" == "1" && "$KEEP_BENCHMARK_DATA" != "1" ]]; then
        rm -rf -- "$RUN_DIR"
    else
        echo "Benchmark data retained at: $RUN_DIR"
    fi
}
trap cleanup EXIT

MANIFEST="$RUN_DIR/pbmc1k-map-rad.manifest"
BASELINE_ROOT="$RUN_DIR/baseline"
BASELINE_OUTPUT="$RUN_DIR/baseline-map.rad"
RANGED_OUTPUT="$RUN_DIR/ranged-map.rad"
mkdir -p "$BASELINE_ROOT"

aws s3api list-objects-v2 \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --bucket "$PBMC_RAD_BUCKET" \
    --prefix "$PBMC_RAD_PREFIX" \
    --query 'Contents[?ends_with(Key, `/map.rad`)].Key' \
    --output text | tr '\t' '\n' | sort -V | \
    sed "s#^#s3://$PBMC_RAD_BUCKET/#" > "$MANIFEST"

SHARD_COUNT=$(wc -l < "$MANIFEST")
if [[ "$SHARD_COUNT" -ne "$EXPECTED_SHARDS" ]]; then
    echo "Expected $EXPECTED_SHARDS RAD shards, found $SHARD_COUNT" >&2
    exit 1
fi

now_ns() {
    date +%s%N
}

elapsed_seconds() {
    local start="$1" end="$2"
    awk -v start="$start" -v end="$end" 'BEGIN { printf "%.3f", (end-start)/1000000000 }'
}

echo "PBMC 1K S3 RAD materializer benchmark"
echo "Bucket:  $PBMC_RAD_BUCKET"
echo "Shards:  $SHARD_COUNT"
echo "Threads: $THREADS"
echo "Workdir: $RUN_DIR"

sync
echo "Running baseline: aws s3 sync + radtk cat"
start=$(now_ns)
aws s3 sync \
    "s3://$PBMC_RAD_BUCKET/piscem_output/" \
    "$BASELINE_ROOT/piscem_output/" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --exclude '*' --include '*/map.rad' \
    --only-show-errors
after_sync=$(now_ns)

mapfile -t RAD_FILES < <(find "$BASELINE_ROOT/piscem_output" -type f -name map.rad | sort -V)
if [[ "${#RAD_FILES[@]}" -ne "$SHARD_COUNT" ]]; then
    echo "Baseline downloaded ${#RAD_FILES[@]} RAD files, expected $SHARD_COUNT" >&2
    exit 1
fi
RAD_INPUTS=$(IFS=,; echo "${RAD_FILES[*]}")
radtk cat -i "$RAD_INPUTS" -o "$BASELINE_OUTPUT"
after_cat=$(now_ns)

sync_seconds=$(elapsed_seconds "$start" "$after_sync")
cat_seconds=$(elapsed_seconds "$after_sync" "$after_cat")
baseline_seconds=$(elapsed_seconds "$start" "$after_cat")

# Do not make the ranged implementation absorb the baseline's pending local
# writes. This synchronization is intentionally outside both measured paths.
sync
echo "Running ranged materializer"
ranged_start=$(now_ns)
"$MATERIALIZER" \
    --manifest "$MANIFEST" \
    --output "$RANGED_OUTPUT" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --threads "$THREADS" \
    --overwrite | tee "$RUN_DIR/materializer-metrics.txt"
ranged_end=$(now_ns)
ranged_seconds=$(elapsed_seconds "$ranged_start" "$ranged_end")

echo "Checking byte-for-byte equality"
cmp "$BASELINE_OUTPUT" "$RANGED_OUTPUT"

baseline_sha=$(sha256sum "$BASELINE_OUTPUT" | awk '{print $1}')
ranged_sha=$(sha256sum "$RANGED_OUTPUT" | awk '{print $1}')
output_bytes=$(stat -c '%s' "$RANGED_OUTPUT")
speedup=$(awk -v baseline="$baseline_seconds" -v ranged="$ranged_seconds" \
    'BEGIN { if (ranged > 0) printf "%.3f", baseline/ranged; else print "0" }')

{
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "bucket=$PBMC_RAD_BUCKET"
    echo "prefix=$PBMC_RAD_PREFIX"
    echo "shards=$SHARD_COUNT"
    echo "threads=$THREADS"
    echo "output_bytes=$output_bytes"
    echo "baseline_sync_seconds=$sync_seconds"
    echo "baseline_radtk_seconds=$cat_seconds"
    echo "baseline_total_seconds=$baseline_seconds"
    echo "ranged_total_seconds=$ranged_seconds"
    echo "speedup=$speedup"
    echo "baseline_sha256=$baseline_sha"
    echo "ranged_sha256=$ranged_sha"
    echo "byte_identical=true"
} | tee "$RESULTS_FILE"

SUCCESS=1
echo "Benchmark results: $RESULTS_FILE"
