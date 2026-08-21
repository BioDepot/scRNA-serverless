#!/usr/bin/env bash

# One-shot KO baseline: run Piscem once per sample, sequentially, using all
# R1/R2 pairs assigned to that sample. Alevin-fry is intentionally excluded.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MANIFEST="${MANIFEST:-$SCRIPT_DIR/ko_sample_pairs.tsv}"
FASTQ_DIR="${FASTQ_DIR:-/mnt/nvme/datasets/ko/fastqs}"
PISCEM_BIN="${PISCEM_BIN:-/mnt/nvme/benchmark-runs/piscem-cloud-profile.um6E5m/piscem-x86_64-unknown-linux-gnu/piscem}"
PISCEM_INDEX_PREFIX="${PISCEM_INDEX_PREFIX:-/mnt/nvme/benchmark-runs/piscem-cloud-profile.um6E5m/index_output_transcriptome/index_output_transcriptome}"
RADTK_BIN="${RADTK_BIN:-/mnt/nvme/benchmark-runs/piscem-cloud-profile.um6E5m/radtk-x86_64-unknown-linux-gnu/radtk}"
THREADS="${THREADS:-32}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
RUN_ID="${RUN_ID:-ko-piscem-baseline-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="${RUN_DIR:-/mnt/nvme/benchmark-runs/$RUN_ID}"

SAMPLES=(A B C D E F G_1 G_2 H I J L_1 L_2)
declare -A EXPECTED_PAIRS=(
    [A]=9 [B]=9 [C]=9 [D]=11 [E]=16 [F]=11 [G_1]=11
    [G_2]=5 [H]=9 [I]=9 [J]=11 [L_1]=11 [L_2]=9
)

[[ "$THREADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: THREADS must be positive" >&2; exit 1; }
[[ "$PREFLIGHT_ONLY" == "0" || "$PREFLIGHT_ONLY" == "1" ]] || {
    echo "ERROR: PREFLIGHT_ONLY must be 0 or 1" >&2
    exit 1
}
[[ -f "$MANIFEST" ]] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; }
[[ -d "$FASTQ_DIR" ]] || { echo "ERROR: FASTQ directory not found: $FASTQ_DIR" >&2; exit 1; }
[[ -x "$PISCEM_BIN" ]] || { echo "ERROR: Piscem executable not found: $PISCEM_BIN" >&2; exit 1; }
[[ -x "$RADTK_BIN" ]] || { echo "ERROR: radtk executable not found: $RADTK_BIN" >&2; exit 1; }
for suffix in sshash ctab refinfo; do
    [[ -f "${PISCEM_INDEX_PREFIX}.${suffix}" ]] || {
        echo "ERROR: Piscem index component missing: ${PISCEM_INDEX_PREFIX}.${suffix}" >&2
        exit 1
    }
done
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }
[[ ! -e "$RUN_DIR/started" ]] || {
    echo "ERROR: one-shot run already started: $RUN_DIR/started" >&2
    exit 1
}

# Validate all 130 local inputs and their exact recorded sizes before creating
# the one-shot marker.
row_count=0
while IFS=$'\t' read -r priority sample condition pair_name r1_name r1_bytes r1_url \
    r2_name r2_bytes r2_url combined_bytes; do
    [[ "$priority" == "priority" ]] && continue
    row_count=$((row_count + 1))
    [[ -n "${EXPECTED_PAIRS[$sample]:-}" ]] || {
        echo "ERROR: unexpected sample in manifest: $sample" >&2
        exit 1
    }
    for spec in "$r1_name:$r1_bytes" "$r2_name:$r2_bytes"; do
        filename=${spec%%:*}
        expected_bytes=${spec##*:}
        path="$FASTQ_DIR/$filename"
        [[ -f "$path" ]] || { echo "ERROR: missing FASTQ: $path" >&2; exit 1; }
        actual_bytes=$(stat --format=%s "$path")
        [[ "$actual_bytes" -eq "$expected_bytes" ]] || {
            echo "ERROR: size mismatch for $path: expected $expected_bytes, found $actual_bytes" >&2
            exit 1
        }
        [[ "$path" != *,* ]] || { echo "ERROR: comma in FASTQ path: $path" >&2; exit 1; }
    done
done < "$MANIFEST"
[[ "$row_count" -eq 130 ]] || { echo "ERROR: expected 130 pairs, found $row_count" >&2; exit 1; }

for sample in "${SAMPLES[@]}"; do
    actual_pairs=$(awk -F'\t' -v wanted="$sample" 'NR > 1 && $2 == wanted {n++} END {print n+0}' "$MANIFEST")
    [[ "$actual_pairs" -eq "${EXPECTED_PAIRS[$sample]}" ]] || {
        echo "ERROR: sample $sample expected ${EXPECTED_PAIRS[$sample]} pairs, found $actual_pairs" >&2
        exit 1
    }
done

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
    echo "Preflight passed: 130 pairs, 13 ordered samples, Piscem/index/radtk available"
    exit 0
fi

mkdir -p "$RUN_DIR/samples"
(
    set -o noclobber
    printf 'run_id=%s\ncreated_utc=%s\n' "$RUN_ID" "$(date -u +%FT%TZ)" > "$RUN_DIR/started"
)
printf 'sample\tpairs\tseconds\treads\tmapped\trad_bytes\n' > "$RUN_DIR/sample_timings.tsv"
printf '%s\n' \
    "run_id=$RUN_ID" \
    "manifest=$MANIFEST" \
    "fastq_dir=$FASTQ_DIR" \
    "piscem_bin=$PISCEM_BIN" \
    "piscem_index_prefix=$PISCEM_INDEX_PREFIX" \
    "threads=$THREADS" \
    "samples=${SAMPLES[*]}" \
    "pairs=130" \
    "alevin_fry=excluded" \
    > "$RUN_DIR/config.txt"

OVERALL_START_NS=$(date +%s%N)
printf '%s\n' "$OVERALL_START_NS" > "$RUN_DIR/start_ns.txt"

for sample in "${SAMPLES[@]}"; do
    sample_dir="$RUN_DIR/samples/$sample"
    output_dir="$sample_dir/output"
    mkdir -p "$sample_dir"
    declare -a r1_paths=() r2_paths=()
    while IFS=$'\t' read -r pair_name r1_name r2_name; do
        r1_paths+=("$FASTQ_DIR/$r1_name")
        r2_paths+=("$FASTQ_DIR/$r2_name")
    done < <(
        awk -F'\t' -v wanted="$sample" \
            'NR > 1 && $2 == wanted {print $4 "\t" $5 "\t" $8}' "$MANIFEST" \
            | LC_ALL=C sort -t $'\t' -k1,1
    )
    [[ ${#r1_paths[@]} -eq "${EXPECTED_PAIRS[$sample]}" ]] || {
        echo "ERROR: internal pair-count mismatch for $sample" >&2
        exit 1
    }
    r1_csv=$(IFS=,; printf '%s' "${r1_paths[*]}")
    r2_csv=$(IFS=,; printf '%s' "${r2_paths[*]}")

    echo "Starting sample $sample (${#r1_paths[@]} pairs) with Piscem -t $THREADS"
    sample_start_ns=$(date +%s%N)
    /usr/bin/time -v -o "$sample_dir/time.txt" \
        "$PISCEM_BIN" map-sc \
            -i "$PISCEM_INDEX_PREFIX" \
            -g chromium_v3 \
            -1 "$r1_csv" \
            -2 "$r2_csv" \
            -t "$THREADS" \
            -o "$output_dir" \
            > "$sample_dir/piscem.log" 2>&1
    sample_end_ns=$(date +%s%N)
    sample_seconds=$(awk -v start="$sample_start_ns" -v end="$sample_end_ns" \
        'BEGIN {printf "%.6f", (end - start) / 1000000000}')
    [[ -s "$output_dir/map.rad" ]] || { echo "ERROR: map.rad missing for $sample" >&2; exit 1; }
    [[ -s "$output_dir/map_info.json" ]] || { echo "ERROR: map_info.json missing for $sample" >&2; exit 1; }
    reads=$(jq -er '.num_reads' "$output_dir/map_info.json")
    mapped=$(jq -er '.num_mapped' "$output_dir/map_info.json")
    rad_bytes=$(stat --format=%s "$output_dir/map.rad")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sample" "${#r1_paths[@]}" "$sample_seconds" "$reads" "$mapped" "$rad_bytes" \
        >> "$RUN_DIR/sample_timings.tsv"
    echo "Completed sample $sample in $sample_seconds seconds; reads=$reads mapped=$mapped"
    unset r1_paths r2_paths
done

OVERALL_END_NS=$(date +%s%N)
printf '%s\n' "$OVERALL_END_NS" > "$RUN_DIR/end_ns.txt"
WALL_SECONDS=$(awk -v start="$OVERALL_START_NS" -v end="$OVERALL_END_NS" \
    'BEGIN {printf "%.6f", (end - start) / 1000000000}')
SUM_SECONDS=$(awk -F'\t' 'NR > 1 {sum += $3} END {printf "%.6f", sum}' "$RUN_DIR/sample_timings.tsv")
TOTAL_READS=$(awk -F'\t' 'NR > 1 {sum += $4} END {printf "%.0f", sum}' "$RUN_DIR/sample_timings.tsv")
TOTAL_MAPPED=$(awk -F'\t' 'NR > 1 {sum += $5} END {printf "%.0f", sum}' "$RUN_DIR/sample_timings.tsv")
TOTAL_RAD_BYTES=$(awk -F'\t' 'NR > 1 {sum += $6} END {printf "%.0f", sum}' "$RUN_DIR/sample_timings.tsv")

# Parse the first chunk of every RAD after the timed region.
for sample in "${SAMPLES[@]}"; do
    "$RADTK_BIN" view --input "$RUN_DIR/samples/$sample/output/map.rad" \
        --rad-type single-cell --max-chunks 1 > /dev/null
done

printf '%s\n' \
    "run_id=$RUN_ID" \
    "wall_seconds=$WALL_SECONDS" \
    "sum_sample_seconds=$SUM_SECONDS" \
    "sample_count=${#SAMPLES[@]}" \
    "pair_count=130" \
    "threads_per_sample=$THREADS" \
    "total_reads=$TOTAL_READS" \
    "total_mapped=$TOTAL_MAPPED" \
    "total_rad_bytes=$TOTAL_RAD_BYTES" \
    "rad_validation=passed_first_chunk_all_samples" \
    "alevin_fry=excluded" \
    > "$RUN_DIR/result.txt"

echo "KO Piscem baseline complete: $WALL_SECONDS seconds"
echo "Evidence: $RUN_DIR"
