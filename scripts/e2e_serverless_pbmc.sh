#!/usr/bin/env bash
################################################################################
# e2e_serverless_pbmc.sh
#
# End-to-end serverless scRNA pipeline for PBMC datasets.
#
# USAGE:
#   # Driver mode (default): launch EC2 instance, run pipeline on it
#   bash scripts/e2e_serverless_pbmc.sh pbmc1k
#   bash scripts/e2e_serverless_pbmc.sh pbmc10k
#
#   # Run mode (on EC2 instance):
#   bash scripts/e2e_serverless_pbmc.sh pbmc1k --run
#
# ENVIRONMENT VARIABLES (set before calling):
#   SEED_AMI_ID            Required in driver mode. AMI with pre-installed reference data.
#   AWS_REGION             AWS region (default: us-east-2)
#   INSTANCE_TYPE          EC2 instance type (default: m6id.16xlarge)
#   ROOT_VOL_GB            EBS root volume size in GB (default: 200)
#   KEY_NAME               Required in driver mode. Existing EC2 keypair name.
#   KEY_PEM_PATH           Required in driver mode. Path to .pem file for SSH.
#   SUBNET_ID              Required in driver mode. VPC subnet ID.
#   SG_ID                  Required in driver mode. Security group ID.
#
#   LAMBDA_MEMORY_MB       Lambda function memory (default: 10240)
#   LAMBDA_EPHEMERAL_MB    Lambda /tmp ephemeral storage (default: 10240)
#   LAMBDA_TIMEOUT_SEC     Lambda timeout in seconds (default: 900)
#   THREADS                Number of CPU threads (default: nproc)
#   CLEANUP_AWS            Clean up AWS resources after pipeline (default: 1)
#   TERMINATE_DRIVER_ON_EXIT  Terminate EC2 instance on exit (default: 1)
#
#   FASTQ_TAR_PATH         Optional: path to local FASTQ tar file on instance.
#   FASTQ_TAR_URL          Optional: direct URL to FASTQ tar (NOT landing page).
#   WRITE_H5AD             Save h5ad output from QC (default: 0)
#   RUN_ID                 Run identifier (auto-generated if empty)
#
# FASTQ_TAR_URL IMPORTANT:
#   Must be a direct downloadable URL to a tar file. 
#   Do NOT use dataset landing page URLs.
#
################################################################################

set -euo pipefail

################################################################################
# Default Configuration
################################################################################

# AWS Configuration
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?ERROR: AWS_ACCOUNT_ID must be set}"
AWS_REGION="${AWS_REGION:-us-east-2}"
SEED_AMI_ID="${SEED_AMI_ID:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-m6id.16xlarge}"
ROOT_VOL_GB="${ROOT_VOL_GB:-200}"
KEY_NAME="${KEY_NAME:-}"
KEY_PEM_PATH="${KEY_PEM_PATH:-}"
SUBNET_ID="${SUBNET_ID:-}"
SG_ID="${SG_ID:-}"

# Lambda Configuration
LAMBDA_MEMORY_MB="${LAMBDA_MEMORY_MB:-10240}"
LAMBDA_EPHEMERAL_MB="${LAMBDA_EPHEMERAL_MB:-10240}"
LAMBDA_TIMEOUT_SEC="${LAMBDA_TIMEOUT_SEC:-900}"

# Execution Configuration
THREADS="${THREADS:-$(nproc)}"
CLEANUP_AWS="${CLEANUP_AWS:-1}"
TERMINATE_DRIVER_ON_EXIT="${TERMINATE_DRIVER_ON_EXIT:-1}"

# FASTQ Configuration
FASTQ_TAR_PATH="${FASTQ_TAR_PATH:-}"
FASTQ_TAR_URL="${FASTQ_TAR_URL:-}"
WRITE_H5AD="${WRITE_H5AD:-0}"
RUN_ID="${RUN_ID:-}"

# Derived values (will be set later)
RUN_MODE=0
DATASET=""
DRIVER_INSTANCE_ID=""
DRIVER_INSTANCE_IP=""

################################################################################
# Helper Functions
################################################################################

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

die() {
    log_error "$@"
    exit 1
}

################################################################################
# Argument Parsing
################################################################################

if [[ $# -lt 1 ]]; then
    cat >&2 <<EOF
Usage: $0 <dataset> [--run]
  dataset: pbmc1k or pbmc10k
  --run: Execute in run mode on EC2 (default: driver mode)
EOF
    exit 1
fi

DATASET="$1"
if [[ "$DATASET" != "pbmc1k" && "$DATASET" != "pbmc10k" ]]; then
    die "Unknown dataset: $DATASET (must be pbmc1k or pbmc10k)"
fi

if [[ $# -gt 1 && "$2" == "--run" ]]; then
    RUN_MODE=1
fi

################################################################################
# Generate Run ID and Resource Names
################################################################################

if [[ -z "$RUN_ID" ]]; then
    RUN_ID="pbmc-$(date +%s)-$(head -c 4 /dev/urandom | xxd -p)"
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
UNIQUE_SUFFIX="${TIMESTAMP}_${RANDOM}"

# Resource names (must be globally unique)
ECR_REPO_NAME="scrna-serverless-${UNIQUE_SUFFIX}"
LAMBDA_FUNCTION_NAME="scrna-map-${UNIQUE_SUFFIX}"
EVENTBRIDGE_RULE_NAME="scrna-rule-${UNIQUE_SUFFIX}"

# S3 bucket names (must be lowercase, globally unique)
INPUT_FASTQ_BUCKET="scrna-input-fastq-${AWS_ACCOUNT_ID}-${UNIQUE_SUFFIX,,}"
INPUT_TXT_BUCKET="scrna-input-txt-${AWS_ACCOUNT_ID}-${UNIQUE_SUFFIX,,}"
OUTPUT_MAP_BUCKET="scrna-output-map-${AWS_ACCOUNT_ID}-${UNIQUE_SUFFIX,,}"
OUTPUT_QUANT_BUCKET="scrna-output-quant-${AWS_ACCOUNT_ID}-${UNIQUE_SUFFIX,,}"

################################################################################
# Mode: Driver (Launch EC2 and run pipeline)
################################################################################

if [[ $RUN_MODE -eq 0 ]]; then
    log_info "======== E2E Serverless scRNA Pipeline (DRIVER MODE) ========"
    log_info "Dataset: $DATASET"
    log_info "Run ID: $RUN_ID"
    
    # Validate driver mode requirements
    [[ -n "$SEED_AMI_ID" ]] || die "SEED_AMI_ID must be set in driver mode"
    [[ -n "$KEY_NAME" ]] || die "KEY_NAME must be set in driver mode"
    [[ -n "$KEY_PEM_PATH" ]] || die "KEY_PEM_PATH must be set in driver mode"
    [[ -n "$SUBNET_ID" ]] || die "SUBNET_ID must be set in driver mode"
    [[ -n "$SG_ID" ]] || die "SG_ID must be set in driver mode"
    [[ -f "$KEY_PEM_PATH" ]] || die "KEY_PEM_PATH does not exist: $KEY_PEM_PATH"
    
    log_info "Launching EC2 instance from AMI $SEED_AMI_ID..."
    DRIVER_INSTANCE_ID=$(aws ec2 run-instances \
        --region "$AWS_REGION" \
        --image-id "$SEED_AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SG_ID" \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_VOL_GB,VolumeType=gp3}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=scrna-e2e-$RUN_ID}]" \
        --query "Instances[0].InstanceId" \
        --output text)
    
    log_info "Instance launched: $DRIVER_INSTANCE_ID"
    
    log_info "Waiting for instance to reach running state..."
    aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$DRIVER_INSTANCE_ID"
    
    log_info "Waiting for public IP..."
    for i in {1..20}; do
        DRIVER_INSTANCE_IP=$(aws ec2 describe-instances \
            --region "$AWS_REGION" \
            --instance-ids "$DRIVER_INSTANCE_ID" \
            --query "Reservations[0].Instances[0].PublicIpAddress" \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "$DRIVER_INSTANCE_IP" && "$DRIVER_INSTANCE_IP" != "None" ]]; then
            break
        fi
        sleep 2
    done
    
    if [[ -z "$DRIVER_INSTANCE_IP" ]]; then
        die "Instance has no public IP. Check subnet auto-assign setting."
    fi
    
    log_info "Instance IP: $DRIVER_INSTANCE_IP"
    
    log_info "Waiting for SSH readiness..."
    sleep 20
    for i in {1..30}; do
        if ssh -i "$KEY_PEM_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 "ubuntu@$DRIVER_INSTANCE_IP" "echo OK" >/dev/null 2>&1; then
            log_info "SSH is ready"
            break
        fi
        sleep 2
    done
    
    log_info "Copying repository to instance..."
    REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    tar -czf "/tmp/scrna-repo-$$.tar.gz" -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")"
    
    scp -i "$KEY_PEM_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "/tmp/scrna-repo-$$.tar.gz" "ubuntu@$DRIVER_INSTANCE_IP:/tmp/"
    
    rm -f "/tmp/scrna-repo-$$.tar.gz"
    
    log_info "Extracting repository on instance..."
    ssh -i "$KEY_PEM_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "ubuntu@$DRIVER_INSTANCE_IP" "cd /tmp && tar -xzf scrna-repo-$$.tar.gz && mv scRNA-serverless /home/ubuntu/scrna-repo"
    
    log_info "Running pipeline in --run mode on instance..."
    
    # Export environment variables and run --run mode
    ssh -i "$KEY_PEM_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "ubuntu@$DRIVER_INSTANCE_IP" <<SSHEOF
export AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID
export AWS_REGION=$AWS_REGION
export LAMBDA_MEMORY_MB=$LAMBDA_MEMORY_MB
export LAMBDA_EPHEMERAL_MB=$LAMBDA_EPHEMERAL_MB
export LAMBDA_TIMEOUT_SEC=$LAMBDA_TIMEOUT_SEC
export THREADS=$THREADS
export CLEANUP_AWS=$CLEANUP_AWS
export FASTQ_TAR_PATH=$FASTQ_TAR_PATH
export FASTQ_TAR_URL=$FASTQ_TAR_URL
export WRITE_H5AD=$WRITE_H5AD
export RUN_ID=$RUN_ID

cd /home/ubuntu/scrna-repo
bash scripts/e2e_serverless_pbmc.sh $DATASET --run
SSHEOF
    
    RUN_EXIT=$?
    
    if [[ $TERMINATE_DRIVER_ON_EXIT -eq 1 ]]; then
        log_info "Terminating driver instance $DRIVER_INSTANCE_ID..."
        aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$DRIVER_INSTANCE_ID" >/dev/null 2>&1 || true
    else
        log_info "Driver instance $DRIVER_INSTANCE_ID left running (TERMINATE_DRIVER_ON_EXIT=0)"
    fi
    
    exit $RUN_EXIT
fi

################################################################################
# Mode: Run (Execute pipeline on EC2)
################################################################################

log_info "======== E2E Serverless scRNA Pipeline (RUN MODE) ========"
log_info "Dataset: $DATASET"
log_info "Run ID: $RUN_ID"

# Create run directory
RUN_DIR="/mnt/nvme/runs/$RUN_ID"
mkdir -p "$RUN_DIR"

log_info "Run directory: $RUN_DIR"

################################################################################
# Step 0: Bootstrap Tools
################################################################################

log_info "Step 0: Bootstrapping tools..."

# Check if this is the first run
if ! command -v python3 &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y \
        python3 python3-venv python3-pip \
        git jq curl tar gzip \
        awscli docker.io
    
    sudo usermod -aG docker ubuntu
fi

log_info "Tools ready"

################################################################################
# Step 1: Prepare FASTQs
################################################################################

log_info "Step 1: Preparing FASTQs..."

FASTQ_DIR="$RUN_DIR/fastq"
mkdir -p "$FASTQ_DIR"

# Obtain FASTQ tar
if [[ -n "$FASTQ_TAR_PATH" ]]; then
    log_info "Extracting FASTQ tar from: $FASTQ_TAR_PATH"
    tar -xzf "$FASTQ_TAR_PATH" -C "$FASTQ_DIR"
elif [[ -n "$FASTQ_TAR_URL" ]]; then
    log_info "Downloading FASTQ tar from: $FASTQ_TAR_URL"
    # Validate URL is not a landing page (reject common patterns)
    if [[ "$FASTQ_TAR_URL" =~ (10xgenomics\.com|support\.10xgenomics\.com) ]]; then
        if [[ ! "$FASTQ_TAR_URL" =~ \.tar\.gz$ ]]; then
            die "FASTQ_TAR_URL must be a direct .tar.gz URL, not a landing page: $FASTQ_TAR_URL"
        fi
    fi
    curl -L "$FASTQ_TAR_URL" | tar -xzf - -C "$FASTQ_DIR"
else
    die "Either FASTQ_TAR_PATH or FASTQ_TAR_URL must be provided"
fi

# Find R1 files
R1_FILES=($(find "$FASTQ_DIR" -name "*R1_001.fastq.gz" | sort))
[[ ${#R1_FILES[@]} -gt 0 ]] || die "No R1_001.fastq.gz files found"

# Extract basename from first R1
FIRST_R1=$(basename "${R1_FILES[0]}")
BASENAME_WITH_LANE="${FIRST_R1/_R1_001.fastq.gz/}"

log_info "BASENAME_WITH_LANE: $BASENAME_WITH_LANE"

# Concatenate all R1 files
log_info "Concatenating R1 files..."
cat "${R1_FILES[@]}" > "$FASTQ_DIR/${BASENAME_WITH_LANE}_R1_001.fastq.gz"

# Find and concatenate R2 files
R2_FILES=($(find "$FASTQ_DIR" -name "*R2_001.fastq.gz" | sort))
[[ ${#R2_FILES[@]} -gt 0 ]] || die "No R2_001.fastq.gz files found"

log_info "Concatenating R2 files..."
cat "${R2_FILES[@]}" > "$FASTQ_DIR/${BASENAME_WITH_LANE}_R2_001.fastq.gz"

log_info "FASTQ files ready"

################################################################################
# Step 2-4: Create S3 Buckets and Setup EventBridge
################################################################################

log_info "Step 2: Creating S3 buckets..."

aws s3 mb "s3://$INPUT_FASTQ_BUCKET" --region "$AWS_REGION" 2>/dev/null || true
aws s3 mb "s3://$INPUT_TXT_BUCKET" --region "$AWS_REGION" 2>/dev/null || true
aws s3 mb "s3://$OUTPUT_MAP_BUCKET" --region "$AWS_REGION" 2>/dev/null || true
aws s3 mb "s3://$OUTPUT_QUANT_BUCKET" --region "$AWS_REGION" 2>/dev/null || true

log_info "Step 4: Enabling EventBridge for input-txt bucket..."
aws s3api put-bucket-notification-configuration \
    --bucket "$INPUT_TXT_BUCKET" \
    --notification-configuration '{"EventBridgeConfiguration":{}}' \
    --region "$AWS_REGION" 2>/dev/null || true

log_info "Buckets created and configured"

################################################################################
# Step 3: Upload FASTQs
################################################################################

log_info "Step 3: Uploading FASTQs to S3..."

aws s3 cp "$FASTQ_DIR/${BASENAME_WITH_LANE}_R1_001.fastq.gz" \
    "s3://$INPUT_FASTQ_BUCKET/$DATASET/${BASENAME_WITH_LANE}_R1_001.fastq.gz" \
    --region "$AWS_REGION"

aws s3 cp "$FASTQ_DIR/${BASENAME_WITH_LANE}_R2_001.fastq.gz" \
    "s3://$INPUT_FASTQ_BUCKET/$DATASET/${BASENAME_WITH_LANE}_R2_001.fastq.gz" \
    --region "$AWS_REGION"

log_info "FASTQs uploaded"

################################################################################
# Step 5: Build and Push Lambda Image
################################################################################

log_info "Step 5: Building Lambda docker image..."

BUILD_DIR="$RUN_DIR/lambda_build"
mkdir -p "$BUILD_DIR"

# Copy scrna-pipeline to build context
cp -r /home/ubuntu/scrna-repo/scrna-pipeline/* "$BUILD_DIR/"

# Copy index data to expected location
cp -r /opt/scrna-seed/index_output_transcriptome "$BUILD_DIR/"

# Sanitize Dockerfile: remove lines that COPY AWS credentials
sed -i '/COPY.*aws.*credentials\|COPY.*\.aws\|COPY.*AWS_/d' "$BUILD_DIR/Dockerfile"

log_info "Creating Lambda ECR repository..."

AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_REPO="${ECR_REGISTRY}/${ECR_REPO_NAME}"

aws ecr create-repository \
    --repository-name "$ECR_REPO_NAME" \
    --region "$AWS_REGION" 2>/dev/null || true

log_info "Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"

log_info "Building docker image..."
docker build -t "${ECR_REPO}:latest" "$BUILD_DIR"

log_info "Pushing to ECR..."
docker push "${ECR_REPO}:latest"

log_info "Lambda image ready"

################################################################################
# Step 6: Setup Lambda and EventBridge (using set-up-resources.py)
################################################################################

log_info "Step 6: Setting up Lambda function and EventBridge..."

python3 /home/ubuntu/scrna-repo/set-up-resources.py \
    --region "$AWS_REGION" \
    --account_id "$AWS_ACCOUNT" \
    --dockerfile_dir "$BUILD_DIR" \
    --ecr_repo_name "$ECR_REPO_NAME" \
    --lambda_function_name "$LAMBDA_FUNCTION_NAME" \
    --eventbridge_rule_name "$EVENTBRIDGE_RULE_NAME" \
    --s3_bucket_name "$INPUT_FASTQ_BUCKET" \
    --s3_input_files_bucket_name "$INPUT_TXT_BUCKET" \
    --s3_output_bucket_name "$OUTPUT_MAP_BUCKET" \
    --final_output_bucket_name "$OUTPUT_QUANT_BUCKET"

log_info "Updating Lambda function configuration..."

aws lambda update-function-configuration \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --region "$AWS_REGION" \
    --memory-size "$LAMBDA_MEMORY_MB" \
    --timeout "$LAMBDA_TIMEOUT_SEC" \
    --ephemeral-storage Size="$LAMBDA_EPHEMERAL_MB" >/dev/null 2>&1 || true

log_info "Lambda function ready"

################################################################################
# Step 7: Split and Upload FASTQs to Lambda Input
################################################################################

log_info "Step 7: Splitting FASTQs and uploading txt files..."

bash /home/ubuntu/scrna-repo/split_and_upload.sh \
    "$FASTQ_DIR/${BASENAME_WITH_LANE}_R1_001.fastq.gz" \
    "$FASTQ_DIR/${BASENAME_WITH_LANE}_R2_001.fastq.gz" \
    "$INPUT_FASTQ_BUCKET" \
    "$OUTPUT_MAP_BUCKET" \
    "$INPUT_TXT_BUCKET" \
    "$DATASET"

# List uploaded input files
log_info "Waiting for txt files to be uploaded..."
INPUT_TXT_FILES=()
for i in {1..60}; do
    INPUT_TXT_FILES=($(aws s3 ls "s3://$INPUT_TXT_BUCKET/$DATASET/" --region "$AWS_REGION" | awk '{print $NF}' | grep "_input.txt"))
    if [[ ${#INPUT_TXT_FILES[@]} -gt 0 ]]; then
        break
    fi
    sleep 2
done

if [[ ${#INPUT_TXT_FILES[@]} -eq 0 ]]; then
    die "No input txt files found after upload"
fi

log_info "Found ${#INPUT_TXT_FILES[@]} input txt files"

################################################################################
# Step 8: Wait for Lambda Outputs
################################################################################

log_info "Step 8: Waiting for Lambda outputs..."

for txt_file in "${INPUT_TXT_FILES[@]}"; do
    JOB_BASE="${txt_file/_input.txt/}"
    MARKER_KEY="piscem_output/${JOB_BASE}/output.txt"
    
    log_info "Waiting for output marker: $MARKER_KEY"
    
    # Exponential backoff polling
    POLL_TIMEOUT=1800  # 30 minutes
    POLL_INTERVAL=10
    ELAPSED=0
    
    while [[ $ELAPSED -lt $POLL_TIMEOUT ]]; do
        if aws s3 ls "s3://$OUTPUT_MAP_BUCKET/$MARKER_KEY" --region "$AWS_REGION" >/dev/null 2>&1; then
            log_info "Output marker found for $JOB_BASE"
            break
        fi
        sleep "$POLL_INTERVAL"
        ((ELAPSED += POLL_INTERVAL))
    done
done

log_info "All Lambda outputs ready"

################################################################################
# Step 9: Download and Post-process Outputs
################################################################################

log_info "Step 9: Downloading Lambda outputs..."

DOWNLOAD_DIR="$RUN_DIR/s3_output_map"
mkdir -p "$DOWNLOAD_DIR"

aws s3 sync "s3://$OUTPUT_MAP_BUCKET/piscem_output/" "$DOWNLOAD_DIR/" --region "$AWS_REGION"

log_info "Running combine scripts..."

COMBINED_DIR="$RUN_DIR/combined"
mkdir -p "$COMBINED_DIR"

bash /home/ubuntu/scrna-repo/combine_map_rad.sh "$DOWNLOAD_DIR" "$COMBINED_DIR"
bash /home/ubuntu/scrna-repo/combine_unmapped_bc_count_bin.sh "$DOWNLOAD_DIR" "$COMBINED_DIR"

log_info "Installing alevin-fry and radtk..."

bash /home/ubuntu/scrna-repo/install_scripts/install_alevin_fry.sh
bash /home/ubuntu/scrna-repo/install_scripts/install_radtk.sh

log_info "Running alevin-fry quant..."

ALEVIN_OUTPUT="$RUN_DIR/alevin_output"
mkdir -p "$ALEVIN_OUTPUT"

alevin-fry generate-permit-list -d fw -k -i "$COMBINED_DIR" -o "$ALEVIN_OUTPUT"
alevin-fry collate -t "$THREADS" -i "$ALEVIN_OUTPUT" -r "$COMBINED_DIR"
alevin-fry quant \
    -t "$THREADS" \
    -i "$ALEVIN_OUTPUT" \
    -o "$ALEVIN_OUTPUT" \
    --tg-map /opt/scrna-seed/reference/t2g.tsv \
    --resolution cr-like \
    --use-mtx

log_info "Post-processing complete"

################################################################################
# Step 10: Upload Quant Outputs
################################################################################

log_info "Step 10: Uploading quantification outputs to S3..."

aws s3 sync "$ALEVIN_OUTPUT" "s3://$OUTPUT_QUANT_BUCKET/$RUN_ID/alevin_output/" \
    --region "$AWS_REGION"

log_info "Quant outputs uploaded"

################################################################################
# Step 11: Optional QC Analysis
################################################################################

if [[ $WRITE_H5AD -eq 1 ]]; then
    log_info "Step 11: Running QC analysis..."
    
    QC_DIR="$RUN_DIR/analysis"
    mkdir -p "$QC_DIR/out"
    
    python3 -m venv "$QC_DIR/venv"
    source "$QC_DIR/venv/bin/activate"
    
    pip install -q scanpy matplotlib seaborn
    
    python3 /home/ubuntu/scrna-repo/scripts/qc_scanpy.py \
        "$ALEVIN_OUTPUT" \
        --outdir "$QC_DIR/out" \
        --write-h5ad
    
    deactivate
    
    log_info "QC analysis complete"
else
    log_info "Step 11: Skipping QC (WRITE_H5AD=0)"
fi

################################################################################
# Step 12: Save Run Metadata
################################################################################

log_info "Step 12: Saving run metadata..."

cat > "$RUN_DIR/run.env" <<EOF
RUN_ID=$RUN_ID
DATASET=$DATASET
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT
INPUT_FASTQ_BUCKET=$INPUT_FASTQ_BUCKET
INPUT_TXT_BUCKET=$INPUT_TXT_BUCKET
OUTPUT_MAP_BUCKET=$OUTPUT_MAP_BUCKET
OUTPUT_QUANT_BUCKET=$OUTPUT_QUANT_BUCKET
ECR_REPO=$ECR_REPO_NAME
LAMBDA_FUNCTION=$LAMBDA_FUNCTION_NAME
EVENTBRIDGE_RULE=$EVENTBRIDGE_RULE_NAME
RUN_DIR=$RUN_DIR
BASENAME_WITH_LANE=$BASENAME_WITH_LANE
EOF

log_info "Run metadata saved to $RUN_DIR/run.env"

################################################################################
# Cleanup
################################################################################

log_info "Step 13: Cleanup..."

if [[ $CLEANUP_AWS -eq 1 ]]; then
    log_info "Cleaning up AWS resources..."
    
    # Delete Lambda function
    aws lambda delete-function --function-name "$LAMBDA_FUNCTION_NAME" \
        --region "$AWS_REGION" 2>/dev/null || true
    
    # Delete EventBridge rule
    aws events delete-rule --name "$EVENTBRIDGE_RULE_NAME" \
        --region "$AWS_REGION" 2>/dev/null || true
    
    # Delete ECR repository
    aws ecr delete-repository --repository-name "$ECR_REPO_NAME" \
        --force --region "$AWS_REGION" 2>/dev/null || true
    
    # Empty and delete S3 buckets
    for bucket in "$INPUT_FASTQ_BUCKET" "$INPUT_TXT_BUCKET" "$OUTPUT_MAP_BUCKET" "$OUTPUT_QUANT_BUCKET"; do
        log_info "Deleting bucket: $bucket"
        aws s3 rm "s3://$bucket" --recursive --region "$AWS_REGION" 2>/dev/null || true
        aws s3 rb "s3://$bucket" --region "$AWS_REGION" 2>/dev/null || true
    done
    
    log_info "AWS resources cleaned up"
else
    log_info "Skipping AWS cleanup (CLEANUP_AWS=0)"
fi

################################################################################
# Summary
################################################################################

log_info "======== Pipeline Complete ========"
log_info "Run ID: $RUN_ID"
log_info "Dataset: $DATASET"
log_info "Output directory: $RUN_DIR"
log_info "Quantification output: s3://$OUTPUT_QUANT_BUCKET/$RUN_ID/alevin_output/"

if [[ $WRITE_H5AD -eq 1 ]]; then
    log_info "QC plots: $RUN_DIR/analysis/out/"
    log_info "H5AD file: $RUN_DIR/analysis/out/pbmc_adata.h5ad"
fi

log_info "Run.env: $RUN_DIR/run.env"

exit 0
