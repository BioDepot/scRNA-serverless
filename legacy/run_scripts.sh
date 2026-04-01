#!/bin/bash

# Set permissions to stop the script if any command fails
set -e

# Variables for AWS resources
AWS_REGION="us-east-2"
AWS_ACCOUNT_ID="509248752274"
ECR_REPO_NAME="sc-rna-serverless-pipeline-f"
DOCKER_IMAGE_NAME="scrna-pipeline-f"
LAMBDA_FUNCTION_NAME="serverless-scrna-132-f"
LAMBDA_EXECUTION_ROLE_NAME="scrna-lambda-f"

#MSK
#S3_INPUT_BUCKET_NAME='nnasam-data-morphic-msk'
#S3_INPUT_TXT_BUCKET_NAME='nnasam-data-morphic-input-msk'
#S3_OUTPUT_BUCKET_NAME='nnasam-output-morphic-msk'
# Final output bucket
#SCRNA_OUTPUT_S3_BUCKET="msk-scrna-output"
#OUTPUT_BASE_DIR="/mnt/nvme/morphic-msk-final-pipeline"

#PBMC 1K
#S3_INPUT_BUCKET_NAME='nnasam-data-pbmc1k'
#S3_INPUT_TXT_BUCKET_NAME='nnasam-data-input-pbmc1k'
#S3_OUTPUT_BUCKET_NAME='nnasam-output-pbmc1k'
# Final output bucket
#SCRNA_OUTPUT_S3_BUCKET="pbmc1k-scrna-output"
#OUTPUT_BASE_DIR="/mnt/nvme/pbmc1k-final-pipeline"

#PBMC 10K
S3_INPUT_BUCKET_NAME='nnasam-data-pbmc10k'
S3_INPUT_TXT_BUCKET_NAME='nnasam-data-input-pbmc10k'
S3_OUTPUT_BUCKET_NAME='nnasam-output-pbmc10k'
# Final output bucket
SCRNA_OUTPUT_S3_BUCKET="pbmc10k-scrna-output"
OUTPUT_BASE_DIR="/mnt/nvme/pbmc10k-final-pipeline"

# Variables for input/output folders
HOME_DIR='/home/ubuntu/final-pipeline'
OUTPUT_DIR="$OUTPUT_BASE_DIR/output"
COMBINED_OUTPUT_DIR="$OUTPUT_BASE_DIR/combined_output"
QUANT_DIR="$OUTPUT_BASE_DIR/quant"
DOCKERFILE_DIR="$HOME_DIR/scrna-pipeline"
TRANSCRIPTOME_GENE_MAPPING="/mnt/nvme/reference/t2g.tsv"

POLLING_INTERVAL="30"

# Run set-up-resources.py
echo "****** Running set-up-resources.py..."
python3 set-up-resources.py \
    --aws_region "$AWS_REGION" \
    --aws_account_id "$AWS_ACCOUNT_ID" \
    --ecr_repo_name "$ECR_REPO_NAME" \
    --docker_image_name "$DOCKER_IMAGE_NAME" \
    --lambda_function_name "$LAMBDA_FUNCTION_NAME" \
    --lambda_execution_role_name "$LAMBDA_EXECUTION_ROLE_NAME" \
    --s3_bucket_name "$S3_INPUT_BUCKET_NAME" \
    --s3_input_files_bucket_name "$S3_INPUT_TXT_BUCKET_NAME" \
    --s3_output_bucket_name "$S3_OUTPUT_BUCKET_NAME" \
    --final_output_bucket_name "$SCRNA_OUTPUT_S3_BUCKET" \
    --dockerfile_dir "$DOCKERFILE_DIR"

if [ $? -eq 0 ]; then
    echo "****** set-up-resources.py completed successfully."
else
    echo "****** set-up-resources.py failed."
    exit 1
fi

start_time=$(date +%s)
echo "Start time: $(date)"

# Run process_fastq_v2.py
echo "****** Running process_fastq.py..."
python3 process_fastq.py \
    --aws_region "$AWS_REGION" \
    --bucket_name "$S3_INPUT_BUCKET_NAME" \
    --s3_input_files_bucket_name "$S3_INPUT_TXT_BUCKET_NAME" \
    --output_bucket_name "$S3_OUTPUT_BUCKET_NAME" \
    --output_dir "$OUTPUT_DIR" \
    --polling_interval "$POLLING_INTERVAL"

if [ $? -eq 0 ]; then
    echo "****** process_fastq.py completed successfully."
else
    echo "****** process_fastq.py failed."
    exit 1
fi

# Run combine_output_rad.sh to concatenate map.rad files
echo "****** Running combine_map_rad.sh..."
crad_start_time=$(date +%s)
./combine_map_rad.sh "$OUTPUT_DIR" "$COMBINED_OUTPUT_DIR"
crad_end_time=$(date +%s)
crad_elapsed_time=$((crad_end_time - crad_start_time))
crad_elapsed_minutes=$(echo "scale=2; $crad_elapsed_time / 60" | bc)

if [ $? -eq 0 ]; then
    echo "****** combine_map_rad.sh completed successfully in $crad_elapsed_time"
else
    echo "****** combine_map_rad.sh failed."
    exit 1
fi

# Run combine_output_unmapped_bc_count_bin.sh to concatenate unmapped_bc_count.bin files
echo "****** Running combine_unmapped_bc_count_bin.sh..."
cbin_start_time=$(date +%s)
./combine_unmapped_bc_count_bin.sh "$OUTPUT_DIR" "$COMBINED_OUTPUT_DIR"
cbin_end_time=$(date +%s)
cbin_elapsed_time=$((cbin_end_time - cbin_start_time))
cbin_elapsed_minutes=$(echo "scale=2; $cbin_elapsed_time / 60" | bc)

if [ $? -eq 0 ]; then
    echo "****** combine_unmapped_bc_count_bin.sh completed successfully in $cbin_elapsed_minutes"
else
    echo "****** combine_unmapped_bc_count_bin.sh failed."
    exit 1
fi

ulimit -n 2048

#Run alevin_process.sh to generate quant files using alevin-fry
echo "****** Running alevin_process.sh..."
alevin_start_time=$(date +%s)
./alevin_process.sh "$COMBINED_OUTPUT_DIR" "$QUANT_DIR" "$TRANSCRIPTOME_GENE_MAPPING"
alevin_end_time=$(date +%s)
alevin_elapsed_time=$((alevin_end_time - alevin_start_time))
alevin_elapsed_minutes=$(echo "scale=2; $alevin_elapsed_time / 60" | bc)

if [ $? -eq 0 ]; then
    echo "****** alevin_process.sh completed successfully in $alevin_elapsed_minutes."
else
    echo "****** alevin_process.sh failed."
    exit 1
fi
echo "****** All scripts completed successfully!"


#upload output files to s3 bucket
upload_start_time=$(date +%s)

# Upload quant files in parallel
echo "Uploading quant files..."
aws s3 sync "$QUANT_DIR/alevin" "s3://$SCRNA_OUTPUT_S3_BUCKET/quant/alevin" --storage-class INTELLIGENT_TIERING --only-show-errors &

# Wait for background jobs to finish
wait
upload_end_time=$(date +%s)
upload_elapsed_time=$((upload_end_time - upload_start_time))
upload_elapsed_minutes=$(echo "scale=2; $upload_elapsed_time / 60" | bc)
echo "****** Upload completed successfully in $upload_elapsed_minutes."


end_time=$(date +%s)
echo "End time: $(date)"
elapsed_time=$((end_time - start_time))
elapsed_minutes=$(echo "scale=2; $elapsed_time / 60" | bc)

echo "The over all process(s3splitfileupload - quant)  took $elapsed_minutes minutes to complete"
