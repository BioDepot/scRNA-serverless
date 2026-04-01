#!/bin/bash

# Variables for AWS resources
AWS_REGION="us-east-2"
ECR_REPO_NAME="sc-rna-serverless-pipeline-f"
LAMBDA_EXECUTION_ROLE_NAME="scrna-lambda-f"
LAMBDA_FUNCTION_NAME="serverless-scrna-132-f"
#MSK
#S3_INPUT_BUCKET_NAME='nnasam-data-morphic-msk'
#S3_OUTPUT_BUCKET_NAME='nnasam-output-morphic-msk'
#S3_INPUT_TXT_BUCKET_NAME='nnasam-data-morphic-input-msk'

#pbmc1k
#S3_INPUT_BUCKET_NAME='nnasam-data-pbmc1k'
#S3_OUTPUT_BUCKET_NAME='nnasam-output-pbmc1k'
#S3_INPUT_TXT_BUCKET_NAME='nnasam-data-input-pbmc1k'

#pbmc10k
S3_INPUT_BUCKET_NAME='nnasam-data-pbmc10k'
S3_OUTPUT_BUCKET_NAME='nnasam-output-pbmc10k'
S3_INPUT_TXT_BUCKET_NAME='nnasam-data-input-pbmc10k'
# Delete S3 buckets, Lambda function, and ECR repository
echo "****** Deleting AWS resources..."
python3 delete_aws_resources.py \
    --aws_region "$AWS_REGION" \
    --s3_output_bucket "$S3_OUTPUT_BUCKET_NAME" \
    --s3_input_txt_bucket "$S3_INPUT_TXT_BUCKET_NAME" \
    --lambda_function_name "$LAMBDA_FUNCTION_NAME" \
    --lambda_execution_role_name "$LAMBDA_EXECUTION_ROLE_NAME" \
    --ecr_repository_name "$ECR_REPO_NAME"

if [ $? -eq 0 ]; then
    echo "****** AWS resources deleted successfully."
else
    echo "****** AWS resources deletion failed."
    exit 1
fi

echo "****** Deleting input and split files from s3"
python3 delete_generated_files_s3.py "$S3_INPUT_BUCKET_NAME"
