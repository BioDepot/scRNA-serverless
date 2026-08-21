#!/bin/bash

set -euo pipefail

SPLIT_TOTAL_START_NS=$(date +%s%N)

split_elapsed_seconds() {
    local start_ns="$1" end_ns="$2"
    awk -v start="$start_ns" -v end="$end_ns" \
        'BEGIN { printf "%.6f", (end - start) / 1000000000 }'
}

record_split_timing() {
    local stage="$1" start_ns="$2" end_ns seconds
    end_ns=$(date +%s%N)
    seconds=$(split_elapsed_seconds "$start_ns" "$end_ns")
    echo "TIMING $stage=${seconds}s"
    if [[ -n "${SPLIT_TIMINGS_FILE:-}" ]]; then
        if [[ ! -f "$SPLIT_TIMINGS_FILE" ]]; then
            mkdir -p "$(dirname "$SPLIT_TIMINGS_FILE")"
            printf 'stage,seconds\n' > "$SPLIT_TIMINGS_FILE"
        fi
        printf '%s,%s\n' "$stage" "$seconds" >> "$SPLIT_TIMINGS_FILE"
    fi
}

# Receive arguments from Python
BUCKET_NAME="$1"
R1_S3_PATH="$2"
R2_S3_PATH="$3"
BASENAME_WITH_LANE="$4"
S3_INPUT_TXT_BUCKET_NAME="$5"
SPLIT_LINES="${6:-${SPLIT_LINES:-16000000}}"  # lines per split (default 16M = 4M reads)
if [[ -z "${SPLIT_LINES}" || ! "${SPLIT_LINES}" =~ ^[0-9]+$ || "${SPLIT_LINES}" -le 0 ]]; then
  echo "ERROR: SPLIT_LINES must be a positive integer (got '${SPLIT_LINES}')" >&2
  exit 1
fi

if (( SPLIT_LINES % 4 != 0 )); then
  echo "ERROR: SPLIT_LINES must be divisible by 4 (FASTQ = 4 lines/read). Got '$SPLIT_LINES'." >&2
  exit 1
fi


echo "$R1_S3_PATH"
echo "$R2_S3_PATH"

# Extract File Names
R1_FILE=$(basename "$R1_S3_PATH")
R2_FILE=$(basename "$R2_S3_PATH")
R1_BASE="${R1_FILE%.fastq.gz}"
R2_BASE="${R2_FILE%.fastq.gz}"

if [[ "${LOCAL_FASTQ_INPUT:-0}" == "1" ]]; then
    R1_LOCAL_PATH="$R1_S3_PATH"
    R2_LOCAL_PATH="$R2_S3_PATH"
    [[ -f "$R1_LOCAL_PATH" ]] || { echo "ERROR: local R1 not found: $R1_LOCAL_PATH" >&2; exit 1; }
    [[ -f "$R2_LOCAL_PATH" ]] || { echo "ERROR: local R2 not found: $R2_LOCAL_PATH" >&2; exit 1; }
else
    R1_S3_FULL_PATH="s3://$BUCKET_NAME/$R1_S3_PATH"
    R2_S3_FULL_PATH="s3://$BUCKET_NAME/$R2_S3_PATH"
    echo "full paths"
    echo "$R1_S3_FULL_PATH"
    echo "$R2_S3_FULL_PATH"
    R1_LOCAL_PATH="/mnt/nvme/$R1_FILE"
    R2_LOCAL_PATH="/mnt/nvme/$R2_FILE"
fi

# Caller sets DECOMP_THREADS so concurrent lanes still fit on the box.
# Default is 8 (fastest setting we measured on a single gzip stream).
DECOMP_THREADS="${DECOMP_THREADS:-8}"
(( DECOMP_THREADS < 1 )) && DECOMP_THREADS=1
FASTQ_DECOMPRESSOR="${FASTQ_DECOMPRESSOR:-rapidgzip}"
[[ "$FASTQ_DECOMPRESSOR" == "gzip" || "$FASTQ_DECOMPRESSOR" == "rapidgzip" ]] || {
    echo "ERROR: FASTQ_DECOMPRESSOR must be gzip or rapidgzip" >&2
    exit 1
}

# Download the gzip to NVMe first, then decompress the local file.
# Piping `aws s3 cp -` into rapidgzip blocks multipart download and
# rapidgzip seek parallelism (Hong, Aug 2026).
DOWNLOAD_START_NS=$(date +%s%N)
if [[ "${LOCAL_FASTQ_INPUT:-0}" == "1" ]]; then
    echo "Reading compressed FASTQ files directly from NVMe..."
    record_split_timing "locate_nvme_fastq" "$DOWNLOAD_START_NS"
else
    echo "Downloading compressed FASTQ files from S3..."
    aws s3 cp "$R1_S3_FULL_PATH" "$R1_LOCAL_PATH" --only-show-errors &
    R1_DL_PID=$!
    aws s3 cp "$R2_S3_FULL_PATH" "$R2_LOCAL_PATH" --only-show-errors &
    R2_DL_PID=$!
    wait "$R1_DL_PID" || { echo "ERROR: R1 download failed for $R1_FILE" >&2; exit 1; }
    wait "$R2_DL_PID" || { echo "ERROR: R2 download failed for $R2_FILE" >&2; exit 1; }
    record_split_timing "download_compressed_fastq" "$DOWNLOAD_START_NS"
fi

# The driver chooses gzip for one CPU per file and rapidgzip when multiple CPUs
# are apportioned to each active compressed input.
DECOMPRESS_START_NS=$(date +%s%N)
if [[ "$FASTQ_DECOMPRESSOR" == "gzip" ]]; then
    echo "Decompressing local files with single-threaded gzip"
    echo "Splitting local FASTQ files (split every $SPLIT_LINES lines)..."
    gzip -dc -- "$R1_LOCAL_PATH" | split -l "$SPLIT_LINES" -d -a 4 --additional-suffix=.fastq - "/mnt/nvme/${R1_BASE}_p" &
    R1_PID=$!
    gzip -dc -- "$R2_LOCAL_PATH" | split -l "$SPLIT_LINES" -d -a 4 --additional-suffix=.fastq - "/mnt/nvme/${R2_BASE}_p" &
    R2_PID=$!
elif command -v rapidgzip >/dev/null 2>&1; then
    echo "Decompressing local files with rapidgzip (-P $DECOMP_THREADS)"
    echo "Splitting local FASTQ files (split every $SPLIT_LINES lines)..."
    rapidgzip -d -c -P "$DECOMP_THREADS" "$R1_LOCAL_PATH" | split -l "$SPLIT_LINES" -d -a 4 --additional-suffix=.fastq - "/mnt/nvme/${R1_BASE}_p" &
    R1_PID=$!
    rapidgzip -d -c -P "$DECOMP_THREADS" "$R2_LOCAL_PATH" | split -l "$SPLIT_LINES" -d -a 4 --additional-suffix=.fastq - "/mnt/nvme/${R2_BASE}_p" &
    R2_PID=$!
else
    echo "WARNING: rapidgzip not on PATH, falling back to zcat" >&2
    echo "Splitting local FASTQ files (split every $SPLIT_LINES lines)..."
    gzip -dc -- "$R1_LOCAL_PATH" | split -l "$SPLIT_LINES" -d -a 4 --additional-suffix=.fastq - "/mnt/nvme/${R1_BASE}_p" &
    R1_PID=$!
    gzip -dc -- "$R2_LOCAL_PATH" | split -l "$SPLIT_LINES" -d -a 4 --additional-suffix=.fastq - "/mnt/nvme/${R2_BASE}_p" &
    R2_PID=$!
fi
wait "$R1_PID" || { echo "ERROR: R1 split failed for $R1_BASE" >&2; rm -f "$R1_LOCAL_PATH" "$R2_LOCAL_PATH"; exit 1; }
wait "$R2_PID" || { echo "ERROR: R2 split failed for $R2_BASE" >&2; rm -f "$R1_LOCAL_PATH" "$R2_LOCAL_PATH"; exit 1; }
record_split_timing "decompress_and_split_fastq" "$DECOMPRESS_START_NS"
if [[ "${LOCAL_FASTQ_INPUT:-0}" != "1" ]]; then
    rm -f "$R1_LOCAL_PATH" "$R2_LOCAL_PATH"
fi

# Rename files to remove zero padding (_p00 -> _p0, _p01 -> _p1, etc.)
echo "Renaming split files..."
find /mnt/nvme/ -maxdepth 1 -type f -name "${R1_BASE}_p*.fastq" | while read -r file; do
    new_name=$(echo "$file" | sed -E 's/_p0+([0-9])/_p\1/')
    if [[ "$file" != "$new_name" ]]; then
        mv "$file" "$new_name"
    fi
done

find /mnt/nvme/ -maxdepth 1 -type f -name "${R2_BASE}_p*.fastq" | while read -r file; do
    new_name=$(echo "$file" | sed -E 's/_p0+([0-9])/_p\1/')
    if [[ "$file" != "$new_name" ]]; then
        mv "$file" "$new_name"
    fi
done

# Count number of file pairs
PAIR_COUNT=$(find /mnt/nvme/ -maxdepth 1 -type f -name "${R1_BASE}_p*.fastq" | wc -l)
echo "Total file pairs: $PAIR_COUNT"

# Upload R1 and R2 split files
echo "Uploading R1 and R2 split files first..."
FASTQ_UPLOAD_START_NS=$(date +%s%N)
UPLOAD_LIST_R1R2="/mnt/nvme/${BASENAME_WITH_LANE}_upload_list_r1r2.txt"

# Ensure the parent directory exists
mkdir -p "$(dirname "$UPLOAD_LIST_R1R2")"
> "$UPLOAD_LIST_R1R2"

find /mnt/nvme/ -maxdepth 1 -type f -name "${R1_BASE}_p*.fastq" | while read -r r1_file; do
    suffix=$(basename "$r1_file" | grep -oP '_p\d+')
    r2_file="/mnt/nvme/${R2_BASE}${suffix}.fastq"

    if [[ ! -f "$r2_file" ]]; then
        echo "ERROR: missing R2 split mate for $r1_file (expected $r2_file)" >&2
        exit 1
    fi
    echo "$r1_file s3://$BUCKET_NAME/${BASENAME_WITH_LANE}_R1_001${suffix}.fastq" >> "$UPLOAD_LIST_R1R2"
    echo "$r2_file s3://$BUCKET_NAME/${BASENAME_WITH_LANE}_R2_001${suffix}.fastq" >> "$UPLOAD_LIST_R1R2"
done

if [[ -s "$UPLOAD_LIST_R1R2" ]]; then
    if ! xargs -a "$UPLOAD_LIST_R1R2" -n 2 -P 10 aws s3 cp --only-show-errors; then
        echo "ERROR: one or more FASTQ shard uploads failed; input manifests will not be published" >&2
        exit 1
    fi
    rm -f "$UPLOAD_LIST_R1R2"
fi

echo "R1 and R2 split files uploaded successfully!"
record_split_timing "upload_fastq_shards" "$FASTQ_UPLOAD_START_NS"

# Create and Upload input.txt Files
echo "Creating input.txt files and preparing for upload..."
MANIFEST_UPLOAD_START_NS=$(date +%s%N)

UPLOAD_LIST_INPUT="/mnt/nvme/${BASENAME_WITH_LANE}_upload_list_input.txt"
mkdir -p "$(dirname "$UPLOAD_LIST_INPUT")"
> "$UPLOAD_LIST_INPUT"

find /mnt/nvme/ -maxdepth 1 -type f -name "${R1_BASE}_p*.fastq" | while read -r r1_file; do
    suffix=$(basename "$r1_file" | grep -oP '_p\d+')
    r2_file="/mnt/nvme/${R2_BASE}${suffix}.fastq"

    BASE_NAME=$(echo "$R1_BASE" | sed -E 's/_R1_001//')
    input_file="/mnt/nvme/${BASE_NAME}${suffix}_input.txt"

    if [[ -f "$r1_file" && -f "$r2_file" ]]; then
        echo "Creating input.txt for $suffix"
        echo "s3://$BUCKET_NAME/${BASENAME_WITH_LANE}_R1_001${suffix}.fastq" > "$input_file"
        echo "s3://$BUCKET_NAME/${BASENAME_WITH_LANE}_R2_001${suffix}.fastq" >> "$input_file"
        echo "$input_file s3://${S3_INPUT_TXT_BUCKET_NAME}/${BASENAME_WITH_LANE}${suffix}_input.txt" >> "$UPLOAD_LIST_INPUT"
    fi
done

if [[ -s "$UPLOAD_LIST_INPUT" ]]; then
    if ! xargs -a "$UPLOAD_LIST_INPUT" -n 2 -P 10 aws s3 cp --only-show-errors; then
        echo "ERROR: one or more Lambda input-manifest uploads failed" >&2
        exit 1
    fi
    rm -f "$UPLOAD_LIST_INPUT"
else
    echo "No input.txt files found for upload!"
fi

echo "Input.txt files uploaded successfully!"
record_split_timing "publish_lambda_input_manifests" "$MANIFEST_UPLOAD_START_NS"

# Delete split R1, R2, and input.txt files after processing
echo "Cleaning up local files..."
CLEANUP_START_NS=$(date +%s%N)

# Delete R1 and R2 split files
find /mnt/nvme/ -maxdepth 1 -type f -name "${R1_BASE}_p*.fastq" -exec rm -f {} +
find /mnt/nvme/ -maxdepth 1 -type f -name "${R2_BASE}_p*.fastq" -exec rm -f {} +

# Remove leading directory from BASENAME_WITH_LANE to match actual filenames
BASENAME_CLEANED=$(basename "$BASENAME_WITH_LANE")

# Delete input.txt files
find /mnt/nvme/ -maxdepth 1 -type f -name "${BASENAME_CLEANED}_p*_input.txt" -exec rm -f {} +

# Delete upload list files
rm -f "$UPLOAD_LIST_R1R2" "$UPLOAD_LIST_INPUT"

echo "Cleanup completed!"
record_split_timing "cleanup_local_split_files" "$CLEANUP_START_NS"
record_split_timing "lane_split_upload_total" "$SPLIT_TOTAL_START_NS"

# Print PAIR_COUNT for Python to capture
echo "$PAIR_COUNT"
