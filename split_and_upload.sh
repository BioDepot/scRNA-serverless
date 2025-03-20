#!/bin/bash

# Receive arguments from Python
BUCKET_NAME="$1"
R1_S3_PATH="$2"
R2_S3_PATH="$3"
BASENAME_WITH_LANE="$4"
S3_INPUT_TXT_BUCKET_NAME="$5"

echo "$R1_S3_PATH"
echo "$R2_S3_PATH"

# Construct the correct full S3 paths
R1_S3_FULL_PATH="s3://$BUCKET_NAME/$R1_S3_PATH"
R2_S3_FULL_PATH="s3://$BUCKET_NAME/$R2_S3_PATH"
echo "full paths"
echo "$R1_S3_FULL_PATH"
echo "$R2_S3_FULL_PATH"
# Extract File Names
R1_FILE=$(basename "$R1_S3_PATH")
R2_FILE=$(basename "$R2_S3_PATH")
R1_BASE="${R1_FILE%.fastq.gz}"
R2_BASE="${R2_FILE%.fastq.gz}"

echo "Streaming & Splitting FASTQ files from S3..."
aws s3 cp "$R1_S3_FULL_PATH" - | zcat | split -l 16000000 -d --additional-suffix=.fastq - "/mnt/nvme/${R1_BASE}_p" &
aws s3 cp "$R2_S3_FULL_PATH" - | zcat | split -l 16000000 -d --additional-suffix=.fastq - "/mnt/nvme/${R2_BASE}_p" &
wait

# Rename files to remove zero padding (_p00 -> _p0, _p01 -> _p1, etc.)
echo "Renaming split files..."
find /mnt/nvme/ -type f -name "${R1_BASE}_p*.fastq" | while read file; do
    new_name=$(echo "$file" | sed -E 's/_p0([0-9])([^0-9]|$)/_p\1\2/')
    [[ "$file" != "$new_name" ]] && mv "$file" "$new_name"
done

find /mnt/nvme/ -type f -name "${R2_BASE}_p*.fastq" | while read file; do
    new_name=$(echo "$file" | sed -E 's/_p0([0-9])([^0-9]|$)/_p\1\2/')
    [[ "$file" != "$new_name" ]] && mv "$file" "$new_name"
done

# Count number of file pairs
PAIR_COUNT=$(find /mnt/nvme/ -type f -name "${R1_BASE}_p*.fastq" | wc -l)
echo "Total file pairs: $PAIR_COUNT"

# Upload R1 and R2 split files
echo "Uploading R1 and R2 split files first..."
UPLOAD_LIST_R1R2="/mnt/nvme/${BASENAME_WITH_LANE}_upload_list_r1r2.txt"

# Ensure the parent directory exists
mkdir -p "$(dirname "$UPLOAD_LIST_R1R2")"
> "$UPLOAD_LIST_R1R2"

find /mnt/nvme/ -type f -name "${R1_BASE}_p*.fastq" | while read r1_file; do
    suffix=$(basename "$r1_file" | grep -oP '_p\d+')
    r2_file="/mnt/nvme/${R2_BASE}${suffix}.fastq"

    [[ -f "$r1_file" ]] && echo "$r1_file s3://$BUCKET_NAME/${BASENAME_WITH_LANE}_R1_001${suffix}.fastq" >> "$UPLOAD_LIST_R1R2"
    [[ -f "$r2_file" ]] && echo "$r2_file s3://$BUCKET_NAME/${BASENAME_WITH_LANE}_R2_001${suffix}.fastq" >> "$UPLOAD_LIST_R1R2"
done

if [[ -s "$UPLOAD_LIST_R1R2" ]]; then
    cat "$UPLOAD_LIST_R1R2" | xargs -n 2 -P 10 aws s3 cp --only-show-errors
    rm -f "$UPLOAD_LIST_R1R2"
fi

echo "R1 and R2 split files uploaded successfully!"

# Create and Upload input.txt Files
echo "Creating input.txt files and preparing for upload..."

UPLOAD_LIST_INPUT="/mnt/nvme/${BASENAME_WITH_LANE}_upload_list_input.txt"
mkdir -p "$(dirname "$UPLOAD_LIST_INPUT")"
> "$UPLOAD_LIST_INPUT"

find /mnt/nvme/ -type f -name "${R1_BASE}_p*.fastq" | while read r1_file; do
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
    cat "$UPLOAD_LIST_INPUT" | xargs -n 2 -P 10 aws s3 cp --only-show-errors
    rm -f "$UPLOAD_LIST_INPUT"
else
    echo "No input.txt files found for upload!"
fi

echo "Input.txt files uploaded successfully!"

# Delete split R1, R2, and input.txt files after processing
echo "Cleaning up local files..."

# Delete R1 and R2 split files
find /mnt/nvme/ -type f -name "${R1_BASE}_p*.fastq" -exec rm -f {} +
find /mnt/nvme/ -type f -name "${R2_BASE}_p*.fastq" -exec rm -f {} +

# Remove leading directory from BASENAME_WITH_LANE to match actual filenames
BASENAME_CLEANED=$(basename "$BASENAME_WITH_LANE")

# Delete input.txt files
find /mnt/nvme/ -type f -name "${BASENAME_CLEANED}_p*_input.txt" -exec rm -f {} +

# Delete upload list files
rm -f "$UPLOAD_LIST_R1R2" "$UPLOAD_LIST_INPUT"

echo "Cleanup completed!"

# Print PAIR_COUNT for Python to capture
echo "$PAIR_COUNT"
