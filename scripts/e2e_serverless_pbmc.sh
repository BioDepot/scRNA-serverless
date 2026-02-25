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
#   KEY_NAME               Required in driver mode when USE_SSM=0. Existing EC2 keypair name.
#   KEY_PEM_PATH           Required in driver mode when USE_SSM=0. Path to .pem file for SSH.
#   SUBNET_ID              Required in driver mode. VPC subnet ID.
#   SG_ID                  Required in driver mode. Security group ID.
#   DRIVER_INSTANCE_ID     Optional: reuse existing EC2 instance (skip launch).
#   EC2_INSTANCE_PROFILE_NAME  Required for reviewer-proof runs (grants AWS permissions to driver EC2)
#   AUTO_SSH_INGRESS       Auto-authorize caller IP in SG for SSH (default: 1)
#   USE_SSM                SSM connection mode: auto|1|0 (default: auto)
#                          auto = try SSH ~60s, fallback to SSM if blocked
#                          1    = SSM only (no SSH required, KEY_NAME/KEY_PEM_PATH optional)
#                          0    = SSH only (original behavior)
#
#   LAMBDA_MEMORY_MB       Lambda function memory (default: 10240, fallback: 3008)
#                          Attempts 10240MB first; falls back to 3008MB if account quota exceeded.
#   LAMBDA_EPHEMERAL_MB    Lambda /tmp ephemeral storage (default: 10240)
#   LAMBDA_TIMEOUT_SEC     Lambda timeout in seconds (default: 900)
#   THREADS                Number of CPU threads (default: nproc)
#   CLEANUP_AWS            Clean up AWS resources after pipeline (default: 1)
#   TERMINATE_DRIVER_ON_EXIT  Terminate EC2 instance on exit (default: 1)
#   DOWNLOAD_TO_LOCAL      Download results from EC2 to local machine (default: 1). Alias for DOWNLOAD_RESULTS.
#   RUN_QC                 Run QC analysis on outputs (default: 1). ONLY step requiring python.
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

# Cleanup temp files on exit (safe under set -u)
# Cleanup function — called automatically on EXIT/INT/TERM.
# Ensures EC2 instances and security groups created by this script are not
# left running if the script fails at any point.
cleanup_on_exit() {
    local exit_code=$?
    # Clean up temp FASTQ files
    [[ -n "${FASTQ_DIR:-}" ]] && rm -f "${FASTQ_DIR}"/*.tmp 2>/dev/null || true

    # Only run driver-mode cleanup when we are in driver mode and actually
    # created resources (DRIVER_INSTANCE_ID is set after launch).
    if [[ "${RUN_MODE:-0}" -eq 0 && -n "${DRIVER_INSTANCE_ID:-}" && "${DRIVER_INSTANCE_ID:-}" != "None" ]]; then
        if [[ $exit_code -ne 0 ]]; then
            echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') Script failed (exit $exit_code). Running automatic cleanup..." >&2
        fi

        # Revoke caller IP from SG if it was authorized
        if [[ -n "${CALLER_IP_TO_REVOKE:-}" ]]; then
            echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Revoking SG ingress for ${CALLER_IP_TO_REVOKE}..."
            aws ec2 revoke-security-group-ingress \
                --region "${AWS_REGION:-us-east-2}" \
                --group-id "${SG_ID:-}" \
                --protocol tcp --port 22 \
                --cidr "${CALLER_IP_TO_REVOKE}/32" 2>/dev/null || true
        fi

        if [[ "${TERMINATE_DRIVER_ON_EXIT:-1}" -eq 1 ]]; then
            echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Terminating driver instance ${DRIVER_INSTANCE_ID}..."
            aws ec2 terminate-instances --region "${AWS_REGION:-us-east-2}" \
                --instance-ids "$DRIVER_INSTANCE_ID" >/dev/null 2>&1 || true

            echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Waiting for instance to terminate..."
            aws ec2 wait instance-terminated --region "${AWS_REGION:-us-east-2}" \
                --instance-ids "$DRIVER_INSTANCE_ID" 2>/dev/null || true

            # Delete auto-created SG after instance is gone
            if [[ -n "${CREATED_SG_ID:-}" ]]; then
                echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Deleting temporary security group ${CREATED_SG_ID}..."
                aws ec2 delete-security-group --region "${AWS_REGION:-us-east-2}" \
                    --group-id "$CREATED_SG_ID" 2>/dev/null || true
            fi

            # Clean up SSM transfer bucket if used
            if [[ -n "${SSM_TRANSFER_BUCKET:-}" ]]; then
                echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Cleaning up SSM transfer bucket ${SSM_TRANSFER_BUCKET}..."
                aws s3 rm "s3://${SSM_TRANSFER_BUCKET}" --recursive --region "${AWS_REGION:-us-east-2}" 2>/dev/null || true
                aws s3 rb "s3://${SSM_TRANSFER_BUCKET}" --region "${AWS_REGION:-us-east-2}" 2>/dev/null || true
            fi
        fi
    fi
}
trap cleanup_on_exit EXIT INT TERM

################################################################################
# User Configuration (Edit Once)
# Set these defaults once, then override via env vars if needed
################################################################################

DEFAULT_AWS_REGION="us-east-2"
DEFAULT_KEY_NAME=""
DEFAULT_KEY_PEM_PATH=""
DEFAULT_EC2_INSTANCE_PROFILE_NAME=""
DEFAULT_SEED_AMI_ID="ami-0b80485dc95b72c33"  # Author's seed AMI (hardcoded for reproducibility)
SEED_AMI_NAME_PREFIX="scrna-seed-"  # Used to auto-detect seed AMI by name (for reviewers)
SEED_AMI_OWNER="${SEED_AMI_OWNER:-self}"  # For reviewers: set to publisher account ID
AUTO_PICK_SUBNET=1                 # Auto-pick subnet from default VPC
AUTO_CREATE_SG=1                   # Auto-create temporary security group
AUTO_DETECT_SEED_AMI=0             # For authors: disabled (use hardcoded AMI). For reviewers: set to 1

################################################################################
# Default Configuration
################################################################################

# AWS Configuration
AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
SEED_AMI_ID="${SEED_AMI_ID:-$DEFAULT_SEED_AMI_ID}"
INSTANCE_TYPE="${INSTANCE_TYPE:-m6id.16xlarge}"
ROOT_VOL_GB="${ROOT_VOL_GB:-200}"
KEY_NAME="${KEY_NAME:-$DEFAULT_KEY_NAME}"
KEY_PEM_PATH="${KEY_PEM_PATH:-$DEFAULT_KEY_PEM_PATH}"
SUBNET_ID="${SUBNET_ID:-}"
SG_ID="${SG_ID:-}"
DRIVER_INSTANCE_ID="${DRIVER_INSTANCE_ID:-}"
EC2_INSTANCE_PROFILE_NAME="${EC2_INSTANCE_PROFILE_NAME:-$DEFAULT_EC2_INSTANCE_PROFILE_NAME}"
AUTO_SSH_INGRESS="${AUTO_SSH_INGRESS:-1}"
SSH_USER="${SSH_USER:-ubuntu}"    # SSH username (auto-detected if default fails)
CREATED_SG_ID=""                  # Track SG created by this script for cleanup
USE_SSM="${USE_SSM:-auto}"        # auto|1|0 — SSM fallback for SSH-blocked networks

# Lambda Configuration (try 10240MB memory; fallback to 3008MB if quota exceeded)
LAMBDA_MEMORY_MB="${LAMBDA_MEMORY_MB:-10240}"
LAMBDA_EPHEMERAL_MB="${LAMBDA_EPHEMERAL_MB:-10240}"
LAMBDA_TIMEOUT_SEC="${LAMBDA_TIMEOUT_SEC:-900}"

# Execution Configuration
THREADS="${THREADS:-$(nproc)}"
CLEANUP_AWS="${CLEANUP_AWS:-1}"
TERMINATE_DRIVER_ON_EXIT="${TERMINATE_DRIVER_ON_EXIT:-1}"
RUN_QC="${RUN_QC:-1}"
DOWNLOAD_RESULTS="${DOWNLOAD_RESULTS:-${DOWNLOAD_TO_LOCAL:-1}}"  # DOWNLOAD_TO_LOCAL is accepted alias
LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR:-./serverless_runs}"

# FASTQ Configuration
FASTQ_TAR_PATH="${FASTQ_TAR_PATH:-}"
FASTQ_TAR_URL="${FASTQ_TAR_URL:-}"
WRITE_H5AD="${WRITE_H5AD:-0}"
RUN_ID="${RUN_ID:-}"
PROCESS_FASTQ_TIMEOUT_SEC="${PROCESS_FASTQ_TIMEOUT_SEC:-7200}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-30}"

# Derived values (will be set later)
RUN_MODE=0
DRY_RUN_MODE=0
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
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

die() {
    log_error "$@"
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

rand_hex() {
    # Return N lowercase hex chars (default 8). No python dependency.
    local n="${1:-8}"
    local bytes=$(( (n + 1) / 2 ))
    local hex=""
    if command -v openssl >/dev/null 2>&1; then
        hex=$(openssl rand -hex "$bytes" 2>/dev/null)
    elif [[ -r /dev/urandom ]]; then
        hex=$(od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n')
    else
        hex=$(date +%s%N | sha1sum | tr -d ' \t-')
    fi
    printf '%s' "${hex:0:$n}"
}

get_caller_public_ip() {
    # Detect caller's public IP for security group ingress
    curl -s -m 5 http://checkip.amazonaws.com | tr -d ' \n' 2>/dev/null || echo ""
}

is_windows_host() {
    command -v powershell.exe >/dev/null 2>&1
}

is_wsl() {
    [[ -n "${WSL_INTEROP:-}" ]] && return 0
    [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null && return 0
    return 1
}

normalize_path_for_bash() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$p"
        return 0
    fi
    # fallback: D:\path\file.pem -> /d/path/file.pem (Git Bash)
    if [[ "$p" =~ ^([A-Za-z]):\\ ]]; then
        local drive="${p:0:1}"
        local rest="${p:2}"
        echo "/${drive,,}${rest//\\/\/}"
    else
        echo "$p"
    fi
}

win_path_from_bash() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$p"
    else
        echo "$p"
    fi
}

maybe_fix_pem_perms_windows() {
    local pem="$1"

    # Only meaningful on Windows Git Bash
    command -v icacls.exe >/dev/null 2>&1 || return 0

    # Convert bash path -> Windows path
    local win_pem="$pem"
    if command -v cygpath >/dev/null 2>&1; then
        win_pem="$(cygpath -w "$pem")"
    fi

    # Username (usually present in Git Bash as $USERNAME)
    local user="${USERNAME:-${USER:-}}"

    # Tighten ACLs (ignore failures)
    icacls.exe "$win_pem" /inheritance:r >/dev/null 2>&1 || true
    [[ -n "$user" ]] && icacls.exe "$win_pem" /grant:r "${user}:R" >/dev/null 2>&1 || true
    icacls.exe "$win_pem" /grant:r "Administrators:R" >/dev/null 2>&1 || true
    icacls.exe "$win_pem" /grant:r "SYSTEM:R" >/dev/null 2>&1 || true
    icacls.exe "$win_pem" /remove "Users" "Everyone" >/dev/null 2>&1 || true

    # Also set mode bits to keep OpenSSH happy
    chmod 600 "$pem" 2>/dev/null || true
}

# Compute local PEM fingerprint matching the format AWS uses for KeyFingerprint.
#   SHA-1 (20 bytes / 19 colons) → AWS-created RSA keypairs: SHA1(DER-encoded private key)
#   MD5  (16 bytes / 15 colons) → imported keypairs: MD5 of public key
# Usage: compute_local_fp_for_aws <pem_path> <aws_fingerprint>
compute_local_fp_for_aws() {
    local pem="$1" aws_fp="$2"
    local colon_count fp=""
    colon_count="$(echo "$aws_fp" | tr -cd ':' | wc -c)"
    colon_count="${colon_count// /}"  # trim whitespace from wc

    if [[ "$colon_count" -eq 19 ]] || [[ "$colon_count" -ne 15 ]]; then
        # SHA-1 of DER-encoded private key (AWS CreateKeyPair / Console)
        # Use a temp file because DER is binary (null bytes break bash variables)
        local tmpder
        tmpder="$(mktemp)" || return 1
        if openssl rsa -in "$pem" -outform DER -out "$tmpder" 2>/dev/null && [[ -s "$tmpder" ]]; then
            local hex=""
            if command -v sha1sum >/dev/null 2>&1; then
                hex="$(sha1sum "$tmpder" | awk '{print $1}')"
            else
                hex="$(openssl dgst -sha1 "$tmpder" | awk '{print $NF}')"
            fi
            if [[ -n "$hex" && "$hex" != "da39a3ee5e6b4b0d3255bfef95601890afd80709" ]]; then
                fp="$(echo "$hex" | sed 's/..\B/&:/g')"
            fi
        fi
        rm -f "$tmpder"
    fi

    if [[ -z "$fp" && "$colon_count" -eq 15 ]]; then
        # MD5 of public key (imported keypair)
        fp="$(ssh-keygen -E md5 -lf "$pem" 2>/dev/null | awk '{print $2}' | sed 's/^MD5://g' || true)"
    fi

    printf '%s' "${fp,,}"
}
win_env() {
    local var="$1"
    printf '%s' "${!var-}"
}

maybe_import_windows_env() {
    local var="$1"
    local current="${!var:-}"
    if [[ -z "$current" ]]; then
        local pulled
        pulled="$(win_env "$var")"
        if [[ -n "$pulled" ]]; then
            export "$var=$pulled"
        fi
    fi
}

ensure_keypair_and_pem() {
    [[ -n "$KEY_NAME" ]] || die "KEY_NAME must be set in driver mode"
    [[ -n "$KEY_PEM_PATH" ]] || die "KEY_PEM_PATH must be set in driver mode"

    # Normalize to bash-usable path for Git Bash
    KEY_PEM_PATH="$(normalize_path_for_bash "$KEY_PEM_PATH")"
    local pem="$KEY_PEM_PATH"

    [[ -f "$pem" ]] || die "PEM file not found at '$pem'. Set KEY_PEM_PATH to the downloaded .pem file."

    aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" >/dev/null 2>&1 \
        || die "AWS keypair '$KEY_NAME' not found in region '$AWS_REGION'. Create/import it in EC2 → Key Pairs."

    need_cmd ssh-keygen || die "ssh-keygen not found (required for PEM/keypair fingerprint validation)."

    local warn
    warn="$(ssh-keygen -lf "$pem" 2>&1 || true)"
    if echo "$warn" | grep -q -E "UNPROTECTED PRIVATE KEY FILE|is not a key file"; then
        log_info "PEM permissions too open or unreadable; tightening permissions (Windows)..."
        maybe_fix_pem_perms_windows "$pem"
    fi

    local aws_fp local_fp
    aws_fp="$(aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" \
        --query 'KeyPairs[0].KeyFingerprint' --output text 2>/dev/null || true)"
    aws_fp="${aws_fp,,}"

    [[ -n "$aws_fp" ]] || die "Could not read AWS key fingerprint for '$KEY_NAME'."

    local_fp="$(compute_local_fp_for_aws "$pem" "$aws_fp")"

    [[ -n "$local_fp" ]] || die "Could not compute local PEM fingerprint for '$pem' (need openssl + sha1sum or ssh-keygen)."

    [[ "$local_fp" == "$aws_fp" ]] || die "PEM does not match AWS keypair. Choose a NEW KEY_NAME or recreate the keypair+PEM."
    log_info "Keypair/PEM fingerprint match confirmed for '$KEY_NAME'."
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
    local random_suffix=$(rand_hex)
    local run_id_clean="${RUN_ID//_/-}"  # Replace underscores with hyphens for S3 compatibility
    
    # ECR and Lambda names
    ECR_REPO_NAME="scrna-serverless-${timestamp}-${random_suffix}"
    LAMBDA_FUNCTION_NAME="scrna-map-${timestamp}-${random_suffix}"
    LAMBDA_EXECUTION_ROLE_NAME="scrna-lambda-role-${timestamp}-${random_suffix}"
    DOCKER_IMAGE_NAME="scrna-serverless-${run_id_clean}"
    
    # S3 bucket names (must be lowercase, no underscores, globally unique, ≤63 chars)
    INPUT_FASTQ_BUCKET="scrna-fastq-${AWS_ACCOUNT_ID}-${AWS_REGION}-${run_id_clean}"
    INPUT_TXT_BUCKET="scrna-txt-${AWS_ACCOUNT_ID}-${AWS_REGION}-${run_id_clean}"
    OUTPUT_MAP_BUCKET="scrna-map-${AWS_ACCOUNT_ID}-${AWS_REGION}-${run_id_clean}"
    OUTPUT_QUANT_BUCKET="scrna-quant-${AWS_ACCOUNT_ID}-${AWS_REGION}-${run_id_clean}"

    # Validate S3 bucket name length (max 63 chars)
    local _b
    for _b in "$INPUT_FASTQ_BUCKET" "$INPUT_TXT_BUCKET" "$OUTPUT_MAP_BUCKET" "$OUTPUT_QUANT_BUCKET"; do
        if (( ${#_b} > 63 )); then
            die "S3 bucket name too long (${#_b} > 63): $_b"
        fi
    done
}

################################################################################
# Bash Resource Setup Functions (replaces set-up-resources.py — no python needed)
################################################################################

create_ecr_repo_if_needed() {
    local repo_name="$1"
    local uri="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${repo_name}"
    if aws ecr describe-repositories --repository-names "$repo_name" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "ECR repository '$repo_name' already exists."
    else
        aws ecr create-repository --repository-name "$repo_name" \
            --image-scanning-configuration scanOnPush=true \
            --region "$AWS_REGION" >/dev/null
        log_info "ECR repository '$repo_name' created."
    fi
    echo "$uri"
}

build_and_push_lambda_image() {
    local repo_uri="$1" image_name="$2" build_dir="$3"
    local docker_tag="${repo_uri}:${image_name}"

    log_info "Building Docker image: $image_name ..."
    $DOCKER build --platform linux/amd64 -t "$image_name" "$build_dir" >&2

    log_info "Tagging image as $docker_tag"
    $DOCKER tag "$image_name" "$docker_tag" >&2

    log_info "Logging into ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | \
        $DOCKER login --username AWS --password-stdin \
        "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" >&2

    log_info "Pushing image to ECR..."
    $DOCKER push "$docker_tag" >&2

    log_info "Docker image pushed: $docker_tag"
    echo "$docker_tag"
}

create_lambda_execution_role() {
    local role_name="$1"

    # Check if role already exists
    local existing_arn
    existing_arn=$(aws iam get-role --role-name "$role_name" \
        --query 'Role.Arn' --output text 2>/dev/null || echo "")
    if [[ -n "$existing_arn" && "$existing_arn" != "None" ]]; then
        log_info "IAM role '$role_name' already exists: $existing_arn"
        echo "$existing_arn"
        return 0
    fi

    local trust_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["lambda.amazonaws.com","events.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'

    local role_arn
    role_arn=$(aws iam create-role \
        --role-name "$role_name" \
        --assume-role-policy-document "$trust_policy" \
        --description "Lambda execution role with EventBridge trigger" \
        --query 'Role.Arn' --output text)

    log_info "Created IAM role '$role_name': $role_arn"

    # Attach required policies (same as set-up-resources.py)
    local policies=(
        "arn:aws:iam::aws:policy/AmazonS3FullAccess"
        "arn:aws:iam::aws:policy/service-role/AmazonS3ObjectLambdaExecutionRolePolicy"
        "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
    )

    local max_retries=5
    for policy_arn in "${policies[@]}"; do
        local delay=5
        for attempt in $(seq 1 $max_retries); do
            if aws iam attach-role-policy --role-name "$role_name" \
                --policy-arn "$policy_arn" 2>/dev/null; then
                log_info "Attached policy $policy_arn"
                break
            fi
            [[ $attempt -eq $max_retries ]] && die "Failed to attach policy $policy_arn after $max_retries attempts."
            sleep "$delay"; delay=$((delay * 2))
        done
    done

    echo "$role_arn"
}

create_lambda_function_from_image() {
    local func_name="$1" role_arn="$2" image_uri="$3"
    local mem="$4" eph="$5" timeout_sec="$6"

    local env_json
    env_json=$(jq -n \
        --arg out "$OUTPUT_MAP_BUCKET" \
        --arg inp "$INPUT_FASTQ_BUCKET" \
        --arg txt "$INPUT_TXT_BUCKET" \
        '{Variables:{S3_OUTPUT_BUCKET_NAME:$out,S3_INPUT_BUCKET_NAME:$inp,S3_INPUT_TXT_BUCKET_NAME:$txt}}')

    # Check if function already exists
    local existing_arn
    existing_arn=$(aws lambda get-function --function-name "$func_name" \
        --region "$AWS_REGION" --query 'Configuration.FunctionArn' --output text 2>/dev/null || echo "")
    if [[ -n "$existing_arn" && "$existing_arn" != "None" ]]; then
        log_info "Lambda function '$func_name' already exists."
        echo "$existing_arn"
        return 0
    fi

    local max_retries=5 delay=5
    local _create_err
    for attempt in $(seq 1 $max_retries); do
        local func_arn
        _create_err=$(mktemp)
        if func_arn=$(aws lambda create-function \
            --function-name "$func_name" \
            --role "$role_arn" \
            --code "ImageUri=$image_uri" \
            --package-type Image \
            --memory-size "$mem" \
            --ephemeral-storage "Size=$eph" \
            --timeout "$timeout_sec" \
            --architectures x86_64 \
            --environment "$env_json" \
            --region "$AWS_REGION" \
            --query 'FunctionArn' --output text 2>"$_create_err"); then
            rm -f "$_create_err"
            log_info "Lambda function '$func_name' created."
            echo "$func_arn"
            return 0
        fi
        local err_msg; err_msg=$(cat "$_create_err" 2>/dev/null); rm -f "$_create_err"
        # Memory quota exceeded — return 2 so caller can fallback
        if [[ "$err_msg" == *"InvalidParameterValue"* || "$err_msg" == *"ValidationException"* && "$err_msg" == *"MemorySize"* ]]; then
            log_info "Memory quota exceeded (detected in error): $err_msg"
            return 2
        fi
        log_info "Lambda creation attempt $attempt/$max_retries failed: ${err_msg:-unknown error}. Retrying in ${delay}s..."
        sleep "$delay"; delay=$((delay * 2))
    done

    return 1
}

create_eventbridge_rule_for_lambda() {
    local rule_name="$1" lambda_arn="$2" bucket_name="$3"

    # Ensure EventBridge notifications enabled on bucket
    aws s3api put-bucket-notification-configuration \
        --bucket "$bucket_name" \
        --notification-configuration '{"EventBridgeConfiguration":{}}' \
        --region "$AWS_REGION" 2>/dev/null || true

    # Create EventBridge rule
    local event_pattern
    event_pattern=$(jq -n --arg b "$bucket_name" \
        '{source:["aws.s3"],"detail-type":["Object Created"],detail:{bucket:{name:[$b]}}}')

    local rule_arn
    rule_arn=$(aws events put-rule \
        --name "$rule_name" \
        --event-pattern "$event_pattern" \
        --state ENABLED \
        --region "$AWS_REGION" \
        --query 'RuleArn' --output text)

    log_info "EventBridge rule '$rule_name' created."

    # Add Lambda as target
    aws events put-targets \
        --rule "$rule_name" \
        --targets "Id=LambdaTarget,Arn=$lambda_arn" \
        --region "$AWS_REGION" >/dev/null

    log_info "Lambda added as target to rule '$rule_name'."

    # Grant EventBridge permission to invoke Lambda
    aws lambda add-permission \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --statement-id "EventBridgeInvoke-$(date +%s)" \
        --action "lambda:InvokeFunction" \
        --principal "events.amazonaws.com" \
        --source-arn "$rule_arn" \
        --region "$AWS_REGION" >/dev/null 2>&1 || log_info "Lambda invoke permission already exists (ok)"

    # Verify rule is enabled
    local max_wait=30 elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        local state
        state=$(aws events describe-rule --name "$rule_name" --region "$AWS_REGION" \
            --query 'State' --output text 2>/dev/null || echo "")
        if [[ "$state" == "ENABLED" ]]; then
            log_info "EventBridge rule verified ENABLED."
            return 0
        fi
        sleep 5; elapsed=$((elapsed + 5))
    done
    log_warn "EventBridge rule not confirmed ENABLED within ${max_wait}s (continuing)."
}

################################################################################
# Bash FASTQ Processing Functions (replaces process_fastq.py — no python needed)
################################################################################

find_s3_fastq_pairs() {
    # Outputs lines: base_with_lane<TAB>read_type<TAB>key for each R1/R2 .fastq.gz
    local bucket="$1"
    aws s3api list-objects-v2 --bucket "$bucket" --region "$AWS_REGION" \
        --query "Contents[].Key" --output text 2>/dev/null | \
    tr '\t' '\n' | grep '\.fastq\.gz$' | grep -v '_I[12]_' | sort | \
    while IFS= read -r key; do
        if [[ "$key" =~ ^(.+_L[0-9]{3})_(R[12])_[0-9]{3}(_p[0-9]+)?\.fastq\.gz$ ]]; then
            printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$key"
        fi
    done
}

create_and_upload_input_txt() {
    local lane_id="$1" r1_s3_path="$2" r2_s3_path="$3" base_folder="$4"
    local input_file="/tmp/${lane_id}_p0_input.txt"
    printf '%s\n%s\n' "$r1_s3_path" "$r2_s3_path" > "$input_file"

    local s3_key
    if [[ -n "$base_folder" && "$base_folder" != "." ]]; then
        s3_key="${base_folder}/${lane_id}_p0_input.txt"
    else
        s3_key="${lane_id}_p0_input.txt"
    fi

    aws s3 cp "$input_file" "s3://${INPUT_TXT_BUCKET}/${s3_key}" \
        --region "$AWS_REGION" --only-show-errors
    rm -f "$input_file"
    log_info "Uploaded input.txt for ${lane_id}_p0"
}

process_fastq_bash() {
    local output_dir="$1"

    log_info "Finding FASTQ pairs in S3 bucket $INPUT_FASTQ_BUCKET ..."

    declare -A PF_R1_KEYS PF_R2_KEYS
    local pair_info
    pair_info=$(find_s3_fastq_pairs "$INPUT_FASTQ_BUCKET")

    while IFS=$'\t' read -r base read_type key; do
        [[ -z "$base" ]] && continue
        if [[ "$read_type" == "R1" ]]; then
            PF_R1_KEYS["$base"]="$key"
        else
            PF_R2_KEYS["$base"]="$key"
        fi
    done <<< "$pair_info"

    local INPUT_FOLDERS=()

    for base in "${!PF_R1_KEYS[@]}"; do
        local r1_key="${PF_R1_KEYS[$base]}"
        local r2_key="${PF_R2_KEYS[$base]:-}"
        [[ -z "$r2_key" ]] && { log_warn "No R2 for $base, skipping"; continue; }

        local lane_id base_folder
        lane_id=$(basename "$base")
        base_folder=$(dirname "$base")
        [[ "$base_folder" == "." ]] && base_folder=""

        # Check combined file size
        local r1_bytes r2_bytes combined_bytes split_threshold_bytes
        r1_bytes=$(aws s3api head-object --bucket "$INPUT_FASTQ_BUCKET" --key "$r1_key" \
            --region "$AWS_REGION" --query 'ContentLength' --output text 2>/dev/null || echo 0)
        r2_bytes=$(aws s3api head-object --bucket "$INPUT_FASTQ_BUCKET" --key "$r2_key" \
            --region "$AWS_REGION" --query 'ContentLength' --output text 2>/dev/null || echo 0)
        combined_bytes=$(( r1_bytes + r2_bytes ))
        # Force splitting when Lambda memory <= 3008 MB (threshold=0) to avoid OOM/timeouts
        if [[ $LAMBDA_MEMORY_MB -le 3008 ]]; then
            split_threshold_bytes=0
        else
            split_threshold_bytes=$(( 7 * 1024 * 1024 * 1024 ))
        fi
        log_info "Pair $lane_id: combined size $(( combined_bytes / 1048576 )) MB (split threshold: $(( split_threshold_bytes / 1048576 )) MB)"

        if [[ $split_threshold_bytes -gt 0 && $combined_bytes -lt $split_threshold_bytes ]]; then
            local r1_s3="s3://${INPUT_FASTQ_BUCKET}/${r1_key}"
            local r2_s3="s3://${INPUT_FASTQ_BUCKET}/${r2_key}"
            sleep 3
            create_and_upload_input_txt "$lane_id" "$r1_s3" "$r2_s3" "$base_folder"
            INPUT_FOLDERS+=("${lane_id}_p0")
        else
            log_info "Splitting large files for $lane_id ..."
            local num_parts
            num_parts=$(bash /home/ubuntu/scrna-repo/split_and_upload.sh \
                "$INPUT_FASTQ_BUCKET" "$r1_key" "$r2_key" "$base" "$INPUT_TXT_BUCKET" 2>&1 | tail -1)
            if [[ "${num_parts:-0}" -gt 0 ]]; then
                for idx in $(seq 0 $((num_parts - 1))); do
                    INPUT_FOLDERS+=("${lane_id}_p${idx}")
                done
            else
                die "split_and_upload.sh failed for $lane_id"
            fi
        fi
    done

    local input_count=${#INPUT_FOLDERS[@]}
    log_info "Total input folders: $input_count"
    [[ $input_count -gt 0 ]] || die "No input folders created. Check FASTQ files in $INPUT_FASTQ_BUCKET"

    # Wait 30s for EventBridge propagation (matches process_fastq.py behavior)
    log_info "Waiting 30s for EventBridge/Lambda warm-up..."
    sleep 30

    # Poll output bucket
    log_info "Polling output bucket $OUTPUT_MAP_BUCKET for Lambda results..."
    local poll_start
    poll_start=$(date +%s)

    while true; do
        local completed=0
        for folder in "${INPUT_FOLDERS[@]}"; do
            if aws s3api head-object --bucket "$OUTPUT_MAP_BUCKET" \
                --key "piscem_output/${folder}/output.txt" \
                --region "$AWS_REGION" >/dev/null 2>&1; then
                completed=$((completed + 1))
            fi
        done

        log_info "Output progress: $completed / $input_count"

        if [[ $completed -ge $input_count ]]; then
            break
        fi

        local elapsed=$(( $(date +%s) - poll_start ))
        if [[ $elapsed -gt $PROCESS_FASTQ_TIMEOUT_SEC ]]; then
            log_error "Timeout (${PROCESS_FASTQ_TIMEOUT_SEC}s) waiting for Lambda outputs."
            log_error "Checking CloudWatch logs for Lambda errors..."
            aws logs tail "/aws/lambda/$LAMBDA_FUNCTION_NAME" --region "$AWS_REGION" \
                --since 30m --format short 2>&1 | tail -50 >&2 || true
            log_error "Listing output bucket contents for diagnostics..."
            aws s3 ls "s3://$OUTPUT_MAP_BUCKET/" --recursive --region "$AWS_REGION" 2>&1 | tail -30 >&2 || true
            die "Lambda did not complete in time. Check CloudWatch logs above for OOM / Runtime errors."
        fi
        # Fail-fast: if zero progress after LAMBDA_TIMEOUT_SEC, Lambda likely failed
        if [[ $completed -eq 0 && $elapsed -gt $LAMBDA_TIMEOUT_SEC ]]; then
            log_warn "Zero outputs after $((elapsed/60))m (Lambda timeout: ${LAMBDA_TIMEOUT_SEC}s). Checking CloudWatch for errors..."
            aws logs tail "/aws/lambda/$LAMBDA_FUNCTION_NAME" --region "$AWS_REGION" \
                --since 15m --format short 2>&1 | grep -iE 'error|oom|runtime.exited|killed|memory' | tail -20 >&2 || true
            if [[ $elapsed -gt $(( LAMBDA_TIMEOUT_SEC * 2 )) ]]; then
                die "No Lambda outputs after $((elapsed/60))m (2x timeout). Lambda processing appears to have failed."
            fi
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done

    local elapsed_sec=$(( $(date +%s) - poll_start ))
    log_info "All $input_count outputs ready ($((elapsed_sec / 60)) min $((elapsed_sec % 60)) sec)"

    # Download outputs
    log_info "Downloading output files from $OUTPUT_MAP_BUCKET ..."
    for folder in "${INPUT_FOLDERS[@]}"; do
        local local_dir="${output_dir}/piscem_output/${folder}"
        mkdir -p "$local_dir"
        aws s3 sync "s3://${OUTPUT_MAP_BUCKET}/piscem_output/${folder}/" "$local_dir/" \
            --region "$AWS_REGION" --only-show-errors
    done

    log_info "All output files downloaded to $output_dir"
}

################################################################################
# SSM Helper Functions (for driver mode when SSH is blocked)
################################################################################

ssm_wait_for_managed() {
    local instance_id="$1" max_wait="${2:-300}"
    log_info "Waiting for instance $instance_id to become SSM-managed ..."
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        local managed
        managed=$(aws ssm describe-instance-information \
            --region "$AWS_REGION" \
            --filters "Key=InstanceIds,Values=$instance_id" \
            --query 'InstanceInformationList[0].InstanceId' \
            --output text 2>/dev/null || echo "")
        if [[ "$managed" == "$instance_id" ]]; then
            log_info "Instance $instance_id is SSM-managed."
            return 0
        fi
        sleep 10; elapsed=$((elapsed + 10))
    done
    die "Instance $instance_id not SSM-managed after ${max_wait}s. Ensure instance profile '$EC2_INSTANCE_PROFILE_NAME' includes the AmazonSSMManagedInstanceCore policy."
}

ssm_run_command() {
    # Run a short command via SSM and return stdout
    local instance_id="$1" cmd_text="$2" timeout_sec="${3:-600}"
    local cmd_id
    cmd_id=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "{\"commands\":[\"$cmd_text\"]}" \
        --timeout-seconds "$timeout_sec" \
        --query 'Command.CommandId' --output text)

    # Poll for completion
    while true; do
        local inv status
        inv=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --output json 2>/dev/null || echo '{"Status":"Pending"}')
        status=$(echo "$inv" | jq -r '.Status')
        case "$status" in
            Success)
                echo "$inv" | jq -r '.StandardOutputContent // ""'
                return 0 ;;
            Failed|TimedOut|Cancelled)
                log_error "SSM command $status (ID: $cmd_id)"
                echo "$inv" | jq -r '.StandardErrorContent // ""' >&2
                return 1 ;;
            *) sleep 5 ;;
        esac
    done
}

ssm_run_pipeline() {
    # Run the e2e pipeline via SSM send-command with S3 output capture
    local instance_id="$1" dataset="$2"
    local transfer_bucket="$3" run_id="$4"

    # Build commands array via jq
    local cmds_json
    cmds_json=$(jq -n \
        --arg region "$AWS_REGION" \
        --arg mem "$LAMBDA_MEMORY_MB" \
        --arg eph "$LAMBDA_EPHEMERAL_MB" \
        --arg timeout "$LAMBDA_TIMEOUT_SEC" \
        --arg threads "$THREADS" \
        --arg cleanup "$CLEANUP_AWS" \
        --arg fastq_path "${FASTQ_TAR_PATH:-}" \
        --arg fastq_url "${FASTQ_TAR_URL:-}" \
        --arg write_h5ad "$WRITE_H5AD" \
        --arg run_id "$run_id" \
        --arg run_qc "$RUN_QC" \
        --arg user "$SSH_USER" \
        --arg ds "$dataset" \
        '{commands:[
            "#!/bin/bash",
            "set -euo pipefail",
            ("export AWS_REGION=" + $region),
            ("export LAMBDA_MEMORY_MB=" + $mem),
            ("export LAMBDA_EPHEMERAL_MB=" + $eph),
            ("export LAMBDA_TIMEOUT_SEC=" + $timeout),
            ("export THREADS=" + $threads),
            ("export CLEANUP_AWS=" + $cleanup),
            ("export FASTQ_TAR_PATH=" + $fastq_path),
            ("export FASTQ_TAR_URL=" + $fastq_url),
            ("export WRITE_H5AD=" + $write_h5ad),
            ("export RUN_ID=" + $run_id),
            ("export RUN_QC=" + $run_qc),
            ("cd /home/" + $user + "/scrna-repo"),
            ("bash scripts/e2e_serverless_pbmc.sh " + $ds + " --run 2>&1 | tee /tmp/pipeline-" + $run_id + ".log")
        ]}')

    local cmd_id
    cmd_id=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "$cmds_json" \
        --timeout-seconds 7200 \
        --output-s3-bucket-name "$transfer_bucket" \
        --output-s3-key-prefix "ssm-output/$run_id" \
        --query 'Command.CommandId' --output text)

    log_info "SSM pipeline command sent: $cmd_id"

    # Poll for completion.
    # NOTE: when --output-s3-bucket-name is used, get-command-invocation may
    # return truncated JSON or empty StandardOutputContent (output goes to S3).
    # We parse status only; stdout comes from the S3 log after completion.
    local last_len=0
    while true; do
        local inv status
        inv=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --output json 2>&1 || true)

        # Guard against truncated / malformed JSON from SSM
        if ! status=$(echo "$inv" | jq -r '.Status' 2>/dev/null); then
            log_info "SSM poll: waiting (response not valid JSON)..."
            sleep 15
            continue
        fi

        # Stream stdout incrementally (may be empty when S3 output is used)
        local stdout
        stdout=$(echo "$inv" | jq -r '.StandardOutputContent // ""' 2>/dev/null) || stdout=""
        local cur_len=${#stdout}
        if [[ $cur_len -gt $last_len ]]; then
            printf '%s' "${stdout:$last_len}"
            last_len=$cur_len
        fi

        case "$status" in
            Success)
                log_info "Pipeline completed successfully via SSM."
                # Download full output log from S3
                log_info "Downloading full SSM output log from S3..."
                mkdir -p "${LOCAL_RESULTS_DIR}/${run_id}/ssm-output"
                aws s3 sync "s3://${transfer_bucket}/ssm-output/${run_id}/" \
                    "${LOCAL_RESULTS_DIR}/${run_id}/ssm-output/" --region "$AWS_REGION" 2>/dev/null || true
                return 0 ;;
            Failed|TimedOut|Cancelled)
                log_error "Pipeline command $status (SSM ID: $cmd_id)"
                echo "$inv" | jq -r '.StandardErrorContent // ""' 2>/dev/null >&2 || true
                # Download full log from S3
                log_info "Downloading full SSM output log from S3..."
                mkdir -p "${LOCAL_RESULTS_DIR}/${run_id}/ssm-output"
                aws s3 sync "s3://${transfer_bucket}/ssm-output/${run_id}/" \
                    "${LOCAL_RESULTS_DIR}/${run_id}/ssm-output/" --region "$AWS_REGION" 2>/dev/null || true
                return 1 ;;
            *) sleep 15 ;;
        esac
    done
}

################################################################################
# Argument Parsing
################################################################################

if [[ $# -lt 1 ]]; then
    cat >&2 <<EOF
Usage: $0 <dataset> [--run|--dry-run]
  dataset: pbmc1k or pbmc10k
  --run: Execute in run mode on EC2 (default: driver mode)
  --dry-run: Validate requirements without creating AWS resources
EOF
    exit 1
fi

DATASET="$1"
if [[ "$DATASET" != "pbmc1k" && "$DATASET" != "pbmc10k" ]]; then
    die "Unknown dataset: $DATASET (must be pbmc1k or pbmc10k)"
fi

if [[ $# -gt 1 ]]; then
    if [[ "$2" == "--run" ]]; then
        RUN_MODE=1
    elif [[ "$2" == "--dry-run" ]]; then
        DRY_RUN_MODE=1
    fi
fi

################################################################################
# Windows Environment Variable Import
# Under WSL/MSYS bash, PowerShell env vars may not propagate automatically.
################################################################################

maybe_import_windows_env AWS_REGION
maybe_import_windows_env KEY_NAME
maybe_import_windows_env KEY_PEM_PATH
maybe_import_windows_env EC2_INSTANCE_PROFILE_NAME
maybe_import_windows_env SEED_AMI_ID
maybe_import_windows_env SUBNET_ID
maybe_import_windows_env SG_ID
maybe_import_windows_env USE_SSM

# Re-apply defaults after import (in case import populated them)
AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
KEY_NAME="${KEY_NAME:-$DEFAULT_KEY_NAME}"
KEY_PEM_PATH="${KEY_PEM_PATH:-$DEFAULT_KEY_PEM_PATH}"
EC2_INSTANCE_PROFILE_NAME="${EC2_INSTANCE_PROFILE_NAME:-$DEFAULT_EC2_INSTANCE_PROFILE_NAME}"
SEED_AMI_ID="${SEED_AMI_ID:-$DEFAULT_SEED_AMI_ID}"

# Normalize Windows PEM path if needed
# (Postponed: normalize inside validate_dry_run / ensure_keypair_and_pem
#  so raw path is available for WSL detection and error messages.)

# Fail fast if running under WSL — paths like D:\... resolve to /d/... which
# does not exist in WSL (it uses /mnt/d/...).  The script is designed for
# Git for Windows (Git Bash / MSYS / MINGW).
if is_wsl && [[ $DRY_RUN_MODE -eq 1 || $RUN_MODE -eq 0 ]]; then
    log_error "WSL bash detected ($(uname -a))."
    die "Use Git for Windows (Git Bash) to run this script. uname must show MINGW/MSYS, not Linux."
fi

################################################################################
# Dry-Run Validation
################################################################################

validate_dry_run() {
    local pass=0
    local fail=0
    
    log_info "========== DRY-RUN VALIDATION =========="
    log_info ""
    
    # AWS CLI
    log_info "[CHECK 1/7] AWS CLI..."
    if ! need_cmd aws; then
        log_error "  FAIL: AWS CLI not found"
        fail=$((fail + 1))
    else
        log_info "  PASS: AWS CLI installed"
        pass=$((pass + 1))
    fi
    
    # AWS Auth
    log_info "[CHECK 2/7] AWS authentication..."
    if ! aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
        log_error "  FAIL: AWS authentication failed"
        fail=$((fail + 1))
    else
        CALLER=$(aws sts get-caller-identity --region "$AWS_REGION" --query Arn --output text)
        AWS_ACCOUNT_ID=$(aws sts get-caller-identity --region "$AWS_REGION" --query Account --output text)
        log_info "  PASS: Authenticated as $CALLER"
        pass=$((pass + 1))
    fi
    
    # Docker: only required on EC2 (run mode). In driver mode it runs on EC2.
    log_info "[CHECK 3/7] Docker..."
    if [[ $RUN_MODE -eq 0 ]]; then
        # Driver mode: Docker runs on EC2, not locally
        if need_cmd docker && docker ps >/dev/null 2>&1; then
            log_info "  PASS: Docker accessible (optional in driver mode)"
            pass=$((pass + 1))
        else
            log_info "  SKIP: Docker not required in driver mode (runs on EC2)"
        fi
    else
        # Run mode: Docker is needed locally
        if ! need_cmd docker; then
            log_error "  FAIL: Docker not installed"
            fail=$((fail + 1))
        elif ! docker ps >/dev/null 2>&1; then
            log_error "  FAIL: Docker not accessible (run: docker ps)"
            fail=$((fail + 1))
        else
            log_info "  PASS: Docker working"
            pass=$((pass + 1))
        fi
    fi
    
    # Seed AMI
    if [[ $RUN_MODE -eq 0 ]]; then
        log_info "[CHECK 4/7] Seed AMI..."
        if ! aws ec2 describe-images --image-ids "$SEED_AMI_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
            log_error "  FAIL: AMI not found: $SEED_AMI_ID"
            fail=$((fail + 1))
        else
            log_info "  PASS: Seed AMI accessible"
            pass=$((pass + 1))
        fi
    else
        log_info "[CHECK 4/7] (skipped, run mode)"
    fi
    
    # Keypair + PEM
    if [[ $RUN_MODE -eq 0 ]]; then
        log_info "[CHECK 5/7] Keypair + PEM..."
        if [[ "$USE_SSM" == "1" && -z "$KEY_NAME" ]]; then
            log_info "  SKIP: KEY_NAME not set but USE_SSM=1 (SSH not required)"
        elif [[ -z "$KEY_NAME" ]]; then
            log_error "  FAIL: KEY_NAME not set"
            fail=$((fail + 1))
        elif [[ -z "$KEY_PEM_PATH" ]]; then
            log_error "  FAIL: KEY_PEM_PATH not set"
            fail=$((fail + 1))
        elif ! command -v ssh-keygen >/dev/null 2>&1; then
            log_error "  FAIL: ssh-keygen not found (required for PEM/keypair fingerprint validation)"
            fail=$((fail + 1))
        else
            local raw_pem="$KEY_PEM_PATH"
            pem_check="$(normalize_path_for_bash "$raw_pem")"
            if [[ ! -f "$pem_check" ]]; then
                log_error "  FAIL: PEM not found (raw='$raw_pem' resolved='$pem_check')"
                fail=$((fail + 1))
            elif ! aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
                log_error "  FAIL: AWS keypair not found: $KEY_NAME"
                fail=$((fail + 1))
            else
                warn="$(ssh-keygen -lf "$pem_check" 2>&1 || true)"
                if echo "$warn" | grep -q -E "UNPROTECTED PRIVATE KEY FILE|is not a key file"; then
                    log_info "PEM permissions too open or unreadable; tightening permissions (Windows)..."
                    maybe_fix_pem_perms_windows "$pem_check"
                fi
                aws_fp="$(aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" \
                    --query 'KeyPairs[0].KeyFingerprint' --output text 2>/dev/null || true)"
                aws_fp="${aws_fp,,}"
                local_fp="$(compute_local_fp_for_aws "$pem_check" "$aws_fp")"
                if [[ -z "$aws_fp" || -z "$local_fp" ]]; then
                    log_error "  FAIL: Could not compute fingerprints for mismatch detection"
                    fail=$((fail + 1))
                elif [[ "$aws_fp" != "$local_fp" ]]; then
                    log_error "  FAIL: PEM/keypair mismatch (AWS=$aws_fp local=$local_fp)"
                    fail=$((fail + 1))
                else
                    log_info "  PASS: Keypair + PEM present and match"
                    pass=$((pass + 1))
                fi
            fi
        fi
    else
        log_info "[CHECK 5/7] (skipped, run mode)"
    fi
    
    # FASTQ URL
    log_info "[CHECK 6/7] FASTQ URL..."
    local fastq_url="$FASTQ_TAR_URL"
    if [[ -z "$fastq_url" ]]; then
        case "$DATASET" in
            pbmc1k) fastq_url="https://s3-us-west-2.amazonaws.com/10x.files/samples/cell-exp/3.0.0/pbmc_1k_v3/pbmc_1k_v3_fastqs.tar" ;;
            pbmc10k) fastq_url="https://s3-us-west-2.amazonaws.com/10x.files/samples/cell-exp/3.0.0/pbmc_10k_v3/pbmc_10k_v3_fastqs.tar" ;;
        esac
    fi
    if ! curl -s -I -m 10 "$fastq_url" 2>/dev/null | head -1 | grep -q "200\|302"; then
        log_error "  FAIL: FASTQ URL not reachable"
        fail=$((fail + 1))
    else
        log_info "  PASS: FASTQ URL reachable"
        pass=$((pass + 1))
    fi
    
    # Instance Profile  
    if [[ $RUN_MODE -eq 0 ]]; then
        log_info "[CHECK 7/7] EC2 instance profile..."
        if [[ -z "$EC2_INSTANCE_PROFILE_NAME" ]]; then
            log_error "  FAIL: EC2_INSTANCE_PROFILE_NAME not set"
            fail=$((fail + 1))
        elif ! aws iam get-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
            log_error "  FAIL: Instance profile not found: $EC2_INSTANCE_PROFILE_NAME"
            fail=$((fail + 1))
        else
            log_info "  PASS: Instance profile exists"
            pass=$((pass + 1))
        fi
    else
        log_info "[CHECK 7/7] (skipped, run mode)"
    fi
    
    log_info ""
    log_info "========== RESULT =========="
    log_info "PASSED: $pass | FAILED: $fail"
    log_info ""
    
    if [[ $fail -eq 0 ]]; then
        log_info "All checks passed! Ready to run:"
        log_info "  export CLEANUP_AWS=0 TERMINATE_DRIVER_ON_EXIT=0 RUN_QC=1 WRITE_H5AD=1"
        log_info "  bash scripts/e2e_serverless_pbmc.sh $DATASET 2>&1 | tee pbmc1k.log"
        return 0
    else
        log_error "$fail check(s) failed. See errors above."
        return 1
    fi
}

################################################################################
# Handle Dry-Run Mode
################################################################################

if [[ $DRY_RUN_MODE -eq 1 ]]; then
    if ! validate_dry_run; then
        exit 1
    fi
    exit 0
fi

################################################################################
# Pre-Run Checks (AWS CLI, authentication, keypair)
################################################################################

# 1. AWS CLI must be available before any aws command
if ! need_cmd aws; then
    if [[ $RUN_MODE -eq 1 ]]; then
        log_info "AWS CLI v2 not found — installing..."
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
        (cd /tmp && unzip -qo awscliv2.zip && sudo ./aws/install --update 2>&1) >&2
        rm -rf /tmp/awscliv2.zip /tmp/aws
        hash -r
        if ! command -v aws >/dev/null 2>&1; then
            die "Failed to install AWS CLI v2. Install it manually and re-run."
        fi
        log_info "AWS CLI installed: $(aws --version 2>&1)"
    else
        die "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    fi
fi

# 1.5. Ensure jq is available locally (needed for SSM fallback and Lambda JSON parsing)
if ! need_cmd jq; then
    if [[ $RUN_MODE -eq 0 ]]; then
        log_info "jq not found — auto-installing for this session..."
        _jq_dir="$HOME/.local/bin"
        mkdir -p "$_jq_dir"
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*)
                curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe" -o "$_jq_dir/jq.exe"
                ;;
            Linux*)
                curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" -o "$_jq_dir/jq"
                chmod +x "$_jq_dir/jq"
                ;;
            Darwin*)
                curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64" -o "$_jq_dir/jq"
                chmod +x "$_jq_dir/jq"
                ;;
            *)
                die "Unsupported OS for jq auto-install. Install manually: https://jqlang.github.io/jq/download/"
                ;;
        esac
        export PATH="$_jq_dir:$PATH"
        if ! need_cmd jq; then
            die "Failed to install jq. Install manually: https://jqlang.github.io/jq/download/"
        fi
        log_info "jq installed: $(jq --version 2>&1)"
    fi
fi

# 2. AWS authentication must work
if ! aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
    log_error "AWS authentication failed."
    log_error "Run 'aws configure' or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN."
    die "Cannot proceed without valid AWS credentials."
fi
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --region "$AWS_REGION" --query Account --output text)
log_info "AWS authenticated (account: $AWS_ACCOUNT_ID, region: $AWS_REGION)"

# 3. In driver mode checks (keypair, instance profile)
if [[ $RUN_MODE -eq 0 ]]; then
    # Instance profile
    if [[ -z "$EC2_INSTANCE_PROFILE_NAME" ]]; then
        die "EC2_INSTANCE_PROFILE_NAME must be set for driver mode."
    fi
    if ! aws iam get-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
        die "Instance profile '$EC2_INSTANCE_PROFILE_NAME' not found in IAM."
    fi
    log_info "Instance profile verified: $EC2_INSTANCE_PROFILE_NAME"

    # Keypair (when SSH may be used)
    if [[ "$USE_SSM" != "1" ]]; then
        if [[ -z "$KEY_NAME" ]]; then
            die "KEY_NAME must be set (or export USE_SSM=1 for SSM-only mode)."
        fi
        if ! aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
            die "AWS keypair '$KEY_NAME' not found in region '$AWS_REGION'. Create it in EC2 → Key Pairs."
        fi
        log_info "Keypair verified in AWS: $KEY_NAME"
    fi
fi

################################################################################
# Generate Run ID
################################################################################

if [[ -z "$RUN_ID" ]]; then
    RUN_ID="pbmc-$(date +%s)-$(rand_hex)"
fi

################################################################################
# Mode: Driver (Launch EC2 and run pipeline)
################################################################################

if [[ $RUN_MODE -eq 0 ]]; then
    log_info "======== E2E Serverless scRNA Pipeline (DRIVER MODE) ========"
    log_info "Dataset: $DATASET"
    log_info "Run ID: $RUN_ID"
    log_info "USE_SSM: $USE_SSM"

    # Capture all driver-mode output to a log file in the results directory
    mkdir -p "$LOCAL_RESULTS_DIR"
    PIPELINE_LOG="$LOCAL_RESULTS_DIR/${RUN_ID}.log"
    exec > >(tee -a "$PIPELINE_LOG") 2>&1
    log_info "Pipeline log: $PIPELINE_LOG"
    
    # Validate and ensure keypair+PEM (only when SSH may be used)
    if [[ "$USE_SSM" != "1" ]]; then
        ensure_keypair_and_pem
    elif [[ -n "$KEY_NAME" && -n "$KEY_PEM_PATH" ]]; then
        # SSM=1 but keys provided — validate them (useful for fallback)
        ensure_keypair_and_pem
    else
        log_info "USE_SSM=1: skipping keypair/PEM validation (SSH not required)."
    fi
    
    # Auto-detect seed AMI by name prefix if not set
    if [[ -z "$SEED_AMI_ID" && $AUTO_DETECT_SEED_AMI -eq 1 ]]; then
        log_info "Auto-detecting seed AMI with prefix: $SEED_AMI_NAME_PREFIX (owner: $SEED_AMI_OWNER)"
        SEED_AMI_ID=$(aws ec2 describe-images \
            --region "$AWS_REGION" \
            --owners "$SEED_AMI_OWNER" \
            --filters "Name=name,Values=${SEED_AMI_NAME_PREFIX}*" "Name=state,Values=available" \
            --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
            --output text 2>/dev/null || echo "")
        
        if [[ -z "$SEED_AMI_ID" || "$SEED_AMI_ID" == "None" ]]; then
            log_error "No seed AMI found with prefix: $SEED_AMI_NAME_PREFIX (owner: $SEED_AMI_OWNER)"
            log_error "Options for reviewers:"
            log_error "  1. Set SEED_AMI_OWNER to the publisher's AWS account ID (e.g., SEED_AMI_OWNER=123456789012)"
            log_error "  2. Set SEED_AMI_ID explicitly (e.g., SEED_AMI_ID=ami-xxxxx)"
            log_error "Options for authors:"
            log_error "  1. Set DEFAULT_SEED_AMI_ID in this script"
            log_error "  2. Build and share seed AMI: bash scripts/build_seed_ami.sh"
            log_error "  3. Disable auto-detect: AUTO_DETECT_SEED_AMI=0 and set SEED_AMI_ID manually"
            die "Seed AMI not found and AUTO_DETECT_SEED_AMI=1"
        fi
        log_info "Found seed AMI: $SEED_AMI_ID"
    fi
    
    # Auto-pick a truly public subnet from default VPC if not set
    if [[ -z "$SUBNET_ID" && $AUTO_PICK_SUBNET -eq 1 ]]; then
        log_info "Auto-picking public subnet from default VPC..."
        
        # Find default VPC
        VPC_ID=$(aws ec2 describe-vpcs \
            --region "$AWS_REGION" \
            --filters "Name=isDefault,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text 2>/dev/null || echo "")
        
        if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
            die "No default VPC found in region $AWS_REGION. Set SUBNET_ID explicitly or disable AUTO_PICK_SUBNET=0."
        fi
        
        # Get main route table for VPC (fallback for subnets without explicit association)
        MAIN_RT=$(aws ec2 describe-route-tables \
            --region "$AWS_REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
            --query 'RouteTables[0].RouteTableId' \
            --output text 2>/dev/null || echo "")
        
        # List all subnets with MapPublicIpOnLaunch=true
        CANDIDATE_SUBNETS=$(aws ec2 describe-subnets \
            --region "$AWS_REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
            --query 'Subnets[*].[SubnetId,AvailableIpAddressCount,AvailabilityZone]' \
            --output text 2>/dev/null || echo "")
        
        if [[ -z "$CANDIDATE_SUBNETS" ]]; then
            # Show all subnets for diagnosis
            log_error "No subnets with MapPublicIpOnLaunch=true in VPC $VPC_ID."
            log_error "All subnets in this VPC:"
            aws ec2 describe-subnets --region "$AWS_REGION" \
                --filters "Name=vpc-id,Values=$VPC_ID" \
                --query 'Subnets[*].[SubnetId,MapPublicIpOnLaunch,AvailableIpAddressCount,AvailabilityZone]' \
                --output table 2>/dev/null || true
            die "Set SUBNET_ID explicitly to a public subnet."
        fi
        
        # For each candidate, verify it has a route to an internet gateway
        BEST_SUBNET=""
        BEST_IPS=0
        
        while IFS=$'\t' read -r sid ips az; do
            # Find route table: explicit association first, then main
            RT=$(aws ec2 describe-route-tables \
                --region "$AWS_REGION" \
                --filters "Name=association.subnet-id,Values=$sid" \
                --query 'RouteTables[0].RouteTableId' \
                --output text 2>/dev/null || echo "None")
            
            if [[ -z "$RT" || "$RT" == "None" ]]; then
                RT="$MAIN_RT"
            fi
            
            if [[ -z "$RT" || "$RT" == "None" ]]; then
                log_info "  Subnet $sid ($az): no route table found, skipping"
                continue
            fi
            
            # Check for 0.0.0.0/0 -> igw-*
            IGW_ROUTE=$(aws ec2 describe-route-tables \
                --region "$AWS_REGION" \
                --route-table-ids "$RT" \
                --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" \
                --output text 2>/dev/null || echo "")
            
            if [[ "$IGW_ROUTE" == igw-* ]]; then
                log_info "  Subnet $sid ($az): public (IGW route via $RT, $ips IPs)"
                if [[ $ips -gt $BEST_IPS ]]; then
                    BEST_SUBNET="$sid"
                    BEST_IPS=$ips
                fi
            else
                log_info "  Subnet $sid ($az): no IGW default route (rt=$RT), skipping"
            fi
        done <<< "$CANDIDATE_SUBNETS"
        
        if [[ -z "$BEST_SUBNET" ]]; then
            log_error "No truly public subnet found in VPC $VPC_ID."
            log_error "A public subnet needs: MapPublicIpOnLaunch=true AND a 0.0.0.0/0 route to an igw-*."
            log_error "Candidate subnets checked:"
            echo "$CANDIDATE_SUBNETS" | while IFS=$'\t' read -r sid ips az; do
                log_error "  $sid  IPs=$ips  AZ=$az  MapPublic=true  (missing IGW route)"
            done
            die "Set SUBNET_ID explicitly to a known public subnet."
        fi
        
        SUBNET_ID="$BEST_SUBNET"
        log_info "Auto-selected public subnet: $SUBNET_ID (VPC: $VPC_ID, available IPs: $BEST_IPS)"
    fi
    
    # Auto-create temporary security group if not set
    if [[ -z "$SG_ID" && $AUTO_CREATE_SG -eq 1 ]]; then
        log_info "Auto-creating temporary security group..."
        
        # Get VPC ID (already found above, or find it now)
        if [[ -z "${VPC_ID:-}" ]]; then
            VPC_ID=$(aws ec2 describe-vpcs \
                --region "$AWS_REGION" \
                --filters "Name=isDefault,Values=true" \
                --query 'Vpcs[0].VpcId' \
                --output text 2>/dev/null || echo "")
        fi
        
        if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
            die "Cannot create SG: no default VPC found."
        fi
        
        # Create SG
        SG_ID=$(aws ec2 create-security-group \
            --region "$AWS_REGION" \
            --group-name "scrna-driver-ssh-$RUN_ID" \
            --description "scrna serverless driver ssh (temporary)" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' \
            --output text 2>/dev/null || echo "")
        
        if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
            die "Failed to create security group."
        fi
        
        CREATED_SG_ID="$SG_ID"
        log_info "Created temporary security group: $SG_ID"
        
        # Tag it
        aws ec2 create-tags \
            --region "$AWS_REGION" \
            --resources "$SG_ID" \
            --tags "Key=Name,Value=scrna-driver-ssh-$RUN_ID" 2>/dev/null || true
    fi
    
    # Validate driver mode requirements
    [[ -n "$SEED_AMI_ID" ]] || die "SEED_AMI_ID must be set (use AUTO_DETECT_SEED_AMI=1 or set it explicitly)"
    if [[ "$USE_SSM" == "0" ]]; then
        [[ -n "$KEY_NAME" ]] || die "KEY_NAME must be set in driver mode (or set USE_SSM=auto|1)"
        [[ -n "$KEY_PEM_PATH" ]] || die "KEY_PEM_PATH must be set in driver mode (or set USE_SSM=auto|1)"
        [[ -f "$KEY_PEM_PATH" ]] || die "KEY_PEM_PATH does not exist: $KEY_PEM_PATH"
    fi
    [[ -n "$SUBNET_ID" ]] || die "SUBNET_ID must be set (use AUTO_PICK_SUBNET=1 or set it explicitly)"
    [[ -n "$SG_ID" ]] || die "SG_ID must be set (use AUTO_CREATE_SG=1 or set it explicitly)"
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
        
        # Build key-name args (optional when using SSM)
        KEY_NAME_ARGS=()
        if [[ -n "$KEY_NAME" ]]; then
            KEY_NAME_ARGS=(--key-name "$KEY_NAME")
        fi
        
        # Instance type fallback: try requested type first, then progressively smaller
        # alternatives if launch fails due to vCPU quota or capacity issues.
        # Chain: m6id (NVMe, best perf) → m6i (EBS-only) → t3 (burstable, free-tier accounts)
        INSTANCE_FALLBACKS=("$INSTANCE_TYPE")
        if [[ "$INSTANCE_TYPE" == "m6id.16xlarge" ]]; then
            INSTANCE_FALLBACKS+=("m6id.8xlarge" "m6id.4xlarge" "m6id.xlarge" "m6i.xlarge" "t3.2xlarge" "t3.xlarge" "t3.large" "t3.medium" "t3.small" "t3.micro")
        fi
        
        DRIVER_INSTANCE_ID=""
        for _try_type in "${INSTANCE_FALLBACKS[@]}"; do
            log_info "Attempting instance type: $_try_type"
            _launch_err=$(mktemp)
            if DRIVER_INSTANCE_ID=$(MSYS2_ARG_CONV_EXCL="*" MSYS_NO_PATHCONV=1 \
                aws ec2 run-instances \
                --region "$AWS_REGION" \
                --image-id "$SEED_AMI_ID" \
                --instance-type "$_try_type" \
                "${KEY_NAME_ARGS[@]}" \
                --subnet-id "$SUBNET_ID" \
                --security-group-ids "$SG_ID" \
                "${IAM_PROFILE_ARGS[@]}" \
                --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_VOL_GB,VolumeType=gp3}" \
                --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=scrna-e2e-$RUN_ID}]" \
                --query "Instances[0].InstanceId" \
                --output text 2>"$_launch_err"); then
                rm -f "$_launch_err"
                INSTANCE_TYPE="$_try_type"
                break
            fi
            _err_msg=$(cat "$_launch_err" 2>/dev/null); rm -f "$_launch_err"
            if [[ "$_err_msg" == *"VcpuLimitExceeded"* || "$_err_msg" == *"InsufficientInstanceCapacity"* || "$_err_msg" == *"InstanceLimitExceeded"* || "$_err_msg" == *"Unsupported"* ]]; then
                log_warn "Instance type $_try_type unavailable: ${_err_msg##*:}"
                DRIVER_INSTANCE_ID=""
                continue
            fi
            die "Failed to launch EC2 instance ($_try_type): $_err_msg"
        done
        
        [[ -n "$DRIVER_INSTANCE_ID" ]] || die "All instance types exhausted (tried: ${INSTANCE_FALLBACKS[*]}). Request a vCPU quota increase in AWS Service Quotas."
    
        log_info "Instance launched: $DRIVER_INSTANCE_ID (type: $INSTANCE_TYPE)"
        
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
    
    if [[ -z "$DRIVER_INSTANCE_IP" || "$DRIVER_INSTANCE_IP" == "None" ]]; then
        log_warn "Instance has no public IP (may be expected for SSM-only mode)."
        DRIVER_INSTANCE_IP=""
    else
        log_info "Instance IP: $DRIVER_INSTANCE_IP"
    fi
    
    # Auto-authorize caller IP for SSH (only when SSH might be used)
    CALLER_IP_TO_REVOKE=""
    if [[ "$USE_SSM" != "1" && $AUTO_SSH_INGRESS -eq 1 && -n "$DRIVER_INSTANCE_IP" ]]; then
        CALLER_IP=$(get_caller_public_ip)
        if [[ -n "$CALLER_IP" ]]; then
            manage_sg_ingress authorize "$CALLER_IP"
            CALLER_IP_TO_REVOKE="$CALLER_IP"
        else
            log_info "Could not detect caller IP; skipping SG ingress"
        fi
    fi
    
    # Wait for EC2 status checks (not just "running")
    log_info "Waiting for EC2 status checks (instance-status-ok)..."
    aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$DRIVER_INSTANCE_ID"
    
    ############################################################################
    # Determine connection method: ssh or ssm
    ############################################################################
    CONNECT_METHOD=""
    SSH_OPTS=()
    
    if [[ "$USE_SSM" == "1" ]]; then
        CONNECT_METHOD="ssm"
        log_info "USE_SSM=1: using SSM exclusively (no SSH)."
    else
        # Build SSH options (needed for both USE_SSM=0 and auto)
        if [[ -n "$KEY_PEM_PATH" && -f "$KEY_PEM_PATH" ]]; then
            SSH_OPTS=(
                -o StrictHostKeyChecking=no
                -o UserKnownHostsFile=/dev/null
                -o BatchMode=yes
                -o IdentitiesOnly=yes
                -o ConnectTimeout=10
                -o ServerAliveInterval=5
                -o ServerAliveCountMax=2
                -i "$KEY_PEM_PATH"
            )
        fi
        
        # Try SSH_USER first, then fallback candidates
        SSH_USER_CANDIDATES=("$SSH_USER" ubuntu ec2-user admin)
        # Remove duplicates while preserving order
        declare -A _seen_user; _deduped_users=()
        for u in "${SSH_USER_CANDIDATES[@]}"; do
            if [[ -z "${_seen_user[$u]:-}" ]]; then
                _deduped_users+=("$u")
                _seen_user[$u]=1
            fi
        done
        SSH_USER_CANDIDATES=("${_deduped_users[@]}")
        unset _seen_user _deduped_users
        
        if [[ "$USE_SSM" == "0" ]]; then
            # SSH only — full 60-iteration retry
            log_info "Waiting for SSH readiness (USE_SSM=0)..."
            SSH_READY=0
            for i in $(seq 1 60); do
                for try_user in "${SSH_USER_CANDIDATES[@]}"; do
                    if ssh "${SSH_OPTS[@]}" "${try_user}@$DRIVER_INSTANCE_IP" "echo OK" >/dev/null 2>&1; then
                        SSH_USER="$try_user"
                        SSH_READY=1
                        break 2
                    fi
                done
                sleep 5
            done
            
            if [[ "$SSH_READY" -ne 1 ]]; then
                log_error "========== SSH DIAGNOSTICS =========="
                log_error "SSH never became reachable on $DRIVER_INSTANCE_IP:22 (instance $DRIVER_INSTANCE_ID)."
                log_error "Tried users: ${SSH_USER_CANDIDATES[*]}"
                log_error ""
                log_error "PEM path (resolved in bash): $KEY_PEM_PATH"
                ls -l "$KEY_PEM_PATH" >&2 2>/dev/null || log_error "  File NOT FOUND at that path inside bash"
                log_error ""
                log_error "Running one verbose SSH attempt for diagnostics..."
                SSH_DEBUG_LOG="ssh_debug_${RUN_ID}.log"
                ssh -vvv "${SSH_OPTS[@]}" "${SSH_USER}@$DRIVER_INSTANCE_IP" "echo OK" >"$SSH_DEBUG_LOG" 2>&1 || true
                log_error "Full debug log saved to: $SSH_DEBUG_LOG"
                log_error "--- Last 60 lines ---"
                tail -60 "$SSH_DEBUG_LOG" >&2 2>/dev/null || true
                log_error "--- End debug log ---"
                log_error ""
                log_error "To test manually from PowerShell:"
                log_error '  ssh -i $env:KEY_PEM_PATH -o StrictHostKeyChecking=no ubuntu@'"$DRIVER_INSTANCE_IP" '"echo OK"'
                log_error ""
                log_error "Instance KeyName:"
                aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$DRIVER_INSTANCE_ID" \
                  --query 'Reservations[0].Instances[0].KeyName' --output text 2>/dev/null >&2 || true
                log_error ""
                log_error "Security Group: $SG_ID"
                log_error "SG inbound rules for tcp/22:"
                aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SG_ID" \
                  --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\` && ToPort==\`22\`]" \
                  --output json 2>/dev/null >&2 || true
                log_error ""
                log_error "Most common causes: wrong keypair/PEM mismatch, SG inbound 22 wrong IP, subnet not public, or your network blocks outbound 22."
                log_error "TIP: Set USE_SSM=auto or USE_SSM=1 to bypass SSH and use AWS SSM instead."
                die "Cannot SSH to driver instance."
            fi
            CONNECT_METHOD="ssh"
        else
            # USE_SSM=auto — try SSH briefly (~30s), then fall back to SSM
            log_info "USE_SSM=auto: trying SSH for ~30s..."
            SSH_READY=0
            # Use a shorter ConnectTimeout for the auto-probe to avoid long waits
            _probe_opts=()
            for _o in "${SSH_OPTS[@]}"; do
                [[ "$_o" == "ConnectTimeout="* ]] && continue
                _probe_opts+=("$_o")
            done
            _probe_opts+=(-o ConnectTimeout=3)
            if [[ ${#_probe_opts[@]} -gt 0 && -n "$DRIVER_INSTANCE_IP" ]]; then
                for i in $(seq 1 6); do
                    for try_user in "${SSH_USER_CANDIDATES[@]}"; do
                        if ssh "${_probe_opts[@]}" "${try_user}@$DRIVER_INSTANCE_IP" "echo OK" >/dev/null 2>&1; then
                            SSH_USER="$try_user"
                            SSH_READY=1
                            break 2
                        fi
                    done
                    sleep 3
                done
            fi
            
            if [[ "$SSH_READY" -eq 1 ]]; then
                CONNECT_METHOD="ssh"
                log_info "SSH is ready (user: $SSH_USER) — using SSH."
            else
                CONNECT_METHOD="ssm"
                log_warn "SSH unreachable after ~30s — falling back to SSM."
            fi
        fi
    fi
    
    # If using SSM, wait for the instance to register with SSM
    SSM_TRANSFER_BUCKET=""
    if [[ "$CONNECT_METHOD" == "ssm" ]]; then
        ssm_wait_for_managed "$DRIVER_INSTANCE_ID"
        
        # Get AWS account ID for SSM transfer bucket
        if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
            AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        fi
        SSM_TRANSFER_BUCKET="scrna-ssm-xfer-${AWS_ACCOUNT_ID}-${AWS_REGION}"
        aws s3 mb "s3://${SSM_TRANSFER_BUCKET}" --region "$AWS_REGION" 2>/dev/null || true
    else
        log_info "SSH is ready (user: $SSH_USER)"
    fi
    
    ############################################################################
    # Transfer repository to instance
    ############################################################################
    log_info "Copying repository to instance..."
    REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    TARBALL_LOCAL="/tmp/scrna-repo-${RUN_ID}.tar.gz"
    
    tar -czf "$TARBALL_LOCAL" -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")"
    
    if [[ "$CONNECT_METHOD" == "ssh" ]]; then
        TARBALL_REMOTE="/tmp/scrna-repo-${RUN_ID}.tar.gz"
        scp "${SSH_OPTS[@]}" "$TARBALL_LOCAL" "${SSH_USER}@$DRIVER_INSTANCE_IP:$TARBALL_REMOTE"
        rm -f "$TARBALL_LOCAL"
        
        log_info "Extracting repository on instance..."
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@$DRIVER_INSTANCE_IP" \
            "rm -rf /home/${SSH_USER}/scrna-repo && cd /tmp && tar -xzf scrna-repo-${RUN_ID}.tar.gz && mv scRNA-serverless /home/${SSH_USER}/scrna-repo && rm -f ${TARBALL_REMOTE} && find /home/${SSH_USER}/scrna-repo -name '*.sh' -exec sed -i 's/\r$//' {} +"
    else
        # SSM: transfer via S3
        TARBALL_S3_KEY="transfer/${RUN_ID}/repo.tar.gz"
        aws s3 cp "$TARBALL_LOCAL" "s3://${SSM_TRANSFER_BUCKET}/${TARBALL_S3_KEY}" \
            --region "$AWS_REGION" --only-show-errors
        rm -f "$TARBALL_LOCAL"
        log_info "Repo uploaded to s3://${SSM_TRANSFER_BUCKET}/${TARBALL_S3_KEY}"

        # Ensure AWS CLI v2 is available on the instance (the AMI may not have it)
        log_info "Ensuring AWS CLI v2 is installed on instance via SSM..."
        ssm_run_command "$DRIVER_INSTANCE_ID" \
            "if command -v aws >/dev/null 2>&1; then aws --version; exit 0; fi; for i in \$(seq 1 30); do fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break; echo waiting for dpkg lock \$i/30; sleep 10; done; apt-get update -qq && apt-get install -y -qq unzip curl && curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip && cd /tmp && unzip -qo awscliv2.zip && ./aws/install --update && rm -rf /tmp/awscliv2.zip /tmp/aws && echo AWS_CLI_INSTALLED" \
            600

        log_info "Downloading and extracting repo on instance via SSM..."
        ssm_run_command "$DRIVER_INSTANCE_ID" \
            "aws s3 cp s3://${SSM_TRANSFER_BUCKET}/${TARBALL_S3_KEY} /tmp/repo.tar.gz --region ${AWS_REGION} && rm -rf /home/${SSH_USER}/scrna-repo && cd /tmp && tar -xzf repo.tar.gz && mv scRNA-serverless /home/${SSH_USER}/scrna-repo && chown -R ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/scrna-repo && find /home/${SSH_USER}/scrna-repo -name '*.sh' -exec sed -i 's/\r$//' {} + && rm -f /tmp/repo.tar.gz" \
            300
    fi
    
    ############################################################################
    # Run pipeline on instance
    ############################################################################
    log_info "Running pipeline in --run mode on instance..."
    
    if [[ "$CONNECT_METHOD" == "ssh" ]]; then
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@$DRIVER_INSTANCE_IP" <<SSHEOF
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
export RUN_QC=$RUN_QC

cd /home/${SSH_USER}/scrna-repo
bash scripts/e2e_serverless_pbmc.sh $DATASET --run
SSHEOF
        RUN_EXIT=$?
    else
        # SSM path
        if ssm_run_pipeline "$DRIVER_INSTANCE_ID" "$DATASET" "$SSM_TRANSFER_BUCKET" "$RUN_ID"; then
            RUN_EXIT=0
        else
            RUN_EXIT=1
        fi
    fi
    
    ############################################################################
    # Download results from EC2 to local machine
    ############################################################################
    if [[ $RUN_EXIT -eq 0 && $DOWNLOAD_RESULTS -eq 1 ]]; then
        log_info "Downloading results from EC2 to local machine..."
        mkdir -p "$LOCAL_RESULTS_DIR/$RUN_ID"
        
        if [[ "$CONNECT_METHOD" == "ssh" ]]; then
            ssh "${SSH_OPTS[@]}" "${SSH_USER}@$DRIVER_INSTANCE_IP" \
                "tar -czf /tmp/${RUN_ID}_results.tgz --exclude='fastq' --exclude='lambda_build' --exclude='venv_qc' -C /mnt/nvme/runs ${RUN_ID}"
            scp "${SSH_OPTS[@]}" \
                "${SSH_USER}@${DRIVER_INSTANCE_IP}:/tmp/${RUN_ID}_results.tgz" "$LOCAL_RESULTS_DIR/$RUN_ID/"
        else
            # SSM: create tarball on instance, upload to S3, download locally
            ssm_run_command "$DRIVER_INSTANCE_ID" \
                "tar -czf /tmp/${RUN_ID}_results.tgz --exclude='fastq' --exclude='lambda_build' --exclude='venv_qc' -C /mnt/nvme/runs ${RUN_ID} && aws s3 cp /tmp/${RUN_ID}_results.tgz s3://${SSM_TRANSFER_BUCKET}/results/${RUN_ID}_results.tgz --region ${AWS_REGION} && rm -f /tmp/${RUN_ID}_results.tgz" \
                600
            aws s3 cp "s3://${SSM_TRANSFER_BUCKET}/results/${RUN_ID}_results.tgz" \
                "$LOCAL_RESULTS_DIR/$RUN_ID/${RUN_ID}_results.tgz" \
                --region "$AWS_REGION" --only-show-errors
        fi
        
        # Extract locally
        log_info "Extracting results to $LOCAL_RESULTS_DIR/$RUN_ID/"
        tar -xzf "$LOCAL_RESULTS_DIR/$RUN_ID/${RUN_ID}_results.tgz" -C "$LOCAL_RESULTS_DIR/$RUN_ID"
        log_info "Results downloaded to: $LOCAL_RESULTS_DIR/$RUN_ID/$RUN_ID/"
    fi
    
    ############################################################################
    # Cleanup (also runs via cleanup_on_exit trap on failure)
    ############################################################################

    if [[ $RUN_EXIT -ne 0 ]]; then
        log_error "Pipeline exited with code $RUN_EXIT.  Cleanup will run via trap."
    fi

    # Normal-path cleanup: revoke SG ingress, then terminate+delete.
    # On failure the trap duplicates this (idempotent AWS calls are safe).
    if [[ -n "${CALLER_IP_TO_REVOKE:-}" ]]; then
        manage_sg_ingress revoke "$CALLER_IP_TO_REVOKE"
    fi
    
    if [[ $TERMINATE_DRIVER_ON_EXIT -eq 1 ]]; then
        log_info "Terminating driver instance $DRIVER_INSTANCE_ID..."
        aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$DRIVER_INSTANCE_ID" >/dev/null 2>&1 || true
        
        log_info "Waiting for instance to terminate..."
        aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$DRIVER_INSTANCE_ID" 2>/dev/null || true
        
        if [[ -n "$CREATED_SG_ID" ]]; then
            log_info "Deleting temporary security group: $CREATED_SG_ID"
            aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$CREATED_SG_ID" 2>/dev/null || log_info "Could not delete SG (may still be in use)"
        fi
        
        if [[ -n "${SSM_TRANSFER_BUCKET:-}" ]]; then
            log_info "Cleaning up SSM transfer bucket: $SSM_TRANSFER_BUCKET"
            aws s3 rm "s3://${SSM_TRANSFER_BUCKET}" --recursive --region "$AWS_REGION" 2>/dev/null || true
            aws s3 rb "s3://${SSM_TRANSFER_BUCKET}" --region "$AWS_REGION" 2>/dev/null || true
        fi

        # Clear DRIVER_INSTANCE_ID so the trap doesn't double-terminate
        DRIVER_INSTANCE_ID=""
        CREATED_SG_ID=""
    else
        log_info "Driver instance $DRIVER_INSTANCE_ID left running (TERMINATE_DRIVER_ON_EXIT=0)"
        log_info "Note: Temporary SG ${CREATED_SG_ID:-} is still in use. Clean it up manually when done."
        # Prevent trap from terminating a kept-alive instance
        DRIVER_INSTANCE_ID=""
    fi
    
    exit $RUN_EXIT
fi

################################################################################
# Mode: Run (Execute pipeline on EC2)
################################################################################

log_info "======== E2E Serverless scRNA Pipeline (RUN MODE) ========"
log_info "Dataset: $DATASET"
log_info "Run ID: $RUN_ID"
log_info "AWS CLI present: $(aws --version 2>&1)"

# Auto-detect AWS account ID if not set
if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
    log_info "Auto-detecting AWS account ID..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    log_info "AWS account ID: $AWS_ACCOUNT_ID"
fi

# Initialize resource names now that AWS_ACCOUNT_ID is known
init_resource_names

# Setup NVMe storage if available
log_info "Setting up NVMe storage..."

MOUNT_POINT="/mnt/nvme"

if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    log_info "$MOUNT_POINT already mounted — reusing"
else
    # Find an NVMe instance-store device (skip devices already mounted, e.g. root EBS on nvme0n1)
    NVMe_DEVICE=""
    while read -r dev; do
        dev_path="/dev/$dev"
        # Skip if this device (or a partition of it) is already mounted
        if mount | grep -q "^${dev_path}"; then
            log_info "Skipping $dev_path (already mounted)"
            continue
        fi
        NVMe_DEVICE="$dev"
        break
    done < <(lsblk -d -n -l -o NAME | grep nvme)

    if [[ -n "$NVMe_DEVICE" ]]; then
        NVMe_PATH="/dev/$NVMe_DEVICE"
        log_info "Found unmounted NVMe device: $NVMe_PATH"
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
        log_info "No unmounted NVMe device found; using default storage"
        sudo mkdir -p "$MOUNT_POINT"
        sudo chown -R ubuntu:ubuntu "$MOUNT_POINT"
    fi
fi

# Create run directory
RUN_DIR="/mnt/nvme/runs/$RUN_ID"
mkdir -p "$RUN_DIR"

log_info "Run directory: $RUN_DIR"

# Timing instrumentation (matching paper Table 1)
declare -A STEP_TIMES
declare -a STEP_ORDER
PIPELINE_START=$(date +%s)

################################################################################
# Step 0: Bootstrap Tools
################################################################################

log_info "Step 0: Bootstrapping tools..."

# Required tools: python3/pip3 only when RUN_QC=1
REQUIRED_TOOLS=(aws docker jq curl tar gzip git)
if [[ "${RUN_QC:-0}" == "1" ]]; then
    REQUIRED_TOOLS+=(python3 pip3)
fi

MISSING_TOOLS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! need_cmd "$tool"; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    log_info "Installing missing tools: ${MISSING_TOOLS[*]}"
    # Wait for any unattended-upgrades / dpkg locks to release (common on fresh Ubuntu instances)
    for _w in $(seq 1 30); do
        if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
           ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            break
        fi
        log_info "Waiting for dpkg/apt lock to release (attempt $_w/30)..."
        sleep 10
    done
    sudo apt-get update
    
    INSTALL_PKGS=()
    for tool in "${MISSING_TOOLS[@]}"; do
        case "$tool" in
            python3) INSTALL_PKGS+=(python3 python3-venv python3-pip) ;;
            pip3) INSTALL_PKGS+=(python3-pip) ;;
            aws)
                log_info "Installing AWS CLI v2..."
                curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
                (cd /tmp && unzip -qo awscliv2.zip && sudo ./aws/install --update 2>&1) >&2
                rm -rf /tmp/awscliv2.zip /tmp/aws
                hash -r
                ;;
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
STEP_START=$(date +%s)

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

# Concatenate all R1 files (use temp file to avoid overwrites)
log_info "Concatenating R1 files..."
tmp_r1="$FASTQ_DIR/${BASENAME_WITH_LANE}_R1_001.fastq.gz.tmp"
cat "${R1_FILES[@]}" > "$tmp_r1"
mv -f "$tmp_r1" "$FASTQ_DIR/${BASENAME_WITH_LANE}_R1_001.fastq.gz"

# Find and concatenate R2 files
R2_FILES=($(find "$FASTQ_DIR" -name "*R2_001.fastq.gz" | sort))
[[ ${#R2_FILES[@]} -gt 0 ]] || die "No R2_001.fastq.gz files found"

# Concatenate all R2 files (use temp file to avoid overwrites)
log_info "Concatenating R2 files..."
tmp_r2="$FASTQ_DIR/${BASENAME_WITH_LANE}_R2_001.fastq.gz.tmp"
cat "${R2_FILES[@]}" > "$tmp_r2"
mv -f "$tmp_r2" "$FASTQ_DIR/${BASENAME_WITH_LANE}_R2_001.fastq.gz"

log_info "FASTQ files ready"

STEP_END=$(date +%s); STEP_ELAPSED=$((STEP_END - STEP_START))
STEP_TIMES["FASTQ Download"]=$STEP_ELAPSED; STEP_ORDER+=("FASTQ Download")
log_info "Step 1 completed in ${STEP_ELAPSED}s ($((STEP_ELAPSED/60))m $((STEP_ELAPSED%60))s)"

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
STEP_START=$(date +%s)

aws s3 cp "$FASTQ_DIR/${BASENAME_WITH_LANE}_R1_001.fastq.gz" \
    "s3://$INPUT_FASTQ_BUCKET/$DATASET/${BASENAME_WITH_LANE}_R1_001.fastq.gz" \
    --region "$AWS_REGION"

aws s3 cp "$FASTQ_DIR/${BASENAME_WITH_LANE}_R2_001.fastq.gz" \
    "s3://$INPUT_FASTQ_BUCKET/$DATASET/${BASENAME_WITH_LANE}_R2_001.fastq.gz" \
    --region "$AWS_REGION"

log_info "FASTQs uploaded"

STEP_END=$(date +%s); STEP_ELAPSED=$((STEP_END - STEP_START))
STEP_TIMES["FASTQ Upload to S3"]=$STEP_ELAPSED; STEP_ORDER+=("FASTQ Upload to S3")
log_info "Step 3 completed in ${STEP_ELAPSED}s ($((STEP_ELAPSED/60))m $((STEP_ELAPSED%60))s)"

################################################################################
# Step 5: Prepare Lambda Build Context
################################################################################

log_info "Step 5: Preparing Lambda build context..."
STEP_START=$(date +%s)

BUILD_DIR="$RUN_DIR/lambda_build"
mkdir -p "$BUILD_DIR"

# Copy scrna-pipeline to build context
cp -r /home/ubuntu/scrna-repo/scrna-pipeline/* "$BUILD_DIR/"

# Copy index data to expected location
cp -r /opt/scrna-seed/index_output_transcriptome "$BUILD_DIR/"

# Sanitize Dockerfile: remove lines that COPY AWS credentials
sed -i '/COPY.*aws.*credentials\|COPY.*\.aws\|COPY.*AWS_/d' "$BUILD_DIR/Dockerfile"

log_info "Build context ready"

################################################################################
# Step 6: Setup Lambda and EventBridge (pure bash — no python)
################################################################################

log_info "Step 6: Setting up Lambda function and EventBridge..."

# 6a: Create ECR repository
ECR_REPO_URI=$(create_ecr_repo_if_needed "$ECR_REPO_NAME")

# 6b: Build and push Docker image to ECR
IMAGE_URI=$(build_and_push_lambda_image "$ECR_REPO_URI" "$DOCKER_IMAGE_NAME" "$BUILD_DIR")

STEP_END=$(date +%s); STEP_ELAPSED=$((STEP_END - STEP_START))
STEP_TIMES["Docker Build + Push"]=$STEP_ELAPSED; STEP_ORDER+=("Docker Build + Push")
log_info "Steps 5-6b completed in ${STEP_ELAPSED}s ($((STEP_ELAPSED/60))m $((STEP_ELAPSED%60))s)"

# 6c: Create Lambda execution role
LAMBDA_ROLE_ARN=$(create_lambda_execution_role "$LAMBDA_EXECUTION_ROLE_NAME")

# Wait for IAM role propagation (IAM is eventually consistent)
log_info "Waiting 15s for IAM role propagation..."
sleep 15

# 6d: Create Lambda function — try requested memory, fallback to 3008MB if quota exceeded
log_info "Creating Lambda: attempting memory=${LAMBDA_MEMORY_MB}MB, ephemeral=${LAMBDA_EPHEMERAL_MB}MB, timeout=${LAMBDA_TIMEOUT_SEC}s"
_create_rc=0
LAMBDA_FUNCTION_ARN=$(create_lambda_function_from_image \
    "$LAMBDA_FUNCTION_NAME" "$LAMBDA_ROLE_ARN" "$IMAGE_URI" \
    "$LAMBDA_MEMORY_MB" "$LAMBDA_EPHEMERAL_MB" "$LAMBDA_TIMEOUT_SEC") || _create_rc=$?

if [[ $_create_rc -eq 2 ]]; then
    log_info "10,240 MB memory quota exceeded, falling back to 3008 MB"
    LAMBDA_MEMORY_MB=3008
    LAMBDA_FUNCTION_ARN=$(create_lambda_function_from_image \
        "$LAMBDA_FUNCTION_NAME" "$LAMBDA_ROLE_ARN" "$IMAGE_URI" \
        "$LAMBDA_MEMORY_MB" "$LAMBDA_EPHEMERAL_MB" "$LAMBDA_TIMEOUT_SEC") \
        || die "Failed to create Lambda (memory=${LAMBDA_MEMORY_MB}MB). Check account limits."
elif [[ $_create_rc -ne 0 ]]; then
    die "Failed to create Lambda (memory=${LAMBDA_MEMORY_MB}MB, ephemeral=${LAMBDA_EPHEMERAL_MB}MB). Check account limits."
fi
log_info "Lambda created successfully: memory=${LAMBDA_MEMORY_MB}MB, ephemeral=${LAMBDA_EPHEMERAL_MB}MB"
log_info "LAMBDA_EFFECTIVE_MEMORY_MB=${LAMBDA_MEMORY_MB}"

# Wait for Lambda function to be active
log_info "Waiting for Lambda function to be active..."
aws lambda wait function-active-v2 --function-name "$LAMBDA_FUNCTION_NAME" --region "$AWS_REGION" 2>/dev/null \
    || aws lambda wait function-updated --function-name "$LAMBDA_FUNCTION_NAME" --region "$AWS_REGION" 2>/dev/null \
    || sleep 10

# 6e: Create EventBridge rule to trigger Lambda
RULE_NAME="${LAMBDA_FUNCTION_NAME}-rule"
create_eventbridge_rule_for_lambda "$RULE_NAME" "$LAMBDA_FUNCTION_ARN" "$INPUT_TXT_BUCKET"

# Wait for EventBridge propagation (matches original set-up-resources.py sleep 30)
log_info "Waiting 30s for EventBridge propagation..."
sleep 30

# Log resource summary
log_info "========== RESOURCE SUMMARY =========="
log_info "  ECR Repository:      $ECR_REPO_NAME"
log_info "  Lambda Function:     $LAMBDA_FUNCTION_NAME"
log_info "  Lambda Memory:       ${LAMBDA_MEMORY_MB}MB"
log_info "  Lambda Ephemeral:    ${LAMBDA_EPHEMERAL_MB}MB"
log_info "  Lambda Timeout:      ${LAMBDA_TIMEOUT_SEC}s"
log_info "  Lambda Role:         $LAMBDA_EXECUTION_ROLE_NAME"
log_info "  EventBridge Rule:    $RULE_NAME"
log_info "  Input FASTQ Bucket:  $INPUT_FASTQ_BUCKET"
log_info "  Input TXT Bucket:    $INPUT_TXT_BUCKET"
log_info "  Output MAP Bucket:   $OUTPUT_MAP_BUCKET"
log_info "  Output Quant Bucket: $OUTPUT_QUANT_BUCKET"
log_info "======================================="

log_info "Lambda function ready"

################################################################################
# Step 7: Process FASTQs (split, upload, wait for Lambda, download) — pure bash
################################################################################

log_info "Step 7: Processing FASTQs with Lambda (split, upload, wait, download)..."
STEP_START=$(date +%s)

OUTPUT_DIR="$RUN_DIR/output"
mkdir -p "$OUTPUT_DIR"

process_fastq_bash "$OUTPUT_DIR"

STEP_END=$(date +%s); STEP_ELAPSED=$((STEP_END - STEP_START))
STEP_TIMES["Lambda Mapping"]=$STEP_ELAPSED; STEP_ORDER+=("Lambda Mapping")
log_info "Step 7 completed in ${STEP_ELAPSED}s ($((STEP_ELAPSED/60))m $((STEP_ELAPSED%60))s)"

log_info "Lambda processing complete, outputs downloaded to $OUTPUT_DIR"

################################################################################
# Step 8: Combine and Quantify
################################################################################

log_info "Step 8: Installing tools and running combine + alevin-fry quant..."

# Increase file descriptor limit for combine scripts
ulimit -n 2048

bash /home/ubuntu/scrna-repo/install_scripts/install_alevin_fry.sh
bash /home/ubuntu/scrna-repo/install_scripts/install_radtk.sh

log_info "Running combine scripts..."
STEP_START=$(date +%s)

COMBINED_DIR="$RUN_DIR/combined"
mkdir -p "$COMBINED_DIR"

bash /home/ubuntu/scrna-repo/combine_map_rad.sh "$OUTPUT_DIR" "$COMBINED_DIR"
bash /home/ubuntu/scrna-repo/combine_unmapped_bc_count_bin.sh "$OUTPUT_DIR" "$COMBINED_DIR"

STEP_END=$(date +%s); STEP_ELAPSED=$((STEP_END - STEP_START))
STEP_TIMES["Combine Outputs"]=$STEP_ELAPSED; STEP_ORDER+=("Combine Outputs")
log_info "Step 8a (combine) completed in ${STEP_ELAPSED}s ($((STEP_ELAPSED/60))m $((STEP_ELAPSED%60))s)"

log_info "Running alevin-fry quant via alevin_process.sh..."
STEP_START=$(date +%s)

ALEVIN_OUTPUT="$RUN_DIR/alevin_output"
mkdir -p "$ALEVIN_OUTPUT"

TRANSCRIPTOME_GENE_MAPPING="/opt/scrna-seed/reference/t2g.tsv"

bash /home/ubuntu/scrna-repo/alevin_process.sh "$COMBINED_DIR" "$ALEVIN_OUTPUT" "$TRANSCRIPTOME_GENE_MAPPING"

STEP_END=$(date +%s); STEP_ELAPSED=$((STEP_END - STEP_START))
STEP_TIMES["Alevin-fry Quant"]=$STEP_ELAPSED; STEP_ORDER+=("Alevin-fry Quant")
log_info "Step 8b (quant) completed in ${STEP_ELAPSED}s ($((STEP_ELAPSED/60))m $((STEP_ELAPSED%60))s)"

log_info "Quantification complete"

################################################################################
# Step 9: Upload Quant Outputs
################################################################################

log_info "Step 9: Uploading quantification outputs to S3..."
STEP_START=$(date +%s)

aws s3 sync "$ALEVIN_OUTPUT" "s3://$OUTPUT_QUANT_BUCKET/$RUN_ID/alevin_output/" \
    --region "$AWS_REGION"

STEP_END=$(date +%s); STEP_ELAPSED=$((STEP_END - STEP_START))
STEP_TIMES["Upload Quant to S3"]=$STEP_ELAPSED; STEP_ORDER+=("Upload Quant to S3")
log_info "Step 9 completed in ${STEP_ELAPSED}s ($((STEP_ELAPSED/60))m $((STEP_ELAPSED%60))s)"

log_info "Quant outputs uploaded"

################################################################################
# Step 10: Optional QC Analysis (ONLY step requiring python)
################################################################################

if [[ "${RUN_QC:-0}" == "1" ]]; then
    log_info "Step 10: Running QC analysis (requires python3)..."

    _qc_ok=true

    # Ensure python3 + venv are available
    if ! need_cmd python3 || ! python3 -c "import ensurepip" 2>/dev/null; then
        log_info "Installing python3/venv for QC..."
        for _w in $(seq 1 30); do
            if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then break; fi
            log_info "Waiting for dpkg lock ($_w/30)..."; sleep 10
        done
        if ! { sudo apt-get update -qq && sudo apt-get install -y -qq python3 python3-venv python3-pip; }; then
            log_warn "Failed to install python3-venv (non-fatal). Skipping QC."
            _qc_ok=false
        fi
    fi

    if $_qc_ok; then
        QC_DIR="$RUN_DIR/analysis"
        mkdir -p "$QC_DIR/out"

        _qc_rc=0
        (
            set -e
            python3 -m venv "$RUN_DIR/venv_qc"
            source "$RUN_DIR/venv_qc/bin/activate"

            python -m pip install -q --upgrade pip setuptools wheel
            pip install -q numpy pandas scipy matplotlib seaborn anndata scanpy python-igraph leidenalg

            QC_ARGS=("$ALEVIN_OUTPUT" "--outdir" "$QC_DIR/out")
            if [[ $WRITE_H5AD -eq 1 ]]; then
                QC_ARGS+=("--write-h5ad")
            fi

            python scripts/qc_serverless.py "${QC_ARGS[@]}"
        ) || _qc_rc=$?

        if [[ $_qc_rc -eq 0 ]]; then
            log_info "QC analysis complete"
        else
            log_warn "QC step failed with exit code $_qc_rc (non-fatal). Pipeline continues."
        fi
    fi
else
    log_info "Step 10: Skipping QC (RUN_QC=0). No python required."
fi

################################################################################
# Step 11: Save Run Metadata
################################################################################

log_info "Step 11: Saving run metadata..."

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
LAMBDA_MEMORY_MB=$LAMBDA_MEMORY_MB
LAMBDA_EPHEMERAL_MB=$LAMBDA_EPHEMERAL_MB
LAMBDA_TIMEOUT_SEC=$LAMBDA_TIMEOUT_SEC
RUN_DIR=$RUN_DIR
BASENAME_WITH_LANE=$BASENAME_WITH_LANE
EOF

log_info "Run metadata saved to $RUN_DIR/run.env"

################################################################################
# Timing Summary
################################################################################

PIPELINE_END=$(date +%s)
PIPELINE_TOTAL=$((PIPELINE_END - PIPELINE_START))

DATASET_UPPER=$(echo "$DATASET" | tr '[:lower:]' '[:upper:]')

{
    echo ""
    echo "========== SERVERLESS TIMING SUMMARY ($DATASET_UPPER) =========="
    printf "%-30s %15s %10s\n" "Step" "Time (seconds)" "Time (min)"
    echo "-----------------------------------------------------------"
    for key in "${STEP_ORDER[@]}"; do
        val="${STEP_TIMES[$key]}"
        mins=$(echo "scale=2; $val / 60" | bc 2>/dev/null || echo "$((val/60)).$((val%60))")
        printf "%-30s %15s %10s\n" "$key" "$val" "$mins"
    done
    echo "-----------------------------------------------------------"
    total_mins=$(echo "scale=2; $PIPELINE_TOTAL / 60" | bc 2>/dev/null || echo "$((PIPELINE_TOTAL/60)).$((PIPELINE_TOTAL%60))")
    printf "%-30s %15s %10s\n" "Total Pipeline" "$PIPELINE_TOTAL" "$total_mins"
    echo "==========================================================="
    echo ""
} | tee "$RUN_DIR/timing_summary.txt" >&2

################################################################################
# Cleanup
################################################################################

log_info "Step 12: Cleanup..."

if [[ $CLEANUP_AWS -eq 1 ]]; then
    log_info "Cleaning up AWS resources..."
    
    # Get Lambda ARN before deleting (needed for EventBridge rule discovery)
    LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" \
        --region "$AWS_REGION" --query 'Configuration.FunctionArn' --output text 2>/dev/null || echo "")
    
    # Delete Lambda function
    aws lambda delete-function --function-name "$LAMBDA_FUNCTION_NAME" \
        --region "$AWS_REGION" 2>/dev/null || true
    
    # Delete Lambda CloudWatch log group
    aws logs delete-log-group --log-group-name "/aws/lambda/$LAMBDA_FUNCTION_NAME" \
        --region "$AWS_REGION" 2>/dev/null || true
    
    # Delete EventBridge rules targeting this Lambda (discover rules dynamically)
    log_info "Discovering EventBridge rules targeting Lambda..."
    
    if [[ -n "$LAMBDA_ARN" && "$LAMBDA_ARN" != "None" ]]; then
        RULES=$(aws events list-rule-names-by-target --target-arn "$LAMBDA_ARN" \
            --region "$AWS_REGION" --query 'RuleNames[]' --output text 2>/dev/null || echo "")
        
        if [[ -n "$RULES" ]]; then
            for rule in $RULES; do
                log_info "Removing targets from rule: $rule"
                # List and remove all targets from the rule
                TARGETS=$(aws events list-targets-by-rule --rule "$rule" \
                    --region "$AWS_REGION" --query 'Targets[].Id' --output text 2>/dev/null || echo "")
                
                if [[ -n "$TARGETS" ]]; then
                    aws events remove-targets --rule "$rule" --ids $TARGETS \
                        --region "$AWS_REGION" 2>/dev/null || true
                fi
                
                # Delete the rule
                log_info "Deleting rule: $rule"
                aws events delete-rule --name "$rule" --region "$AWS_REGION" 2>/dev/null || true
            done
        fi
    fi
    
    # Also delete the known rule name directly
    aws events remove-targets --rule "${LAMBDA_FUNCTION_NAME}-rule" --ids "LambdaTarget" \
        --region "$AWS_REGION" 2>/dev/null || true
    aws events delete-rule --name "${LAMBDA_FUNCTION_NAME}-rule" --region "$AWS_REGION" 2>/dev/null || true
    
    # Delete IAM execution role (detach all policies first)
    # Detach managed policies
    aws iam list-attached-role-policies --role-name "$LAMBDA_EXECUTION_ROLE_NAME" \
        --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | \
        tr '\t' '\n' | while read -r policy_arn; do
            if [[ -n "$policy_arn" ]]; then
                aws iam detach-role-policy --role-name "$LAMBDA_EXECUTION_ROLE_NAME" \
                    --policy-arn "$policy_arn" 2>/dev/null || true
            fi
        done
    
    # Delete inline policies
    aws iam list-role-policies --role-name "$LAMBDA_EXECUTION_ROLE_NAME" \
        --query 'PolicyNames[]' --output text 2>/dev/null | \
        tr '\t' '\n' | while read -r policy_name; do
            if [[ -n "$policy_name" ]]; then
                aws iam delete-role-policy --role-name "$LAMBDA_EXECUTION_ROLE_NAME" \
                    --policy-name "$policy_name" 2>/dev/null || true
            fi
        done
    
    # Finally delete the role
    aws iam delete-role --role-name "$LAMBDA_EXECUTION_ROLE_NAME" 2>/dev/null || true
    
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

if [[ "${RUN_QC:-0}" == "1" ]]; then
    log_info "QC plots: $RUN_DIR/analysis/out/"
    if [[ $WRITE_H5AD -eq 1 ]]; then
        log_info "H5AD file: $RUN_DIR/analysis/out/pbmc_adata.h5ad"
    fi
fi

log_info "Run.env: $RUN_DIR/run.env"

exit 0
