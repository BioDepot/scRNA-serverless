#!/usr/bin/env bash
################################################################################
# e2e_serverless_pbmc.sh
#
# End-to-end serverless scRNA pipeline for PBMC datasets.
#
# USAGE:
#   # Driver mode (default): launch EC2 instance, run pipeline on it
#   export SEED_AMI_ID=ami-xxxxx
#   export KEY_NAME=my-keypair
#   export KEY_PEM_PATH=/path/to/key.pem
#   export SUBNET_ID=subnet-xxxxx
#   export SG_ID=sg-xxxxx
#   export EC2_INSTANCE_PROFILE_NAME=my-instance-profile  # REQUIRED
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
#   DRIVER_INSTANCE_ID     Optional: reuse existing EC2 instance (skip launch).
#   EC2_INSTANCE_PROFILE_NAME  Required for reviewer-proof runs (grants AWS permissions to driver EC2)
#   AUTO_SSH_INGRESS       Auto-authorize caller IP in SG for SSH (default: 1)
#
#   LAMBDA_MEMORY_MB       Lambda function memory (default: 10240)
#                          Paper uses 10240MB, but some accounts are capped (e.g., 3008MB).
#                          Set explicitly or rely on automatic fallback.
#   LAMBDA_EPHEMERAL_MB    Lambda /tmp ephemeral storage (default: 10240)
#                          Some accounts limit this. Script will fallback if needed.
#   LAMBDA_TIMEOUT_SEC     Lambda timeout in seconds (default: 900)
#   THREADS                Number of CPU threads (default: nproc)
#   CLEANUP_AWS            Clean up AWS resources after pipeline (default: 1)
#   TERMINATE_DRIVER_ON_EXIT  Terminate EC2 instance on exit (default: 1)
#   RUN_QC                 Run QC analysis on outputs (default: 1)
#
#   FASTQ_TAR_PATH         Optional: path to local FASTQ tar file on instance.
#   FASTQ_TAR_URL          Optional: direct URL to FASTQ tar. Auto-set by DATASET if empty.
#   WRITE_H5AD             Save h5ad output from QC (default: 0). Only matters if RUN_QC=1.
#   RUN_ID                 Run identifier (auto-generated if empty). Set to reuse prior resources.
#
# NOTE ON S3 BUCKET NAMES:
#   S3 bucket names must be lowercase with no underscores. Auto-generated bucket names use:
#     scrna-{input|output}-{type}-{ACCOUNT_ID}-{RUN_ID_CLEAN}
#   where RUN_ID_CLEAN removes underscores and uses hyphens in timestamps.
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
AWS_REGION="${AWS_REGION:-us-east-2}"
SEED_AMI_ID="${SEED_AMI_ID:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-m6id.16xlarge}"
ROOT_VOL_GB="${ROOT_VOL_GB:-200}"
KEY_NAME="${KEY_NAME:-}"
KEY_PEM_PATH="${KEY_PEM_PATH:-}"
SUBNET_ID="${SUBNET_ID:-}"
SG_ID="${SG_ID:-}"
DRIVER_INSTANCE_ID="${DRIVER_INSTANCE_ID:-}"
EC2_INSTANCE_PROFILE_NAME="${EC2_INSTANCE_PROFILE_NAME:-}"
AUTO_SSH_INGRESS="${AUTO_SSH_INGRESS:-1}"

# Lambda Configuration
LAMBDA_MEMORY_MB="${LAMBDA_MEMORY_MB:-10240}"
LAMBDA_EPHEMERAL_MB="${LAMBDA_EPHEMERAL_MB:-10240}"
LAMBDA_TIMEOUT_SEC="${LAMBDA_TIMEOUT_SEC:-900}"

# Execution Configuration
THREADS="${THREADS:-$(nproc)}"
CLEANUP_AWS="${CLEANUP_AWS:-1}"
TERMINATE_DRIVER_ON_EXIT="${TERMINATE_DRIVER_ON_EXIT:-1}"
RUN_QC="${RUN_QC:-1}"

# FASTQ Configuration
FASTQ_TAR_PATH="${FASTQ_TAR_PATH:-}"
FASTQ_TAR_URL="${FASTQ_TAR_URL:-}"
WRITE_H5AD="${WRITE_H5AD:-0}"
RUN_ID="${RUN_ID:-}"

# Derived values (will be set later)
RUN_MODE=0
DATASET=""
DRIVER_INSTANCE_ID="${DRIVER_INSTANCE_ID:-}"
DRIVER_INSTANCE_IP=""
ECR_REPO_NAME=""
LAMBDA_FUNCTION_NAME=""
LAMBDA_EXECUTION_ROLE_NAME=""
DOCKER_IMAGE_NAME=""
INPUT_FASTQ_BUCKET=""
INPUT_TXT_BUCKET=""
OUTPUT_MAP_BUCKET=""
OUTPUT_QUANT_BUCKET=""

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

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

get_caller_public_ip() {
    # Detect caller's public IP for security group ingress
    curl -s -m 5 http://checkip.amazonaws.com | tr -d ' \n' 2>/dev/null || echo ""
}

manage_sg_ingress() {
    local action=$1  # "authorize" or "revoke"
    local caller_ip=$2
    
    if [[ -z "$caller_ip" ]] || [[ "$caller_ip" == "127.0.0.1" ]]; then
        log_info "Skipping SG ingress for local caller (cannot auto-auth localhost)"
        return 0
    fi
    
    local cidr="${caller_ip}/32"
    
    log_info "${action^} SSH (tcp/22) ingress for ${cidr}..."
    
    if [[ "$action" == "authorize" ]]; then
        # Authorize: ignore if already exists
        aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 22 \
            --cidr "$cidr" 2>/dev/null && log_info "Authorized SG ingress" || log_info "SG ingress already exists or error (continuing)"
    elif [[ "$action" == "revoke" ]]; then
        # Revoke: ignore if doesn't exist
        aws ec2 revoke-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 22 \
            --cidr "$cidr" 2>/dev/null && log_info "Revoked SG ingress" || log_info "SG ingress doesn't exist or error (continuing)"
    fi
}

################################################################################
# Initialize Resource Names (called after AWS_ACCOUNT_ID is known)
################################################################################

init_resource_names() {
    local timestamp=$(date +%Y-%m-%d-%H-%M-%S)
    local random_suffix=$(head -c 4 /dev/urandom | xxd -p)
    local run_id_clean="${RUN_ID//_/-}"  # Replace underscores with hyphens for S3 compatibility
    
    # ECR and Lambda names
    ECR_REPO_NAME="scrna-serverless-${timestamp}-${random_suffix}"
    LAMBDA_FUNCTION_NAME="scrna-map-${timestamp}-${random_suffix}"
    LAMBDA_EXECUTION_ROLE_NAME="scrna-lambda-role-${timestamp}-${random_suffix}"
    DOCKER_IMAGE_NAME="scrna-serverless:${timestamp}"
    
    # S3 bucket names (must be lowercase, no underscores, globally unique, include region)
    INPUT_FASTQ_BUCKET="scrna-input-fastq-${AWS_ACCOUNT_ID}-${AWS_REGION}-${run_id_clean}"
    INPUT_TXT_BUCKET="scrna-input-txt-${AWS_ACCOUNT_ID}-${AWS_REGION}-${run_id_clean}"
    OUTPUT_MAP_BUCKET="scrna-output-map-${AWS_ACCOUNT_ID}-${AWS_REGION}-${run_id_clean}"
    OUTPUT_QUANT_BUCKET="scrna-output-quant-${AWS_ACCOUNT_ID}-${AWS_REGION}-${run_id_clean}"
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
# Generate Run ID
################################################################################

if [[ -z "$RUN_ID" ]]; then
    RUN_ID="pbmc-$(date +%s)-$(head -c 4 /dev/urandom | xxd -p)"
fi

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
    [[ -n "$EC2_INSTANCE_PROFILE_NAME" ]] || die "EC2_INSTANCE_PROFILE_NAME is required for reviewer-proof execution (no credentials baked into AMI)."
    
    # Resume logic: check for existing instance
    if [[ -z "$DRIVER_INSTANCE_ID" ]]; then
        log_info "Checking for existing instance with tag scrna-e2e-$RUN_ID..."
        DRIVER_INSTANCE_ID=$(aws ec2 describe-instances \
            --region "$AWS_REGION" \
            --filters "Name=tag:Name,Values=scrna-e2e-$RUN_ID" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
            --query "Reservations[0].Instances[0].InstanceId" \
            --output text 2>/dev/null || echo "")
    fi
    
    if [[ -n "$DRIVER_INSTANCE_ID" && "$DRIVER_INSTANCE_ID" != "None" ]]; then
        log_info "Found existing instance: $DRIVER_INSTANCE_ID"
        
        # Get instance state
        INSTANCE_STATE=$(aws ec2 describe-instances \
            --region "$AWS_REGION" \
            --instance-ids "$DRIVER_INSTANCE_ID" \
            --query "Reservations[0].Instances[0].State.Name" \
            --output text 2>/dev/null || echo "")
        
        log_info "Instance state: $INSTANCE_STATE"
        
        # If stopped, start it
        if [[ "$INSTANCE_STATE" == "stopped" ]]; then
            log_info "Starting stopped instance..."
            aws ec2 start-instances --region "$AWS_REGION" --instance-ids "$DRIVER_INSTANCE_ID" >/dev/null
            log_info "Waiting for instance to reach running state..."
            aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$DRIVER_INSTANCE_ID"
        elif [[ "$INSTANCE_STATE" != "running" && "$INSTANCE_STATE" != "pending" ]]; then
            die "Instance is in state: $INSTANCE_STATE. Cannot resume."
        fi
    else
        log_info "Launching new EC2 instance from AMI $SEED_AMI_ID..."
        
        # Build IAM instance profile args if provided
        IAM_PROFILE_ARGS=()
        if [[ -n "${EC2_INSTANCE_PROFILE_NAME}" ]]; then
            IAM_PROFILE_ARGS=(--iam-instance-profile "Name=${EC2_INSTANCE_PROFILE_NAME}")
        fi
        
        DRIVER_INSTANCE_ID=$(aws ec2 run-instances \
        --region "$AWS_REGION" \
        --image-id "$SEED_AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SG_ID" \
        "${IAM_PROFILE_ARGS[@]}" \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_VOL_GB,VolumeType=gp3}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=scrna-e2e-$RUN_ID}]" \
        --query "Instances[0].InstanceId" \
        --output text)
    
        log_info "Instance launched: $DRIVER_INSTANCE_ID"
        
        log_info "Waiting for instance to reach running state..."
        aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$DRIVER_INSTANCE_ID"
    fi
    
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
    
    # Auto-authorize caller IP for SSH
    if [[ $AUTO_SSH_INGRESS -eq 1 ]]; then
        CALLER_IP=$(get_caller_public_ip)
        if [[ -n "$CALLER_IP" ]]; then
            manage_sg_ingress authorize "$CALLER_IP"
            CALLER_IP_TO_REVOKE="$CALLER_IP"
        else
            log_info "Could not detect caller IP; skipping SG ingress"
        fi
    fi
    
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
    # Note: AWS_ACCOUNT_ID is NOT exported; it will be auto-detected in run mode
    ssh -i "$KEY_PEM_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "ubuntu@$DRIVER_INSTANCE_IP" <<SSHEOF
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
    
    # Revoke caller IP from SG if it was authorized
    if [[ -n "${CALLER_IP_TO_REVOKE:-}" ]]; then
        manage_sg_ingress revoke "$CALLER_IP_TO_REVOKE"
    fi
    
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

# Auto-detect AWS account ID if not set
if [[ -z "$AWS_ACCOUNT_ID" ]]; then
    log_info "Auto-detecting AWS account ID..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    log_info "AWS account ID: $AWS_ACCOUNT_ID"
fi

# Initialize resource names now that AWS_ACCOUNT_ID is known
init_resource_names

# Setup NVMe storage if available
log_info "Setting up NVMe storage..."

NVMe_DEVICE=$(lsblk -d -n -l | grep nvme | awk '{print $1}' | head -1)
if [[ -n "$NVMe_DEVICE" ]]; then
    NVMe_PATH="/dev/$NVMe_DEVICE"
    MOUNT_POINT="/mnt/nvme"
    
    if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "Found NVMe device: $NVMe_PATH"
        if [[ -b "$NVMe_PATH" ]]; then
            # Check if filesystem exists; if not, create one
            if ! sudo blkid "$NVMe_PATH" >/dev/null 2>&1; then
                log_info "Creating ext4 filesystem on $NVMe_PATH..."
                sudo mkfs.ext4 -F "$NVMe_PATH"
            fi
            
            log_info "Mounting $NVMe_PATH to $MOUNT_POINT..."
            sudo mkdir -p "$MOUNT_POINT"
            sudo mount "$NVMe_PATH" "$MOUNT_POINT"
            sudo chown -R ubuntu:ubuntu "$MOUNT_POINT"
        fi
    else
        log_info "$MOUNT_POINT already mounted"
    fi
else
    log_info "No NVMe device found; using default storage"
    mkdir -p /mnt/nvme
fi

# Create run directory
RUN_DIR="/mnt/nvme/runs/$RUN_ID"
mkdir -p "$RUN_DIR"

log_info "Run directory: $RUN_DIR"

################################################################################
# Step 0: Bootstrap Tools
################################################################################

log_info "Step 0: Bootstrapping tools..."

# Check for required tools and install missing ones
REQUIRED_TOOLS=(python3 pip3 aws docker jq curl tar gzip git)
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! need_cmd "$tool"; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    log_info "Installing missing tools: ${MISSING_TOOLS[*]}"
    sudo apt-get update
    
    INSTALL_PKGS=()
    for tool in "${MISSING_TOOLS[@]}"; do
        case "$tool" in
            python3) INSTALL_PKGS+=(python3 python3-venv python3-pip) ;;
            pip3) INSTALL_PKGS+=(python3-pip) ;;
            aws) INSTALL_PKGS+=(awscli) ;;
            docker) INSTALL_PKGS+=(docker.io) ;;
            *) INSTALL_PKGS+=("$tool") ;;
        esac
    done
    
    sudo apt-get install -y "${INSTALL_PKGS[@]}"
    
    # Add user to docker group if docker was installed
    if [[ " ${MISSING_TOOLS[*]} " =~ " docker " ]]; then
        sudo usermod -aG docker ubuntu
    fi
fi

# Detect if docker needs sudo
DOCKER="docker"
if ! docker ps >/dev/null 2>&1; then
    DOCKER="sudo docker"
fi

log_info "Tools ready"

################################################################################
# Step 1: Prepare FASTQs
################################################################################

log_info "Step 1: Preparing FASTQs..."

FASTQ_DIR="$RUN_DIR/fastq"
mkdir -p "$FASTQ_DIR"

# Auto-set FASTQ_TAR_URL by dataset if not provided
if [[ -z "$FASTQ_TAR_PATH" && -z "$FASTQ_TAR_URL" ]]; then
    case "$DATASET" in
        pbmc1k)
            FASTQ_TAR_URL="https://s3-us-west-2.amazonaws.com/10x.files/samples/cell-exp/3.0.0/pbmc_1k_v3/pbmc_1k_v3_fastqs.tar"
            log_info "Auto-set FASTQ_TAR_URL for pbmc1k"
            ;;
        pbmc10k)
            FASTQ_TAR_URL="https://s3-us-west-2.amazonaws.com/10x.files/samples/cell-exp/3.0.0/pbmc_10k_v3/pbmc_10k_v3_fastqs.tar"
            log_info "Auto-set FASTQ_TAR_URL for pbmc10k"
            ;;
        *)
            die "Unknown dataset: $DATASET"
            ;;
    esac
fi

# Obtain FASTQ tar
if [[ -n "$FASTQ_TAR_PATH" ]]; then
    log_info "Extracting FASTQ tar from: $FASTQ_TAR_PATH"
    # Detect format and extract accordingly
    if [[ "$FASTQ_TAR_PATH" =~ \.(tar\.gz|tgz)$ ]]; then
        tar -xzf "$FASTQ_TAR_PATH" -C "$FASTQ_DIR"
    else
        tar -xf "$FASTQ_TAR_PATH" -C "$FASTQ_DIR"
    fi
elif [[ -n "$FASTQ_TAR_URL" ]]; then
    log_info "Downloading FASTQ tar from: $FASTQ_TAR_URL"
    # Validate URL is not a landing page (reject common patterns)
    if [[ "$FASTQ_TAR_URL" =~ (10xgenomics\.com|support\.10xgenomics\.com) ]]; then
        if [[ ! "$FASTQ_TAR_URL" =~ \.(tar|tar\.gz|tgz)$ ]]; then
            die "FASTQ_TAR_URL must be a direct tar/tar.gz URL, not a landing page: $FASTQ_TAR_URL"
        fi
    fi
    # Stream and extract: detect format and pipe accordingly
    if [[ "$FASTQ_TAR_URL" =~ \.(tar\.gz|tgz)$ ]]; then
        curl -L "$FASTQ_TAR_URL" | tar -xzf - -C "$FASTQ_DIR"
    else
        curl -L "$FASTQ_TAR_URL" | tar -xf - -C "$FASTQ_DIR"
    fi
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

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_REPO="${ECR_REGISTRY}/${ECR_REPO_NAME}"

aws ecr create-repository \
    --repository-name "$ECR_REPO_NAME" \
    --region "$AWS_REGION" 2>/dev/null || true

log_info "Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
    ${DOCKER} login --username AWS --password-stdin "$ECR_REGISTRY"

log_info "Building docker image..."
${DOCKER} build -t "${ECR_REPO}:latest" "$BUILD_DIR"

log_info "Pushing to ECR..."
${DOCKER} push "${ECR_REPO}:latest"

log_info "Lambda image ready"

################################################################################
# Patcher Function: Patch set-up-resources.py Lambda sizes
################################################################################

patch_set_up_resources_lambda_sizes() {
    local mem="$1" eph="$2" path="/home/ubuntu/scrna-repo/set-up-resources.py"
    python3 - "$path" "$mem" "$eph" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
mem = sys.argv[2]
eph = sys.argv[3]
txt = p.read_text()
txt = re.sub(r"MemorySize\s*=\s*\d+", f"MemorySize={mem}", txt)
txt = re.sub(r"EphemeralStorage\s*=\s*\{'Size':\s*\d+\}", f"EphemeralStorage={{'Size': {eph}}}", txt)
p.write_text(txt)
PY
}

################################################################################
# Step 6: Setup Lambda and EventBridge (using set-up-resources.py)
################################################################################

log_info "Step 6: Setting up Lambda function and EventBridge..."

# Try memory/ephemeral combinations during Lambda creation
MEM_CANDIDATES=(10240 3008 2048 1536 1024 512)
EPH_CANDIDATES=(10240 512)

CREATE_SUCCESS=0
for mem in "${MEM_CANDIDATES[@]}"; do
    for eph in "${EPH_CANDIDATES[@]}"; do
        log_info "Attempting Lambda creation: memory=${mem}MB, ephemeral=${eph}MB"
        
        # Patch set-up-resources.py with current candidate sizes
        patch_set_up_resources_lambda_sizes "$mem" "$eph"
        
        # Run set-up-resources.py (use sudo -E if docker needs sudo)
        PYTHON_CMD="python3"
        if [[ "$DOCKER" == "sudo docker" ]]; then
            PYTHON_CMD="sudo -E python3"
        fi
        
        if $PYTHON_CMD /home/ubuntu/scrna-repo/set-up-resources.py \
            --aws_region "$AWS_REGION" \
            --aws_account_id "$AWS_ACCOUNT_ID" \
            --dockerfile_dir "$BUILD_DIR" \
            --docker_image_name "$DOCKER_IMAGE_NAME" \
            --lambda_function_name "$LAMBDA_FUNCTION_NAME" \
            --lambda_execution_role_name "$LAMBDA_EXECUTION_ROLE_NAME" \
            --s3_bucket_name "$INPUT_FASTQ_BUCKET" \
            --s3_input_files_bucket_name "$INPUT_TXT_BUCKET" \
            --s3_output_bucket_name "$OUTPUT_MAP_BUCKET" \
            --final_output_bucket_name "$OUTPUT_QUANT_BUCKET" 2>&1; then
            
            LAMBDA_MEMORY_MB="$mem"
            LAMBDA_EPHEMERAL_MB="$eph"
            log_info "Lambda created successfully: memory=${LAMBDA_MEMORY_MB}MB, ephemeral=${LAMBDA_EPHEMERAL_MB}MB"
            CREATE_SUCCESS=1
            break 2
        else
            log_info "Failed with memory=${mem}MB, ephemeral=${eph}MB (trying next combination...)"
        fi
    done
done

if [[ $CREATE_SUCCESS -eq 0 ]]; then
    die "Unable to create Lambda with any memory/ephemeral combination. Check account limits."
fi

log_info "Updating Lambda function configuration..."

# Try memory/ephemeral combinations until one succeeds
MEM_CANDIDATES=("$LAMBDA_MEMORY_MB" 3008 2048 1536 1024 512)
EPH_CANDIDATES=("$LAMBDA_EPHEMERAL_MB" 10240 512)

CONFIG_SUCCESS=0
for mem in "${MEM_CANDIDATES[@]}"; do
    for eph in "${EPH_CANDIDATES[@]}"; do
        log_info "Attempting Lambda config: memory=${mem}MB, ephemeral=${eph}MB, timeout=${LAMBDA_TIMEOUT_SEC}s"
        
        if aws lambda update-function-configuration \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --region "$AWS_REGION" \
            --memory-size "$mem" \
            --timeout "$LAMBDA_TIMEOUT_SEC" \
            --ephemeral-storage Size="$eph" 2>&1; then
            
            LAMBDA_MEMORY_MB="$mem"
            LAMBDA_EPHEMERAL_MB="$eph"
            log_info "Lambda configured: memory=${LAMBDA_MEMORY_MB}MB, ephemeral=${LAMBDA_EPHEMERAL_MB}MB, timeout=${LAMBDA_TIMEOUT_SEC}s"
            CONFIG_SUCCESS=1
            break 2
        else
            log_info "Failed with memory=${mem}MB, ephemeral=${eph}MB (trying next combination...)"
        fi
    done
done

if [[ $CONFIG_SUCCESS -eq 0 ]]; then
    die "Unable to configure Lambda. Set LAMBDA_MEMORY_MB/LAMBDA_EPHEMERAL_MB to values allowed in your account. Example: LAMBDA_MEMORY_MB=3008 LAMBDA_EPHEMERAL_MB=512"
fi

# Wait for Lambda function update to complete
log_info "Waiting for Lambda function update to complete..."
aws lambda wait function-updated --function-name "$LAMBDA_FUNCTION_NAME" --region "$AWS_REGION"

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
    # Use basename to strip any S3 prefix from txt_file
    job_folder="$(basename "${txt_file%_input.txt}")"
    MARKER_KEY="piscem_output/${job_folder}/output.txt"
    
    log_info "Waiting for output marker: $MARKER_KEY"
    
    # Exponential backoff polling
    POLL_TIMEOUT=1800  # 30 minutes
    POLL_INTERVAL=10
    ELAPSED=0
    
    while [[ $ELAPSED -lt $POLL_TIMEOUT ]]; do
        if aws s3 ls "s3://$OUTPUT_MAP_BUCKET/$MARKER_KEY" --region "$AWS_REGION" >/dev/null 2>&1; then
            log_info "Output marker found for $job_folder"
            break
        fi
        sleep "$POLL_INTERVAL"
        ((ELAPSED += POLL_INTERVAL))
    done
    
    # Verify marker exists after timeout
    if ! aws s3 ls "s3://$OUTPUT_MAP_BUCKET/$MARKER_KEY" --region "$AWS_REGION" >/dev/null 2>&1; then
        die "Timed out waiting for marker: s3://$OUTPUT_MAP_BUCKET/$MARKER_KEY"
    fi
done

log_info "All Lambda outputs ready"

################################################################################
# Step 9: Download and Post-process Outputs
################################################################################

log_info "Step 9: Downloading Lambda outputs..."

DOWNLOAD_DIR="$RUN_DIR/s3_output_map"
mkdir -p "$DOWNLOAD_DIR"

aws s3 sync "s3://$OUTPUT_MAP_BUCKET/piscem_output/" "$DOWNLOAD_DIR/" --region "$AWS_REGION"

log_info "Installing alevin-fry and radtk..."

bash /home/ubuntu/scrna-repo/install_scripts/install_alevin_fry.sh
bash /home/ubuntu/scrna-repo/install_scripts/install_radtk.sh

log_info "Running combine scripts..."

COMBINED_DIR="$RUN_DIR/combined"
mkdir -p "$COMBINED_DIR"

bash /home/ubuntu/scrna-repo/combine_map_rad.sh "$DOWNLOAD_DIR" "$COMBINED_DIR"
bash /home/ubuntu/scrna-repo/combine_unmapped_bc_count_bin.sh "$DOWNLOAD_DIR" "$COMBINED_DIR"

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

if [[ $RUN_QC -eq 1 ]]; then
    log_info "Step 11: Running QC analysis..."
    
    QC_DIR="$RUN_DIR/analysis"
    mkdir -p "$QC_DIR/out"
    
    python3 -m venv "$QC_DIR/venv"
    source "$QC_DIR/venv/bin/activate"
    
    pip install -q scanpy matplotlib seaborn leidenalg igraph
    
    QC_ARGS=("$ALEVIN_OUTPUT" "--outdir" "$QC_DIR/out")
    if [[ $WRITE_H5AD -eq 1 ]]; then
        QC_ARGS+=("--write-h5ad")
    fi
    
    python3 /home/ubuntu/scrna-repo/scripts/qc_scanpy.py "${QC_ARGS[@]}"
    
    deactivate
    
    log_info "QC analysis complete"
else
    log_info "Step 11: Skipping QC (RUN_QC=0)"
fi

################################################################################
# Step 12: Save Run Metadata
################################################################################

log_info "Step 12: Saving run metadata..."

cat > "$RUN_DIR/run.env" <<EOF
RUN_ID=$RUN_ID
DATASET=$DATASET
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID
DRIVER_INSTANCE_ID=${DRIVER_INSTANCE_ID:-}
INPUT_FASTQ_BUCKET=$INPUT_FASTQ_BUCKET
INPUT_TXT_BUCKET=$INPUT_TXT_BUCKET
OUTPUT_MAP_BUCKET=$OUTPUT_MAP_BUCKET
OUTPUT_QUANT_BUCKET=$OUTPUT_QUANT_BUCKET
ECR_REPO=$ECR_REPO_NAME
LAMBDA_FUNCTION=$LAMBDA_FUNCTION_NAME
LAMBDA_EXECUTION_ROLE=$LAMBDA_EXECUTION_ROLE_NAME
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
    
    # Delete IAM execution role (detach policies first)
    aws iam list-role-policies --role-name "$LAMBDA_EXECUTION_ROLE_NAME" \
        --query 'PolicyNames[]' --output text | \
        xargs -I {} aws iam delete-role-policy --role-name "$LAMBDA_EXECUTION_ROLE_NAME" --policy-name {} 2>/dev/null || true
    
    aws iam delete-role --role-name "$LAMBDA_EXECUTION_ROLE_NAME" \
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

if [[ $RUN_QC -eq 1 ]]; then
    log_info "QC plots: $RUN_DIR/analysis/out/"
    if [[ $WRITE_H5AD -eq 1 ]]; then
        log_info "H5AD file: $RUN_DIR/analysis/out/pbmc_adata.h5ad"
    fi
fi

log_info "Run.env: $RUN_DIR/run.env"

exit 0
