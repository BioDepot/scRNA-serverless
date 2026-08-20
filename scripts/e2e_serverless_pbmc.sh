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
#   bash scripts/e2e_serverless_pbmc.sh ko
#
# Split and Upload apportions CPUs across all active R1/R2 gzip streams. It
# uses rapidgzip with at most 8 threads per stream when more than one CPU is
# available per file, and gzip with one worker per file otherwise.
# If two or more NVMe instance-store disks are present they are striped as
# RAID 0 at /mnt/nvme.
#
#   # Run mode (on EC2 instance):
#   bash scripts/e2e_serverless_pbmc.sh pbmc1k --run
#
# ENVIRONMENT VARIABLES (set before calling):
#   SEED_AMI_ID            Required in driver mode. AMI with pre-installed reference data.
#   AWS_REGION             AWS region (default: us-east-2)
#   INSTANCE_TYPE          EC2 instance type (default: m5dn.8xlarge)
#   ROOT_VOL_GB            EBS root volume size in GB (default: 500)
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
#   LAMBDA_CONCURRENCY     Max concurrent Lambda invocations (default: 1000, fallback: 500→100→10). Set 0 for unrestricted.
#   THREADS                Number of CPU threads (default: nproc)
#   ALLOW_DESTRUCTIVE_CLEANUP Master cleanup gate (default: 0). No AWS cleanup
#                          runs unless this and the specific cleanup flag are 1.
#   ALLOW_S3_DELETE        Additional S3 deletion gate (default: 0).
#   CLEANUP_AWS            Clean up AWS infrastructure after pipeline (default: 0).
#   CLEANUP_RESULTS        Delete results S3 bucket after pipeline (default: 0).
#   DELETE_CLOUDWATCH_LOGS Delete Lambda CloudWatch log groups (default: 0).
#   SKIP_PREFLIGHT_CLEANUP Skip removal of stale scrna resources (default: 1).
#   TERMINATE_DRIVER_ON_EXIT  Terminate EC2 instance on exit (default: 1)
#   DOWNLOAD_TO_LOCAL      Download results from EC2 to local machine (default: 1). Alias for DOWNLOAD_RESULTS.
#   RUN_QC                 Run QC analysis on outputs (default: 1). ONLY step requiring python.
#   READ_PAIRS_PER_SHARD   Target read pairs per Lambda shard (default: 4000000;
#                          8000000 on accounts limited to <=25 concurrent Lambdas).
#   SPLIT_LINES            Legacy override; must equal read pairs per shard * 4.
#   DIRECT_GZIP_MAX_BYTES  Pass a compressed R1/R2 pair directly to Lambda when
#                          its combined size is below this value (default: 1 GiB).
#   USE_RAPIDGZIP          auto/1 enables CPU-aware rapidgzip selection (default:
#                          auto); 0 forces single-threaded gzip workers.
#   MATERIALIZER_THREADS   Concurrent S3 RAD materializer workers (default: 32).
#   EXECUTION_MODE         synchronous (default) or async-submit. The latter
#                          exits after publishing all immediate shard triggers.
#
#   LOCAL_FASTQ_DIR        Optional: directory of already-extracted .fastq.gz
#                          files on the instance. rapidgzip reads these directly.
#   FASTQ_TAR_PATH         Optional: path to local FASTQ tar file on instance.
#   FASTQ_TAR_URL          Optional: direct URL to FASTQ tar. Auto-set by DATASET if empty.
#   WRITE_H5AD             Save h5ad output from QC (default: 1). Only matters if RUN_QC=1.
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

# Development-run safety guard. The account contains expensive-to-rebuild S3
# inputs (including the ENA-backed KO cache). Cleanup requires a master opt-in,
# and S3 deletion requires a second opt-in. Keep blocked requests visible.
s3_delete_disabled() {
    if [[ "${ALLOW_DESTRUCTIVE_CLEANUP:-0}" != "1" || "${ALLOW_S3_DELETE:-0}" != "1" ]]; then
        echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') S3 deletion gated: aws s3 $*" >&2
        return 0
    fi
    aws s3 "$@"
}

delete_lambda_log_group() {
    local function_name="$1"
    local region="$2"
    if [[ "${ALLOW_DESTRUCTIVE_CLEANUP:-0}" != "1" || "${DELETE_CLOUDWATCH_LOGS:-0}" != "1" ]]; then
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Keeping CloudWatch log group: /aws/lambda/$function_name" >&2
        return 0
    fi
    aws logs delete-log-group --log-group-name "/aws/lambda/$function_name" \
        --region "$region" 2>/dev/null || true
}

# Cleanup temp files on exit (safe under set -u)
# Cleanup function — called automatically on EXIT/INT/TERM.
# Ensures ALL AWS resources created by this script are cleaned up if the
# script fails, is interrupted (Ctrl+C), or exits at any point.
cleanup_on_exit() {
    local exit_code=$?
    local _region="${AWS_REGION:-us-east-2}"

    [[ -n "${FASTQ_DIR:-}" ]] && rm -f "${FASTQ_DIR}"/*.tmp 2>/dev/null || true
    rm -f "${BASH_SOURCE[0]:+$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)}/scrna-repo-"*.tar.gz 2>/dev/null || true

    if [[ "${RUN_MODE:-0}" -ne 0 ]]; then return; fi

    if [[ "${ALLOW_DESTRUCTIVE_CLEANUP:-0}" != "1" ]]; then
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Cleanup blocked by ALLOW_DESTRUCTIVE_CLEANUP=0." >&2
        return
    fi

    # On failure: force full cleanup regardless of user settings
    local _force_cleanup=0
    if [[ $exit_code -ne 0 ]]; then
        _force_cleanup=1
        echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') Script failed (exit $exit_code). Forcing full cleanup..." >&2
    fi

    if [[ $_force_cleanup -eq 0 && "${CLEANUP_AWS:-1}" -ne 1 ]]; then return; fi

    local _have_resources=0
    [[ -n "${DRIVER_INSTANCE_ID:-}" && "${DRIVER_INSTANCE_ID:-}" != "None" ]] && _have_resources=1
    [[ -n "${LAMBDA_FUNCTION_NAME:-}" ]] && _have_resources=1
    [[ -n "${INPUT_FASTQ_BUCKET:-}" ]] && _have_resources=1
    [[ $_have_resources -eq 0 ]] && return

    # --- EC2 / SG / SSH ---
    if [[ -n "${CALLER_IP_TO_REVOKE:-}" ]]; then
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Revoking SG ingress for ${CALLER_IP_TO_REVOKE}..."
        aws ec2 revoke-security-group-ingress \
            --region "$_region" --group-id "${SG_ID:-}" \
            --protocol tcp --port 22 \
            --cidr "${CALLER_IP_TO_REVOKE}/32" 2>/dev/null || true
    fi

    if [[ -n "${DRIVER_INSTANCE_ID:-}" && "${DRIVER_INSTANCE_ID:-}" != "None" && ( $_force_cleanup -eq 1 || "${TERMINATE_DRIVER_ON_EXIT:-1}" -eq 1 ) ]]; then
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Terminating driver instance ${DRIVER_INSTANCE_ID}..."
        aws ec2 terminate-instances --region "$_region" \
            --instance-ids "$DRIVER_INSTANCE_ID" >/dev/null 2>&1 || true
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Waiting for instance to terminate..."
        aws ec2 wait instance-terminated --region "$_region" \
            --instance-ids "$DRIVER_INSTANCE_ID" 2>/dev/null || true

        if [[ -n "${CREATED_SG_ID:-}" ]]; then
            echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Deleting temporary security group ${CREATED_SG_ID}..."
            aws ec2 delete-security-group --region "$_region" \
                --group-id "$CREATED_SG_ID" 2>/dev/null || true
        fi
    fi

    # --- SSM transfer bucket (infrastructure, always clean up) ---
    if [[ -n "${SSM_TRANSFER_BUCKET:-}" ]]; then
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Cleaning up SSM transfer bucket ${SSM_TRANSFER_BUCKET}..."
        s3_delete_disabled rm "s3://${SSM_TRANSFER_BUCKET}" --recursive --region "$_region"
        s3_delete_disabled rb "s3://${SSM_TRANSFER_BUCKET}" --region "$_region"
    fi

    # --- Lambda function ---
    if [[ -n "${LAMBDA_FUNCTION_NAME:-}" ]]; then
        local _lambda_arn
        _lambda_arn=$(aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" \
            --region "$_region" --query 'Configuration.FunctionArn' --output text 2>/dev/null || echo "")
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Deleting Lambda function ${LAMBDA_FUNCTION_NAME}..."
        aws lambda delete-function --function-name "$LAMBDA_FUNCTION_NAME" \
            --region "$_region" 2>/dev/null || true
        delete_lambda_log_group "$LAMBDA_FUNCTION_NAME" "$_region"

        # --- EventBridge rules targeting this Lambda ---
        if [[ -n "$_lambda_arn" && "$_lambda_arn" != "None" ]]; then
            local _rules
            _rules=$(aws events list-rule-names-by-target --target-arn "$_lambda_arn" \
                --region "$_region" --query 'RuleNames[]' --output text 2>/dev/null || echo "")
            for _rule in $_rules; do
                local _tids
                _tids=$(aws events list-targets-by-rule --rule "$_rule" \
                    --region "$_region" --query 'Targets[].Id' --output text 2>/dev/null || echo "")
                [[ -n "$_tids" ]] && aws events remove-targets --rule "$_rule" --ids $_tids \
                    --region "$_region" 2>/dev/null || true
                aws events delete-rule --name "$_rule" --region "$_region" 2>/dev/null || true
            done
        fi
        aws events remove-targets --rule "${LAMBDA_FUNCTION_NAME}-rule" --ids "LambdaTarget" \
            --region "$_region" 2>/dev/null || true
        aws events delete-rule --name "${LAMBDA_FUNCTION_NAME}-rule" \
            --region "$_region" 2>/dev/null || true
    fi

    # --- IAM execution role ---
    if [[ -n "${LAMBDA_EXECUTION_ROLE_NAME:-}" ]]; then
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Deleting IAM role ${LAMBDA_EXECUTION_ROLE_NAME}..."
        aws iam list-attached-role-policies --role-name "$LAMBDA_EXECUTION_ROLE_NAME" \
            --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | \
            tr '\t' '\n' | while read -r _pa; do
                [[ -n "$_pa" ]] && aws iam detach-role-policy --role-name "$LAMBDA_EXECUTION_ROLE_NAME" \
                    --policy-arn "$_pa" 2>/dev/null || true
            done
        aws iam list-role-policies --role-name "$LAMBDA_EXECUTION_ROLE_NAME" \
            --query 'PolicyNames[]' --output text 2>/dev/null | \
            tr '\t' '\n' | while read -r _pn; do
                [[ -n "$_pn" ]] && aws iam delete-role-policy --role-name "$LAMBDA_EXECUTION_ROLE_NAME" \
                    --policy-name "$_pn" 2>/dev/null || true
            done
        aws iam delete-role --role-name "$LAMBDA_EXECUTION_ROLE_NAME" 2>/dev/null || true
    fi

    # --- ECR repository ---
    if [[ -n "${ECR_REPO_NAME:-}" ]]; then
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Deleting ECR repository ${ECR_REPO_NAME}..."
        aws ecr delete-repository --repository-name "$ECR_REPO_NAME" \
            --force --region "$_region" 2>/dev/null || true
    fi

    # --- S3 buckets (FASTQ, TXT, MAP, QUANT) ---
    local _bucket
    for _bucket in "${INPUT_FASTQ_BUCKET:-}" "${INPUT_TXT_BUCKET:-}" "${OUTPUT_MAP_BUCKET:-}" "${OUTPUT_QUANT_BUCKET:-}"; do
        if [[ -n "$_bucket" ]]; then
            if [[ $_force_cleanup -eq 0 && "${CLEANUP_RESULTS:-1}" -ne 1 && "$_bucket" == "${OUTPUT_QUANT_BUCKET:-}" ]]; then
                echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Keeping results bucket: $_bucket (CLEANUP_RESULTS=0)"
                continue
            fi
            echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Deleting S3 bucket ${_bucket}..."
            s3_delete_disabled rm "s3://$_bucket" --recursive --region "$_region"
            s3_delete_disabled rb "s3://$_bucket" --region "$_region"
        fi
    done

    # --- Local results: remove partial output on failure, keep on success ---
    if [[ $exit_code -ne 0 && -n "${RUN_ID:-}" && -n "${LOCAL_RESULTS_DIR:-}" ]]; then
        local _run_dir="${LOCAL_RESULTS_DIR}/${RUN_ID}"
        if [[ -d "$_run_dir" ]]; then
            echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Removing incomplete local results: $_run_dir"
            rm -rf "$_run_dir"
        fi
    fi

    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Cleanup complete."
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

################################################################################
# User Configuration (Edit Once)
# Set these defaults once, then override via env vars if needed
################################################################################

DEFAULT_AWS_REGION="us-east-2"
DEFAULT_KEY_NAME=""
DEFAULT_KEY_PEM_PATH=""
DEFAULT_EC2_INSTANCE_PROFILE_NAME="scrna-serverless-ec2-role"
DEFAULT_SEED_AMI_ID="ami-079f71ff8e580ef1f"  # Author's seed AMI (hardcoded for reproducibility)
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
INSTANCE_TYPE="${INSTANCE_TYPE:-m5dn.8xlarge}"
ROOT_VOL_GB="${ROOT_VOL_GB:-500}"
KEY_NAME="${KEY_NAME:-$DEFAULT_KEY_NAME}"
KEY_PEM_PATH="${KEY_PEM_PATH:-$DEFAULT_KEY_PEM_PATH}"
SUBNET_ID="${SUBNET_ID:-}"
SG_ID="${SG_ID:-}"
# Only populated when subnets are auto-detected; stays empty when SUBNET_ID is
# supplied, so it must exist up front for the AZ-fallback loop under `set -u`.
PUBLIC_SUBNETS=()
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
LAMBDA_CONCURRENCY="${LAMBDA_CONCURRENCY:-1000}"
S3_CLAIM_PREFIX="${S3_CLAIM_PREFIX:-piscem_claims}"
S3_CLAIM_PREFIX="${S3_CLAIM_PREFIX#/}"
S3_CLAIM_PREFIX="${S3_CLAIM_PREFIX%/}"
CLAIM_LEASE_SECONDS="${CLAIM_LEASE_SECONDS:-180}"
CLAIM_HEARTBEAT_SECONDS="${CLAIM_HEARTBEAT_SECONDS:-30}"

# Execution Configuration
THREADS="${THREADS:-$(nproc)}"
ALLOW_DESTRUCTIVE_CLEANUP="${ALLOW_DESTRUCTIVE_CLEANUP:-0}"
ALLOW_S3_DELETE="${ALLOW_S3_DELETE:-0}"
CLEANUP_AWS="${CLEANUP_AWS:-0}"
CLEANUP_RESULTS="${CLEANUP_RESULTS:-0}"
DELETE_CLOUDWATCH_LOGS="${DELETE_CLOUDWATCH_LOGS:-0}"
SKIP_PREFLIGHT_CLEANUP="${SKIP_PREFLIGHT_CLEANUP:-1}"
TERMINATE_DRIVER_ON_EXIT="${TERMINATE_DRIVER_ON_EXIT:-1}"
RUN_QC="${RUN_QC:-1}"
DOWNLOAD_RESULTS="${DOWNLOAD_RESULTS:-${DOWNLOAD_TO_LOCAL:-1}}"  # DOWNLOAD_TO_LOCAL is accepted alias
LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR:-./serverless_runs}"

# FASTQ Configuration
LOCAL_FASTQ_DIR="${LOCAL_FASTQ_DIR:-}"
FASTQ_TAR_PATH="${FASTQ_TAR_PATH:-}"
FASTQ_TAR_URL="${FASTQ_TAR_URL:-}"
WRITE_H5AD="${WRITE_H5AD:-1}"
RUN_ID="${RUN_ID:-}"
READ_PAIRS_PER_SHARD="${READ_PAIRS_PER_SHARD:-}"
SPLIT_LINES="${SPLIT_LINES:-}"
DIRECT_GZIP_MAX_BYTES="${DIRECT_GZIP_MAX_BYTES:-1073741824}"
PROCESS_FASTQ_TIMEOUT_SEC="${PROCESS_FASTQ_TIMEOUT_SEC:-43200}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
POST_UPLOAD_PROPAGATION_WAIT_SECONDS="${POST_UPLOAD_PROPAGATION_WAIT_SECONDS:-0}"
USE_RAPIDGZIP="${USE_RAPIDGZIP:-auto}"
EXECUTION_MODE="${EXECUTION_MODE:-synchronous}"

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
        --arg mem "$mem" \
        --arg claims "$S3_CLAIM_PREFIX" \
        --arg lease "$CLAIM_LEASE_SECONDS" \
        --arg heartbeat "$CLAIM_HEARTBEAT_SECONDS" \
        '{Variables:{
            S3_OUTPUT_BUCKET_NAME:$out,
            S3_INPUT_BUCKET_NAME:$inp,
            S3_INPUT_TXT_BUCKET_NAME:$txt,
            LAMBDA_MEMORY_MB:$mem,
            S3_CLAIM_PREFIX:$claims,
            CLAIM_LEASE_SECONDS:$lease,
            CLAIM_HEARTBEAT_SECONDS:$heartbeat
        }}')

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

# Stream the MorPhiC KO R1/R2 FASTQs from ENA into a persistent S3 cache.
# Index reads (I1/I2) are skipped. Fetch time is recorded but excluded from
# Table 1, matching the paper caption. The cache survives CLEANUP_AWS so a
# retry does not pull 450 GB from ENA again.
fetch_ko_fastqs() {
    local manifest="${KO_ENA_MANIFEST:-/home/ubuntu/scrna-repo/scripts/ko_ena_r1r2.tsv}"
    [[ -f "$manifest" ]] || die "KO ENA manifest missing: $manifest"

    KO_FASTQ_CACHE_BUCKET="${KO_FASTQ_CACHE_BUCKET:-scrna-ko-fastq-${AWS_ACCOUNT_ID}-${AWS_REGION}}"
    export KO_FASTQ_CACHE_BUCKET
    log_info "KO FASTQ cache: s3://$KO_FASTQ_CACHE_BUCKET/ko/"
    aws s3 mb "s3://$KO_FASTQ_CACHE_BUCKET" --region "$AWS_REGION" 2>/dev/null || true

    local work="$RUN_DIR/ko_fetch"
    mkdir -p "$work"
    local todo="$work/todo.tsv"
    : > "$todo"
    LANE_BASENAMES=()
    LANE_R1_PATHS=()
    LANE_R2_PATHS=()

    local filename bytes url cached
    while IFS=$'\t' read -r filename bytes url; do
        [[ "$filename" == "filename" || -z "$filename" ]] && continue
        cached=$(aws s3api head-object --bucket "$KO_FASTQ_CACHE_BUCKET" --key "ko/$filename" \
            --query ContentLength --output text --region "$AWS_REGION" 2>/dev/null || echo 0)
        if [[ "$cached" == "$bytes" ]]; then
            :
        else
            printf '%s\t%s\t%s\n' "$filename" "$bytes" "$url" >> "$todo"
        fi
        if [[ "$filename" == *_R1_001.fastq.gz ]]; then
            local lane="${filename%_R1_001.fastq.gz}"
            LANE_BASENAMES+=("$lane")
            LANE_R1_PATHS+=("s3://$KO_FASTQ_CACHE_BUCKET/ko/${lane}_R1_001.fastq.gz")
            LANE_R2_PATHS+=("s3://$KO_FASTQ_CACHE_BUCKET/ko/${lane}_R2_001.fastq.gz")
        fi
    done < "$manifest"

    local n_todo
    n_todo=$(grep -c . "$todo" 2>/dev/null || echo 0)
    if [[ "${n_todo:-0}" -gt 0 ]]; then
        log_info "Downloading $n_todo KO file(s) from ENA into the cache (8 at a time)..."
        local failf="$work/fail.txt"
        : > "$failf"
        _ko_fetch_one() {
            local filename="$1" bytes="$2" url="$3"
            local dest="$work/$filename"
            local tries=0 got
            while (( tries < 6 )); do
                tries=$((tries + 1))
                log_info "  ENA fetch $filename (try $tries, $((bytes / 1048576)) MB)"
                rm -f "$dest"
                # Write to disk first. Piping curl into `aws s3 cp -` uses
                # multipart upload and can fail with MalformedXML on a reset.
                if curl -fL --retry 5 --retry-delay 8 --retry-all-errors -o "$dest" "$url"; then
                    got=$(stat --format=%s "$dest" 2>/dev/null || echo 0)
                    if [[ "$got" == "$bytes" ]] && \
                       aws s3 cp "$dest" "s3://${KO_FASTQ_CACHE_BUCKET}/ko/${filename}" \
                           --region "$AWS_REGION" --only-show-errors; then
                        rm -f "$dest"
                        return 0
                    fi
                    log_warn "  size/upload mismatch $filename expected $bytes got $got"
                else
                    log_warn "  curl failed for $filename"
                fi
                rm -f "$dest"
                sleep $((tries * 15))
            done
            echo "$filename" >> "$failf"
            return 1
        }
        while IFS=$'\t' read -r filename bytes url; do
            [[ -z "$filename" ]] && continue
            while (( $(jobs -rp | wc -l) >= 8 )); do
                sleep 2
            done
            _ko_fetch_one "$filename" "$bytes" "$url" &
        done < "$todo"
        wait
        if [[ -s "$failf" ]]; then
            die "ENA download failed for $(wc -l < "$failf") file(s): $(tr '\n' ' ' < "$failf")"
        fi
        log_info "ENA fetch complete ($n_todo new file(s))"
    else
        log_info "All KO R1/R2 FASTQs already in the cache — skipping ENA download"
    fi

    [[ ${#LANE_BASENAMES[@]} -gt 0 ]] || die "No KO R1 files listed in $manifest"
    BASENAME_WITH_LANE="${LANE_BASENAMES[0]}"
    log_info "Lanes found: ${#LANE_BASENAMES[@]}"
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

################################################################################
# Step timing instrumentation
#
# Each phase below corresponds to a row of Table 1 in the manuscript and is
# written to $RUN_DIR/timings.csv by the pipeline itself, so the published
# breakdown can be regenerated from a run rather than copied by hand.
################################################################################

PHASE_LABEL=""
PHASE_STEP=""
PHASE_START=""

phase_begin() {
    PHASE_LABEL="$1"
    PHASE_STEP="${2:-}"
    PHASE_START=$(date +%s.%N)
}

phase_end() {
    [[ -n "$PHASE_START" ]] || return 0
    local end secs mins csv
    end=$(date +%s.%N)
    secs=$(awk -v a="$PHASE_START" -v b="$end" 'BEGIN{printf "%.3f", b-a}')
    mins=$(awk -v s="$secs" 'BEGIN{printf "%.2f", s/60}')
    csv="${RUN_DIR:-/tmp}/timings.csv"
    [[ -f "$csv" ]] || echo "phase,figure1_step,seconds,minutes" > "$csv"
    echo "${PHASE_LABEL},${PHASE_STEP},${secs},${mins}" >> "$csv"
    log_info "  [timing] ${PHASE_LABEL}: ${mins} min (${secs}s)"
    PHASE_START=""
}

process_fastq_bash() {
    local output_dir="$1"
    local expected_folders_file="$2"


    declare -A PF_R1_KEYS PF_R2_KEYS
    local local_fastq_mode=0
    if [[ -n "${LOCAL_FASTQ_DIR:-}" ]]; then
        local_fastq_mode=1
        log_info "Using compressed FASTQs directly from NVMe: $LOCAL_FASTQ_DIR"
        local _local_i _local_base
        for _local_i in "${!LANE_BASENAMES[@]}"; do
            _local_base="${DATASET}/${LANE_BASENAMES[$_local_i]}"
            PF_R1_KEYS["$_local_base"]="${LANE_R1_PATHS[$_local_i]}"
            PF_R2_KEYS["$_local_base"]="${LANE_R2_PATHS[$_local_i]}"
        done
    else
        log_info "Finding FASTQ pairs in S3 bucket $INPUT_FASTQ_BUCKET ..."
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
    fi

    local INPUT_FOLDERS=()

    # Anything in the map bucket older than this instant belongs to an earlier
    # run and must not count towards completion. Recorded before any input.txt
    # is uploaded, so no Lambda for this run can have written yet.
    local MAP_POLL_SINCE
    MAP_POLL_SINCE=$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null \
                     || date -u +%Y-%m-%dT%H:%M:%S)

    phase_begin "Split and Upload [on-server]" 3

    # Size first, then process lane pairs in descending combined compressed
    # bytes. Large work units therefore enter the decompression queue first.
    local -a ORDERED_BASES=()
    local -a SPLIT_LANES=() SPLIT_R1=() SPLIT_R2=() SPLIT_BASE=()
    local -a DIRECT_LANES=() DIRECT_R1=() DIRECT_R2=() DIRECT_BASE=()
    local -A PF_PAIR_BYTES=()
    local base r1_key r2_key r1_bytes r2_bytes combined_bytes

    TOTAL_INPUT_BYTES=0
    for base in "${!PF_R1_KEYS[@]}"; do
        r1_key="${PF_R1_KEYS[$base]}"
        r2_key="${PF_R2_KEYS[$base]:-}"
        [[ -z "$r2_key" ]] && { log_warn "No R2 for $base, skipping"; continue; }
        if (( local_fastq_mode == 1 )); then
            r1_bytes=$(stat --format=%s "$r1_key")
            r2_bytes=$(stat --format=%s "$r2_key")
        else
            r1_bytes=$(aws s3api head-object --bucket "$INPUT_FASTQ_BUCKET" --key "$r1_key" \
                --region "$AWS_REGION" --query 'ContentLength' --output text 2>/dev/null || echo 0)
            r2_bytes=$(aws s3api head-object --bucket "$INPUT_FASTQ_BUCKET" --key "$r2_key" \
                --region "$AWS_REGION" --query 'ContentLength' --output text 2>/dev/null || echo 0)
        fi
        [[ "$r1_bytes" =~ ^[0-9]+$ && "$r2_bytes" =~ ^[0-9]+$ ]] || \
            die "Could not determine compressed size for $base"
        combined_bytes=$((r1_bytes + r2_bytes))
        PF_PAIR_BYTES["$base"]="$combined_bytes"
        TOTAL_INPUT_BYTES=$((TOTAL_INPUT_BYTES + combined_bytes))
    done

    mapfile -t ORDERED_BASES < <(
        for base in "${!PF_PAIR_BYTES[@]}"; do
            printf '%s\t%s\n' "${PF_PAIR_BYTES[$base]}" "$base"
        done | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 | cut -f2-
    )

    local lane_id direct_threshold_bytes
    if [[ $LAMBDA_MEMORY_MB -le 3008 ]]; then
        direct_threshold_bytes=0
    else
        direct_threshold_bytes=$DIRECT_GZIP_MAX_BYTES
    fi
    for base in "${ORDERED_BASES[@]}"; do
        r1_key="${PF_R1_KEYS[$base]}"
        r2_key="${PF_R2_KEYS[$base]}"
        combined_bytes="${PF_PAIR_BYTES[$base]}"
        lane_id=$(basename "$base")
        log_info "Pair $lane_id: combined compressed size $combined_bytes bytes; direct-pass cutoff $direct_threshold_bytes bytes"

        if (( direct_threshold_bytes > 0 && combined_bytes < direct_threshold_bytes )); then
            DIRECT_LANES+=("$lane_id")
            DIRECT_R1+=("$r1_key")
            DIRECT_R2+=("$r2_key")
            DIRECT_BASE+=("$base")
            INPUT_FOLDERS+=("${lane_id}_p0")
        else
            SPLIT_LANES+=("$lane_id")
            SPLIT_R1+=("$r1_key")
            SPLIT_R2+=("$r2_key")
            SPLIT_BASE+=("$base")
        fi
    done

    publish_direct_pairs() {
        local i lane base_path base_folder direct_r1 direct_r2 r1_s3 r2_s3
        local r1_object r2_object r1_upload_pid r2_upload_pid
        for i in "${!DIRECT_LANES[@]}"; do
            lane="${DIRECT_LANES[$i]}"
            base_path="${DIRECT_BASE[$i]}"
            base_folder=$(dirname "$base_path")
            [[ "$base_folder" == "." ]] && base_folder=""
            direct_r1="${DIRECT_R1[$i]}"
            direct_r2="${DIRECT_R2[$i]}"
            if (( local_fastq_mode == 1 )); then
                r1_object="${base_path}_R1_001.fastq.gz"
                r2_object="${base_path}_R2_001.fastq.gz"
                aws s3 cp "$direct_r1" "s3://${INPUT_FASTQ_BUCKET}/${r1_object}" \
                    --region "$AWS_REGION" --only-show-errors &
                r1_upload_pid=$!
                aws s3 cp "$direct_r2" "s3://${INPUT_FASTQ_BUCKET}/${r2_object}" \
                    --region "$AWS_REGION" --only-show-errors &
                r2_upload_pid=$!
                wait "$r1_upload_pid" || return 1
                wait "$r2_upload_pid" || return 1
                r1_s3="s3://${INPUT_FASTQ_BUCKET}/${r1_object}"
                r2_s3="s3://${INPUT_FASTQ_BUCKET}/${r2_object}"
            else
                r1_s3="s3://${INPUT_FASTQ_BUCKET}/${direct_r1}"
                r2_s3="s3://${INPUT_FASTQ_BUCKET}/${direct_r2}"
            fi
            create_and_upload_input_txt "$lane" "$r1_s3" "$r2_s3" "$base_folder" || return 1
        done
    }

    local DIRECT_PUBLISH_PID=""

    if [[ ${#SPLIT_LANES[@]} -gt 0 ]]; then
        # Apportion CPUs across the compressed files that actually require
        # splitting. More files than cores means one gzip worker per file.
        # Otherwise divide CPUs evenly and cap rapidgzip at its measured sweet
        # spot of eight threads per file.
        local _cores _split_file_count
        _cores=$(nproc 2>/dev/null || echo 4)
        _split_file_count=$(( ${#SPLIT_LANES[@]} * 2 ))
        DECOMP_THREADS=1
        FASTQ_DECOMPRESSOR=gzip
        if [[ "$USE_RAPIDGZIP" != "0" ]] && (( _split_file_count < _cores )); then
            DECOMP_THREADS=$(( _cores / _split_file_count ))
            (( DECOMP_THREADS > 8 )) && DECOMP_THREADS=8
            if (( DECOMP_THREADS > 1 )) && command -v rapidgzip >/dev/null 2>&1; then
                FASTQ_DECOMPRESSOR=rapidgzip
            else
                DECOMP_THREADS=1
            fi
        fi
        export DECOMP_THREADS FASTQ_DECOMPRESSOR
        local _max_lanes=$(( _cores / (DECOMP_THREADS * 2) ))
        (( _max_lanes < 1 )) && _max_lanes=1

        local _decompressor_description="$FASTQ_DECOMPRESSOR"
        [[ "$FASTQ_DECOMPRESSOR" == "rapidgzip" ]] && \
            _decompressor_description="rapidgzip -P $DECOMP_THREADS"
        if (( local_fastq_mode == 1 )); then
            log_info "Splitting ${#SPLIT_LANES[@]} lane pair(s), ${_max_lanes} at a time from NVMe with $_decompressor_description per file"
        else
            log_info "Splitting ${#SPLIT_LANES[@]} lane pair(s), ${_max_lanes} at a time after S3 download with $_decompressor_description per file"
        fi

        local parts_dir="$RUN_DIR/split_parts"
        rm -rf "$parts_dir"; mkdir -p "$parts_dir"
        local split_timings_dir="$RUN_DIR/split_timings"
        mkdir -p "$split_timings_dir"

        local -a split_pids=()
        local i _rc=0 _finished_pid _pid
        local _core_release_dir="" _core_release_fifo="" _core_release_fd=""
        local _available_cores="$_cores" _pair_core_cost=$((DECOMP_THREADS * 2))
        reap_one_split_pair() {
            local _wait_rc=0
            local -a _remaining=()
            _finished_pid=""
            wait -n -p _finished_pid "${split_pids[@]}" || _wait_rc=$?
            (( _wait_rc == 0 )) || _rc=1
            [[ -n "$_finished_pid" ]] || die "Could not identify completed split-pair worker"
            for _pid in "${split_pids[@]}"; do
                [[ "$_pid" == "$_finished_pid" ]] || _remaining+=("$_pid")
            done
            split_pids=("${_remaining[@]}")
        }

        # NVMe workers can return the R1 and R2 allocations independently.
        # The next pair starts as soon as any two complete streams have freed
        # enough cores; the streams need not belong to the same prior pair.
        if (( local_fastq_mode == 1 )); then
            _core_release_dir=$(mktemp -d "$RUN_DIR/core_release.XXXXXX")
            _core_release_fifo="$_core_release_dir/releases.fifo"
            mkfifo "$_core_release_fifo"
            exec {_core_release_fd}<>"$_core_release_fifo"
        fi

        for i in "${!SPLIT_LANES[@]}"; do
            if (( local_fastq_mode == 1 )); then
                while (( _available_cores < _pair_core_cost )); do
                    local _released_cores
                    IFS= read -r _released_cores <&"$_core_release_fd" || \
                        die "Core-release scheduler pipe closed unexpectedly"
                    [[ "$_released_cores" =~ ^[1-9][0-9]*$ ]] || \
                        die "Invalid core-release notification: $_released_cores"
                    _available_cores=$((_available_cores + _released_cores))
                done
                _available_cores=$((_available_cores - _pair_core_cost))
            else
                while (( ${#split_pids[@]} >= _max_lanes )); do
                    reap_one_split_pair
                done
            fi
            (
                if (( local_fastq_mode == 1 )); then
                    CORE_RELEASE_FIFO="$_core_release_fifo" \
                    SPLIT_TIMINGS_FILE="$split_timings_dir/${SPLIT_LANES[$i]}.csv" \
                    bash /home/ubuntu/scrna-repo/scripts/split_upload_trigger_local.sh \
                        "$INPUT_FASTQ_BUCKET" "${SPLIT_R1[$i]}" "${SPLIT_R2[$i]}" \
                        "${SPLIT_BASE[$i]}" "$INPUT_TXT_BUCKET" "$SPLIT_LINES" \
                        > "$parts_dir/${SPLIT_LANES[$i]}.log" 2>&1
                else
                    SPLIT_TIMINGS_FILE="$split_timings_dir/${SPLIT_LANES[$i]}.csv" \
                    bash /home/ubuntu/scrna-repo/split_and_upload.sh \
                        "$INPUT_FASTQ_BUCKET" "${SPLIT_R1[$i]}" "${SPLIT_R2[$i]}" \
                        "${SPLIT_BASE[$i]}" "$INPUT_TXT_BUCKET" \
                        > "$parts_dir/${SPLIT_LANES[$i]}.log" 2>&1
                fi
                _split_rc=$?
                tail -1 "$parts_dir/${SPLIT_LANES[$i]}.log" \
                    > "$parts_dir/${SPLIT_LANES[$i]}.parts"
                exit "$_split_rc"
            ) &
            split_pids+=("$!")
            # Start direct-pass pairs only after the first full batch of the
            # largest split jobs has claimed the decompression cores. Direct
            # pairs use Lambda/S3 capacity and can overlap without displacing
            # those larger local jobs.
            if [[ -z "$DIRECT_PUBLISH_PID" && ${#DIRECT_LANES[@]} -gt 0 ]] && \
               (( ${#split_pids[@]} >= _max_lanes || i == ${#SPLIT_LANES[@]} - 1 )); then
                publish_direct_pairs &
                DIRECT_PUBLISH_PID=$!
            fi
        done
        if (( local_fastq_mode == 1 )); then
            for _pid in "${split_pids[@]}"; do
                wait "$_pid" || _rc=1
            done
            exec {_core_release_fd}>&-
            rm -f -- "$_core_release_fifo"
            rmdir -- "$_core_release_dir"
        else
            while (( ${#split_pids[@]} > 0 )); do
                reap_one_split_pair
            done
        fi
        [[ $_rc -eq 0 ]] || die "split_and_upload.sh failed for one or more lanes"

        for i in "${!SPLIT_LANES[@]}"; do
            local this_lane="${SPLIT_LANES[$i]}"
            local num_parts
            num_parts=$(cat "$parts_dir/${this_lane}.parts" 2>/dev/null || echo 0)
            [[ "${num_parts:-0}" -gt 0 ]] || die "split_and_upload.sh produced no parts for $this_lane"
            log_info "  $this_lane: $num_parts shard pair(s)"
            for idx in $(seq 0 $((num_parts - 1))); do
                INPUT_FOLDERS+=("${this_lane}_p${idx}")
            done
        done
        rm -rf "$parts_dir"
    fi

    if [[ -z "$DIRECT_PUBLISH_PID" && ${#DIRECT_LANES[@]} -gt 0 ]]; then
        publish_direct_pairs &
        DIRECT_PUBLISH_PID=$!
    fi
    if [[ -n "$DIRECT_PUBLISH_PID" ]]; then
        wait "$DIRECT_PUBLISH_PID" || die "Direct gzip-pair publication failed"
    fi

    local input_count=${#INPUT_FOLDERS[@]}

    # Preserve the exact set expected from this submission.  Counting arbitrary
    # objects in the output bucket is unsafe when deletion is disabled, and the
    # direct S3 materializer needs these folders in numeric shard order.
    printf '%s\n' "${INPUT_FOLDERS[@]}" | LC_ALL=C sort -V -u > "$expected_folders_file"
    printf '%s\n' "$MAP_POLL_SINCE" > "${expected_folders_file}.not-before"

    phase_end

    log_info "Total input folders: $input_count"
    [[ $input_count -gt 0 ]] || die "No input folders created. Check FASTQ files in $INPUT_FASTQ_BUCKET"

    if [[ "$EXECUTION_MODE" == "async-submit" ]]; then
        log_info "All shard manifests published; returning without waiting for Lambda (EXECUTION_MODE=async-submit)."
        return 0
    fi

    # EventBridge propagation was already awaited before splitting. Poll
    # immediately so Lambda execution remains overlapped with shard uploads.
    if (( POST_UPLOAD_PROPAGATION_WAIT_SECONDS > 0 )); then
        phase_begin "EventBridge propagation wait [on-server]" 3
        log_info "Waiting ${POST_UPLOAD_PROPAGATION_WAIT_SECONDS}s before polling Lambda outputs..."
        sleep "$POST_UPLOAD_PROPAGATION_WAIT_SECONDS"
        phase_end
    fi

    # Poll output bucket
    phase_begin "Piscem Map [serverless]" 4
    log_info "Polling output bucket $OUTPUT_MAP_BUCKET for Lambda results..."
    local poll_start last_completed=0 last_progress_ts stall_limit
    poll_start=$(date +%s)
    last_progress_ts="$poll_start"
    stall_limit=$(( LAMBDA_TIMEOUT_SEC + 180 ))

    while true; do
        local completed=0
        local -a _have=()
        local _keys
        # Filter on age in the shell rather than in JMESPath: comparing a
        # timestamp against a string literal there needs nested quoting that
        # does not survive being shipped through SSM.
        _keys=$(aws s3api list-objects-v2 --bucket "$OUTPUT_MAP_BUCKET" --prefix "piscem_output/" \
                    --query "Contents[?ends_with(Key,'/output.txt')].[Key,to_string(LastModified)]" \
                    --output text --region "$AWS_REGION" 2>/dev/null \
                | awk -v since="$MAP_POLL_SINCE" '$2 >= since {print $1}' || echo "")

        if [[ -n "$_keys" && "$_keys" != "None" ]]; then
            local _k
            for _k in $_keys; do
                local _folder
                _folder="${_k#piscem_output/}"
                _folder="${_folder%/output.txt}"
                for _expected in "${INPUT_FOLDERS[@]}"; do
                    if [[ "$_folder" == "$_expected" ]]; then
                        completed=$((completed + 1))
                        _have+=("$_folder")
                        break
                    fi
                done
            done
        fi

        log_info "Output progress: $completed / $input_count"

        if [[ $completed -gt $last_completed ]]; then
            last_completed=$completed
            last_progress_ts=$(date +%s)
        fi

        if [[ $completed -ge $input_count ]]; then
            break
        fi

        local elapsed=$(( $(date +%s) - poll_start ))
        local stalled=$(( $(date +%s) - last_progress_ts ))
        if [[ $stalled -gt $stall_limit ]]; then
            log_error "Mapping stalled at $completed / $input_count. No new output.txt for ${stalled}s."
            log_error "A Lambda shard likely hit the ${LAMBDA_TIMEOUT_SEC}s timeout without writing output."
            log_error "Shards still missing:"
            local _exp _found _h
            for _exp in "${INPUT_FOLDERS[@]}"; do
                _found=0
                if [[ ${#_have[@]} -gt 0 ]]; then
                    for _h in "${_have[@]}"; do
                        if [[ "$_h" == "$_exp" ]]; then
                            _found=1
                            break
                        fi
                    done
                fi
                [[ $_found -eq 0 ]] && log_error "  $_exp"
            done
            aws logs tail "/aws/lambda/$LAMBDA_FUNCTION_NAME" --region "$AWS_REGION" \
                --since 30m --format short 2>&1 | tail -50 >&2 || true
            die "Piscem Map stopped making progress. Missing shards are listed above."
        fi
        if [[ $elapsed -gt $PROCESS_FASTQ_TIMEOUT_SEC ]]; then
            log_error "Timeout (${PROCESS_FASTQ_TIMEOUT_SEC}s) waiting for Lambda outputs."
            log_error "Checking CloudWatch logs for Lambda errors..."
            aws logs tail "/aws/lambda/$LAMBDA_FUNCTION_NAME" --region "$AWS_REGION" \
                --since 30m --format short 2>&1 | tail -50 >&2 || true
            log_error "Listing output bucket contents for diagnostics..."
            aws s3 ls "s3://$OUTPUT_MAP_BUCKET/" --recursive --region "$AWS_REGION" 2>&1 | tail -30 >&2 || true
            die "Lambda did not complete in time. Check CloudWatch logs above for OOM / Runtime errors."
        fi
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

    phase_end

    local elapsed_sec=$(( $(date +%s) - poll_start ))
    log_info "All $input_count outputs ready ($((elapsed_sec / 60)) min $((elapsed_sec % 60)) sec)"

    # Download only the non-RAD companion outputs. map.rad shards remain in S3
    # and are ranged directly into the final combined file in Step 8.
    phase_begin "Download non-RAD files [on-server]" 6
    log_info "Downloading non-RAD output files from $OUTPUT_MAP_BUCKET ..."
    mkdir -p "${output_dir}/piscem_output"
    aws s3 sync "s3://${OUTPUT_MAP_BUCKET}/piscem_output/" "${output_dir}/piscem_output/" \
        --region "$AWS_REGION" --exclude '*/map.rad' --only-show-errors
    phase_end

    log_info "All non-RAD output files downloaded to $output_dir"
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

    # Poll for completion. Request the status field on its own rather than the
    # whole invocation: commands that emit CLI transfer progress produce a
    # payload large enough that parsing it locally can fail, and an unparsed
    # status would leave this loop spinning after the command has finished.
    local status
    while true; do
        status=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'Status' --output text 2>/dev/null || true)
        if [[ -z "$status" || "$status" == "None" ]]; then
            status=$(aws ssm list-command-invocations \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --query 'CommandInvocations[0].Status' --output text 2>/dev/null || true)
        fi
        case "$status" in
            Success)
                aws ssm get-command-invocation \
                    --region "$AWS_REGION" \
                    --command-id "$cmd_id" \
                    --instance-id "$instance_id" \
                    --query 'StandardOutputContent' --output text 2>/dev/null || true
                return 0 ;;
            Failed|TimedOut|Cancelled)
                log_error "SSM command $status (ID: $cmd_id)"
                aws ssm get-command-invocation \
                    --region "$AWS_REGION" \
                    --command-id "$cmd_id" \
                    --instance-id "$instance_id" \
                    --query 'StandardErrorContent' --output text 2>/dev/null >&2 || true
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
        --arg claim_prefix "$S3_CLAIM_PREFIX" \
        --arg claim_lease "$CLAIM_LEASE_SECONDS" \
        --arg claim_heartbeat "$CLAIM_HEARTBEAT_SECONDS" \
        --arg threads "$THREADS" \
        --arg allow_cleanup "$ALLOW_DESTRUCTIVE_CLEANUP" \
        --arg allow_s3_delete "$ALLOW_S3_DELETE" \
        --arg cleanup "$CLEANUP_AWS" \
        --arg cleanup_results "$CLEANUP_RESULTS" \
        --arg delete_logs "$DELETE_CLOUDWATCH_LOGS" \
        --arg skip_preflight "$SKIP_PREFLIGHT_CLEANUP" \
        --arg fastq_path "${FASTQ_TAR_PATH:-}" \
        --arg fastq_url "${FASTQ_TAR_URL:-}" \
        --arg write_h5ad "$WRITE_H5AD" \
        --arg run_id "$run_id" \
        --arg run_qc "$RUN_QC" \
        --arg read_pairs_per_shard "$READ_PAIRS_PER_SHARD" \
        --arg split_lines "$SPLIT_LINES" \
        --arg direct_gzip_max_bytes "$DIRECT_GZIP_MAX_BYTES" \
        --arg use_rapidgzip "${USE_RAPIDGZIP:-auto}" \
        --arg execution_mode "$EXECUTION_MODE" \
        --arg concurrency "${LAMBDA_CONCURRENCY:-0}" \
        --arg ko_cache "${KO_FASTQ_CACHE_BUCKET:-}" \
        --arg user "$SSH_USER" \
        --arg ds "$dataset" \
        '{commands:[
            "#!/bin/bash",
            "set -euo pipefail",
            ("export AWS_REGION=" + $region),
            ("export LAMBDA_MEMORY_MB=" + $mem),
            ("export LAMBDA_EPHEMERAL_MB=" + $eph),
            ("export LAMBDA_TIMEOUT_SEC=" + $timeout),
            ("export LAMBDA_CONCURRENCY=" + $concurrency),
            ("export S3_CLAIM_PREFIX=" + $claim_prefix),
            ("export CLAIM_LEASE_SECONDS=" + $claim_lease),
            ("export CLAIM_HEARTBEAT_SECONDS=" + $claim_heartbeat),
            ("export THREADS=" + $threads),
            ("export ALLOW_DESTRUCTIVE_CLEANUP=" + $allow_cleanup),
            ("export ALLOW_S3_DELETE=" + $allow_s3_delete),
            ("export CLEANUP_AWS=" + $cleanup),
            ("export CLEANUP_RESULTS=" + $cleanup_results),
            ("export DELETE_CLOUDWATCH_LOGS=" + $delete_logs),
            ("export SKIP_PREFLIGHT_CLEANUP=" + $skip_preflight),
            ("export FASTQ_TAR_PATH=" + $fastq_path),
            ("export FASTQ_TAR_URL=" + $fastq_url),
            ("export WRITE_H5AD=" + $write_h5ad),
            ("export RUN_ID=" + $run_id),
            ("export RUN_QC=" + $run_qc),
            ("export READ_PAIRS_PER_SHARD=" + $read_pairs_per_shard),
            ("export SPLIT_LINES=" + $split_lines),
            ("export DIRECT_GZIP_MAX_BYTES=" + $direct_gzip_max_bytes),
            ("export USE_RAPIDGZIP=" + $use_rapidgzip),
            ("export EXECUTION_MODE=" + $execution_mode),
            ("export KO_FASTQ_CACHE_BUCKET=" + $ko_cache),
            ("cd /home/" + $user + "/scrna-repo"),
            ("bash scripts/e2e_serverless_pbmc.sh " + $ds + " --run 2>&1 | tee /tmp/pipeline-" + $run_id + ".log")
        ], executionTimeout:["86400"]}')

    local cmd_id
    cmd_id=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "$cmds_json" \
        --timeout-seconds 86400 \
        --output-s3-bucket-name "$transfer_bucket" \
        --output-s3-key-prefix "ssm-output/$run_id" \
        --query 'Command.CommandId' --output text)

    log_info "SSM pipeline command sent: $cmd_id"

    # Poll for completion.
    #
    # Ask for the Status field alone. Fetching the whole invocation pulls
    # StandardOutputContent with it, which reaches hundreds of kilobytes once the
    # AWS CLI transfer progress lines are included, and parsing that payload
    # locally fails often enough that the loop can spin forever while the remote
    # pipeline has already finished. The full stdout is written to S3 by
    # --output-s3-bucket-name and is retrieved once, below.
    local waited=0
    while true; do
        local status
        status=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'Status' --output text 2>/dev/null || true)

        # Fall back to the list API, which reports status even when the
        # single-invocation call is briefly unavailable.
        if [[ -z "$status" || "$status" == "None" ]]; then
            status=$(aws ssm list-command-invocations \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --query 'CommandInvocations[0].Status' --output text 2>/dev/null || true)
        fi

        if [[ -z "$status" || "$status" == "None" ]]; then
            log_info "SSM poll: status unavailable, retrying (${waited}s elapsed)..."
            sleep 15
            waited=$((waited + 15))
            continue
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
                aws ssm get-command-invocation \
                    --region "$AWS_REGION" \
                    --command-id "$cmd_id" \
                    --instance-id "$instance_id" \
                    --query 'StandardErrorContent' --output text 2>/dev/null >&2 || true
                # Download full log from S3
                log_info "Downloading full SSM output log from S3..."
                mkdir -p "${LOCAL_RESULTS_DIR}/${run_id}/ssm-output"
                aws s3 sync "s3://${transfer_bucket}/ssm-output/${run_id}/" \
                    "${LOCAL_RESULTS_DIR}/${run_id}/ssm-output/" --region "$AWS_REGION" 2>/dev/null || true
                return 1 ;;
            *)
                sleep 15
                waited=$((waited + 15))
                if (( waited % 300 == 0 )); then
                    log_info "SSM poll: $status (${waited}s elapsed)"
                fi
                ;;
        esac
    done
}

################################################################################
# Argument Parsing
################################################################################

if [[ $# -lt 1 ]]; then
    cat >&2 <<EOF
Usage: $0 <dataset> [--run|--dry-run]
  dataset: pbmc1k, pbmc10k, or ko
  --run: Execute in run mode on EC2 (default: driver mode)
  --dry-run: Validate requirements without creating AWS resources
EOF
    exit 1
fi

DATASET="$1"
if [[ "$DATASET" != "pbmc1k" && "$DATASET" != "pbmc10k" && "$DATASET" != "ko" ]]; then
    die "Unknown dataset: $DATASET (must be pbmc1k, pbmc10k, or ko)"
fi
if [[ "$EXECUTION_MODE" != "synchronous" && "$EXECUTION_MODE" != "async-submit" ]]; then
    die "Unknown EXECUTION_MODE: $EXECUTION_MODE (must be synchronous or async-submit)"
fi
[[ -n "$S3_CLAIM_PREFIX" ]] || die "S3_CLAIM_PREFIX cannot be empty"
[[ "$CLAIM_LEASE_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "CLAIM_LEASE_SECONDS must be positive"
[[ "$CLAIM_HEARTBEAT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "CLAIM_HEARTBEAT_SECONDS must be positive"
(( CLAIM_HEARTBEAT_SECONDS < CLAIM_LEASE_SECONDS )) || \
    die "CLAIM_HEARTBEAT_SECONDS must be less than CLAIM_LEASE_SECONDS"
[[ "$USE_RAPIDGZIP" == "auto" || "$USE_RAPIDGZIP" == "0" || "$USE_RAPIDGZIP" == "1" ]] || \
    die "USE_RAPIDGZIP must be auto, 0, or 1"
[[ "$DIRECT_GZIP_MAX_BYTES" =~ ^[1-9][0-9]*$ ]] || \
    die "DIRECT_GZIP_MAX_BYTES must be a positive integer"
if [[ -n "$READ_PAIRS_PER_SHARD" ]]; then
    [[ "$READ_PAIRS_PER_SHARD" =~ ^[1-9][0-9]*$ ]] || \
        die "READ_PAIRS_PER_SHARD must be a positive integer"
fi
if [[ -n "$SPLIT_LINES" ]]; then
    [[ "$SPLIT_LINES" =~ ^[1-9][0-9]*$ ]] || die "SPLIT_LINES must be a positive integer"
    (( SPLIT_LINES % 4 == 0 )) || die "SPLIT_LINES must be divisible by four"
    if [[ -n "$READ_PAIRS_PER_SHARD" ]] && \
       (( SPLIT_LINES != READ_PAIRS_PER_SHARD * 4 )); then
        die "SPLIT_LINES must equal READ_PAIRS_PER_SHARD * 4 when both are set"
    fi
fi
if [[ "$DATASET" == "ko" ]]; then
    # Combined 86-line matrix is not useful for the paper QC plots, and the
    # results tarball would be ~200 GB. Table 1 only needs timings.csv.
    RUN_QC=0
    WRITE_H5AD=0
    if [[ "${DOWNLOAD_KO_RESULTS:-0}" != "1" ]]; then
        DOWNLOAD_RESULTS=0
    fi
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
    
    # FASTQ URL / KO manifest
    log_info "[CHECK 6/7] FASTQ source..."
    if [[ "$DATASET" == "ko" ]]; then
        if [[ -f "scripts/ko_ena_r1r2.tsv" ]]; then
            log_info "  PASS: KO ENA manifest present (scripts/ko_ena_r1r2.tsv)"
            pass=$((pass + 1))
        else
            log_error "  FAIL: scripts/ko_ena_r1r2.tsv missing"
            fail=$((fail + 1))
        fi
    else
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
        log_info "  export CLEANUP_AWS=0 CLEANUP_RESULTS=0 TERMINATE_DRIVER_ON_EXIT=0 RUN_QC=1 WRITE_H5AD=1"
        log_info "  bash scripts/e2e_serverless_pbmc.sh $DATASET"
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
        PUBLIC_SUBNETS=()
        PUBLIC_SUBNET_IPS=()
        
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
                PUBLIC_SUBNETS+=("$sid")
                PUBLIC_SUBNET_IPS+=("$ips")
            else
                log_info "  Subnet $sid ($az): no IGW default route (rt=$RT), skipping"
            fi
        done <<< "$CANDIDATE_SUBNETS"
        
        if [[ ${#PUBLIC_SUBNETS[@]} -eq 0 ]]; then
            log_error "No truly public subnet found in VPC $VPC_ID."
            log_error "A public subnet needs: MapPublicIpOnLaunch=true AND a 0.0.0.0/0 route to an igw-*."
            log_error "Candidate subnets checked:"
            echo "$CANDIDATE_SUBNETS" | while IFS=$'\t' read -r sid ips az; do
                log_error "  $sid  IPs=$ips  AZ=$az  MapPublic=true  (missing IGW route)"
            done
            die "Set SUBNET_ID explicitly to a known public subnet."
        fi
        
        SUBNET_ID="${PUBLIC_SUBNETS[0]}"
        log_info "Auto-selected public subnet: $SUBNET_ID (VPC: $VPC_ID, available IPs: ${PUBLIC_SUBNET_IPS[0]})"
        log_info "Total public subnets available for AZ fallback: ${#PUBLIC_SUBNETS[@]}"
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
        
        # The group name is derived from RUN_ID, so a rerun under the same ID
        # collides with the group left behind by the previous attempt. Adopt
        # that one rather than failing, since it was created here and carries
        # the same rules.
        if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
            SG_ID=$(aws ec2 describe-security-groups \
                --region "$AWS_REGION" \
                --filters "Name=group-name,Values=scrna-driver-ssh-$RUN_ID" \
                          "Name=vpc-id,Values=$VPC_ID" \
                --query 'SecurityGroups[0].GroupId' \
                --output text 2>/dev/null || echo "")
            [[ "$SG_ID" == "None" ]] && SG_ID=""
            [[ -n "$SG_ID" ]] && log_info "Reusing existing security group: $SG_ID"
        fi

        if [[ -z "$SG_ID" ]]; then
            die "Failed to create security group."
        fi
        
        CREATED_SG_ID="$SG_ID"
        log_info "Temporary security group: $SG_ID"
        
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
        # Default is m5dn.8xlarge (32 vCPU, 2x NVMe). That is the box 1K, 10K,
        # and KO actually completed on with RAID 0, rapidgzip -P 8, and 2 lanes.
        INSTANCE_FALLBACKS=("$INSTANCE_TYPE")
        if [[ "$INSTANCE_TYPE" == "m5dn.8xlarge" ]]; then
            INSTANCE_FALLBACKS+=("m5dn.4xlarge" "m6id.8xlarge" "m6id.4xlarge" "m6id.xlarge" "m6i.xlarge" "t3.2xlarge" "t3.xlarge" "t3.large")
        elif [[ "$INSTANCE_TYPE" == "m6id.16xlarge" ]]; then
            INSTANCE_FALLBACKS+=("m6id.8xlarge" "m6id.4xlarge" "m6id.xlarge" "m6i.xlarge" "t3.2xlarge" "t3.xlarge" "m7i-flex.large" "t3.large" "c7i-flex.large" "t3.medium" "t3.small" "t3.micro")
        fi
        
        # Build list of subnets to try: auto-picked subnets across AZs, or just the one set
        SUBNETS_TO_TRY=()
        if [[ ${#PUBLIC_SUBNETS[@]} -gt 0 ]]; then
            SUBNETS_TO_TRY=("${PUBLIC_SUBNETS[@]}")
        else
            SUBNETS_TO_TRY=("$SUBNET_ID")
        fi
        
        DRIVER_INSTANCE_ID=""
        for _try_type in "${INSTANCE_FALLBACKS[@]}"; do
            for _try_subnet in "${SUBNETS_TO_TRY[@]}"; do
                log_info "Attempting instance type: $_try_type in subnet $_try_subnet"
                _launch_err=$(mktemp)
                if DRIVER_INSTANCE_ID=$(MSYS2_ARG_CONV_EXCL="*" MSYS_NO_PATHCONV=1 \
                    aws ec2 run-instances \
                    --region "$AWS_REGION" \
                    --image-id "$SEED_AMI_ID" \
                    --instance-type "$_try_type" \
                    "${KEY_NAME_ARGS[@]}" \
                    --subnet-id "$_try_subnet" \
                    --security-group-ids "$SG_ID" \
                    "${IAM_PROFILE_ARGS[@]}" \
                    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_VOL_GB,VolumeType=gp3}" \
                    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=scrna-e2e-$RUN_ID}]" \
                    --query "Instances[0].InstanceId" \
                    --output text 2>"$_launch_err"); then
                    rm -f "$_launch_err"
                    INSTANCE_TYPE="$_try_type"
                    SUBNET_ID="$_try_subnet"
                    break 2
                fi
                _err_msg=$(cat "$_launch_err" 2>/dev/null); rm -f "$_launch_err"
                # Hard-fail on errors that won't be fixed by trying a smaller instance
                if [[ "$_err_msg" == *"AuthFailure"* || "$_err_msg" == *"UnauthorizedOperation"* \
                   || "$_err_msg" == *"InvalidAMIID"* || "$_err_msg" == *"InvalidGroup"* \
                   || "$_err_msg" == *"InvalidSubnetID"* || "$_err_msg" == *"InvalidKeyPair"* ]]; then
                    die "Failed to launch EC2 instance ($_try_type): $_err_msg"
                fi
                if [[ "$_err_msg" == *"InsufficientInstanceCapacity"* ]]; then
                    log_warn "Instance type $_try_type unavailable in $(echo "$_try_subnet" | head -c 20)...: capacity issue, trying next AZ..."
                    DRIVER_INSTANCE_ID=""
                    continue
                fi
                # Any other error (quota, free-tier restriction, unsupported type, etc.) — try next instance type
                log_warn "Instance type $_try_type unavailable: ${_err_msg##*:}"
                DRIVER_INSTANCE_ID=""
                break
            done
            [[ -n "$DRIVER_INSTANCE_ID" ]] && break
        done
        
        [[ -n "$DRIVER_INSTANCE_ID" ]] || die "All instance types and AZs exhausted (tried: ${INSTANCE_FALLBACKS[*]} across ${#SUBNETS_TO_TRY[@]} subnets). Request a vCPU quota increase in AWS Service Quotas."
    
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
    TARBALL_LOCAL="$(dirname "$REPO_DIR")/scrna-repo-${RUN_ID}.tar.gz"
    
    # Only the code is needed on the instance. Collected results and downloaded
    # inputs live under the repository too and reach several gigabytes once a
    # few runs have accumulated, which is enough to break the upload.
    tar --exclude='serverless_runs' --exclude='onserver_runs' --exclude='runs' \
        --exclude='standalone_runs' --exclude='benchmark_results' \
        --exclude='data' --exclude='tools' \
        --exclude='.git' --exclude='*.log' --exclude='scrna-repo-*.tar.gz' \
        --exclude='MASTER_PROMPT.md' --exclude='.vscode' --exclude='.idea' \
        -czf "$TARBALL_LOCAL" -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")"

    log_info "Repository bundle: $(du -h "$TARBALL_LOCAL" | cut -f1)"
    
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
export LAMBDA_CONCURRENCY=$LAMBDA_CONCURRENCY
export S3_CLAIM_PREFIX=$S3_CLAIM_PREFIX
export CLAIM_LEASE_SECONDS=$CLAIM_LEASE_SECONDS
export CLAIM_HEARTBEAT_SECONDS=$CLAIM_HEARTBEAT_SECONDS
export THREADS=$THREADS
export ALLOW_DESTRUCTIVE_CLEANUP=$ALLOW_DESTRUCTIVE_CLEANUP
export ALLOW_S3_DELETE=$ALLOW_S3_DELETE
export CLEANUP_AWS=$CLEANUP_AWS
export CLEANUP_RESULTS=$CLEANUP_RESULTS
export DELETE_CLOUDWATCH_LOGS=$DELETE_CLOUDWATCH_LOGS
export SKIP_PREFLIGHT_CLEANUP=$SKIP_PREFLIGHT_CLEANUP
export FASTQ_TAR_PATH=$FASTQ_TAR_PATH
export FASTQ_TAR_URL=$FASTQ_TAR_URL
export WRITE_H5AD=$WRITE_H5AD
export RUN_ID=$RUN_ID
export RUN_QC=$RUN_QC
export READ_PAIRS_PER_SHARD=$READ_PAIRS_PER_SHARD
export SPLIT_LINES=$SPLIT_LINES
export DIRECT_GZIP_MAX_BYTES=$DIRECT_GZIP_MAX_BYTES
export USE_RAPIDGZIP=${USE_RAPIDGZIP:-auto}
export EXECUTION_MODE=$EXECUTION_MODE
export KO_FASTQ_CACHE_BUCKET=${KO_FASTQ_CACHE_BUCKET:-}

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
                "tar -czf /tmp/${RUN_ID}_results.tgz --exclude='fastq' --exclude='lambda_build' --exclude='venv_qc' --exclude='output' -C /mnt/nvme/runs ${RUN_ID}"
            scp "${SSH_OPTS[@]}" \
                "${SSH_USER}@${DRIVER_INSTANCE_IP}:/tmp/${RUN_ID}_results.tgz" "$LOCAL_RESULTS_DIR/$RUN_ID/"
        else
            # SSM: create tarball on instance, upload to S3, download locally
            log_info "Preparing results tarball on EC2 and uploading to S3 (this may take several minutes)..."
            ssm_run_command "$DRIVER_INSTANCE_ID" \
                "tar -czf /tmp/${RUN_ID}_results.tgz --exclude='fastq' --exclude='lambda_build' --exclude='venv_qc' --exclude='output' -C /mnt/nvme/runs ${RUN_ID} && aws s3 cp /tmp/${RUN_ID}_results.tgz s3://${SSM_TRANSFER_BUCKET}/results/${RUN_ID}_results.tgz --region ${AWS_REGION} && rm -f /tmp/${RUN_ID}_results.tgz" \
                43200
            log_info "Downloading results tarball from S3 to local machine..."
            _dl_target="$LOCAL_RESULTS_DIR/$RUN_ID/${RUN_ID}_results.tgz"
            if ! aws s3 cp "s3://${SSM_TRANSFER_BUCKET}/results/${RUN_ID}_results.tgz" \
                "$_dl_target" \
                --region "$AWS_REGION"; then
                log_error "S3 download failed"
                DOWNLOAD_RESULTS=0
            fi
        fi
        
        # Extract locally and remove tarball to reclaim disk space
        if [[ -f "$LOCAL_RESULTS_DIR/$RUN_ID/${RUN_ID}_results.tgz" ]]; then
            log_info "Extracting results to $LOCAL_RESULTS_DIR/$RUN_ID/"
            if tar -xzf "$LOCAL_RESULTS_DIR/$RUN_ID/${RUN_ID}_results.tgz" -C "$LOCAL_RESULTS_DIR/$RUN_ID"; then
                rm -f "$LOCAL_RESULTS_DIR/$RUN_ID/${RUN_ID}_results.tgz"
                log_info "Results extracted and tarball removed to reclaim disk space."
            else
                log_error "Extraction failed — tarball kept at $LOCAL_RESULTS_DIR/$RUN_ID/${RUN_ID}_results.tgz"
            fi
            log_info "Results downloaded to: $LOCAL_RESULTS_DIR/$RUN_ID/$RUN_ID/"
        fi
    fi
    
    ############################################################################
    # Cleanup (also runs via cleanup_on_exit trap on failure)
    ############################################################################

    if [[ $RUN_EXIT -ne 0 ]]; then
        log_error "Pipeline exited with code $RUN_EXIT.  Cleanup will run via trap."
    fi

    # Normal-path cleanup: revoke SG ingress, then terminate+delete. During
    # development the master gate keeps the whole driver environment intact.
    if [[ "$ALLOW_DESTRUCTIVE_CLEANUP" != "1" ]]; then
        log_info "Driver cleanup blocked by ALLOW_DESTRUCTIVE_CLEANUP=0; instance and temporary resources are preserved."
    elif [[ $TERMINATE_DRIVER_ON_EXIT -eq 1 ]]; then
        if [[ -n "${CALLER_IP_TO_REVOKE:-}" ]]; then
            manage_sg_ingress revoke "$CALLER_IP_TO_REVOKE"
        fi
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
            s3_delete_disabled rm "s3://${SSM_TRANSFER_BUCKET}" --recursive --region "$AWS_REGION"
            s3_delete_disabled rb "s3://${SSM_TRANSFER_BUCKET}" --region "$AWS_REGION"
        fi

        # Clear DRIVER_INSTANCE_ID so the trap doesn't double-terminate
        DRIVER_INSTANCE_ID=""
        CREATED_SG_ID=""
    else
        if [[ -n "${CALLER_IP_TO_REVOKE:-}" ]]; then
            manage_sg_ingress revoke "$CALLER_IP_TO_REVOKE"
        fi
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

if ! command -v aws >/dev/null 2>&1; then
    log_info "AWS CLI missing on this instance. Installing AWS CLI v2..."
    for _i in $(seq 1 30); do
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
        log_info "waiting for dpkg lock $_i/30"
        sleep 10
    done
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip curl
    curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
    (cd /tmp && unzip -qo awscliv2.zip && sudo ./aws/install --update)
    rm -rf /tmp/awscliv2.zip /tmp/aws
    command -v aws >/dev/null 2>&1 || die "AWS CLI install failed"
fi
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
    # Collect every unmounted NVMe instance-store device (skip mounted ones, e.g. root EBS on nvme0n1).
    # Storage layout follows install_scripts/install.sh: RAID 0 across all instance-store
    # devices, XFS with RAID-aware geometry, and the same mount/scheduler/read-ahead tuning.
    NVMe_DEVICES=()
    while read -r dev; do
        dev_path="/dev/$dev"
        # Skip if this device (or a partition of it) is already mounted
        if mount | grep -q "^${dev_path}"; then
            log_info "Skipping $dev_path (already mounted)"
            continue
        fi
        [[ -b "$dev_path" ]] && NVMe_DEVICES+=("$dev_path")
    done < <(lsblk -d -n -l -o NAME | grep nvme)

    NVMe_COUNT=${#NVMe_DEVICES[@]}
    log_info "Unmounted NVMe instance-store devices found: $NVMe_COUNT (${NVMe_DEVICES[*]:-none})"

    if [[ $NVMe_COUNT -gt 0 ]]; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mdadm xfsprogs >/dev/null 2>&1 || true

        for d in "${NVMe_DEVICES[@]}"; do
            sudo wipefs -a "$d" >/dev/null 2>&1 || true
            base=$(basename "$d")
            echo "none" | sudo tee "/sys/block/$base/queue/scheduler" >/dev/null 2>&1 || true
        done

        if [[ $NVMe_COUNT -ge 2 ]]; then
            log_info "Creating RAID 0 across $NVMe_COUNT devices (256K chunk)..."
            sudo mdadm --create --verbose /dev/md0 --level=0 \
                --raid-devices="$NVMe_COUNT" --chunk=256K --run "${NVMe_DEVICES[@]}"
            NVMe_TARGET="/dev/md0"
            log_info "Creating XFS on $NVMe_TARGET (su=256k,sw=$NVMe_COUNT)..."
            sudo mkfs.xfs -f -d "su=256k,sw=$NVMe_COUNT" "$NVMe_TARGET"
        else
            NVMe_TARGET="${NVMe_DEVICES[0]}"
            log_warn "Only one instance-store device present; no RAID 0 possible"
            log_info "Creating XFS on $NVMe_TARGET..."
            sudo mkfs.xfs -f "$NVMe_TARGET"
        fi

        log_info "Mounting $NVMe_TARGET to $MOUNT_POINT..."
        sudo mkdir -p "$MOUNT_POINT"
        sudo mount -o noatime,nodiratime,logbufs=8,logbsize=256k,allocsize=64m \
            "$NVMe_TARGET" "$MOUNT_POINT"
        sudo blockdev --setra 65536 "$NVMe_TARGET" || true
        sudo chown -R ubuntu:ubuntu "$MOUNT_POINT"
        log_info "NVMe storage ready: $(df -h "$MOUNT_POINT" | tail -1)"
    else
        log_info "No unmounted NVMe device found; using default storage"
        sudo mkdir -p "$MOUNT_POINT"
        sudo chown -R ubuntu:ubuntu "$MOUNT_POINT"
    fi
fi

# rapidgzip: parallel gzip decompression for Split and Upload. Falls back to
# zcat if the install below does not land on PATH.
export PATH="${HOME:-/home/ubuntu}/.local/bin:/usr/local/bin:$PATH"
if ! command -v rapidgzip >/dev/null 2>&1; then
    log_info "Installing rapidgzip..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip >/dev/null 2>&1 || true
    sudo pip3 install --quiet --break-system-packages rapidgzip >/dev/null 2>&1 \
        || sudo pip3 install --quiet rapidgzip >/dev/null 2>&1 \
        || pip3 install --quiet --user rapidgzip >/dev/null 2>&1 \
        || true
fi
if command -v rapidgzip >/dev/null 2>&1; then
    log_info "rapidgzip available: $(rapidgzip --version 2>&1 | head -1)"
else
    log_warn "rapidgzip unavailable; Split and Upload will fall back to zcat"
fi

# Create run directory
RUN_DIR="/mnt/nvme/runs/$RUN_ID"
mkdir -p "$RUN_DIR"

log_info "Run directory: $RUN_DIR"


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

# Reported for both arms but excluded from Overall Process, matching the Table 1
# caption which states the times exclude fetching raw sequence data.
phase_begin "Fetch raw FASTQs" ""

if [[ -n "$LOCAL_FASTQ_DIR" ]]; then
    [[ -d "$LOCAL_FASTQ_DIR" ]] || die "LOCAL_FASTQ_DIR not found: $LOCAL_FASTQ_DIR"
    FASTQ_DIR="$LOCAL_FASTQ_DIR"
else
    FASTQ_DIR="$RUN_DIR/fastq"
    mkdir -p "$FASTQ_DIR"
fi

# Auto-set FASTQ_TAR_URL by dataset if not provided
if [[ "$DATASET" != "ko" && -z "$FASTQ_TAR_PATH" && -z "$FASTQ_TAR_URL" ]]; then
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

# Obtain FASTQs
if [[ "$DATASET" == "ko" && -z "$LOCAL_FASTQ_DIR" ]]; then
    fetch_ko_fastqs
elif [[ -n "$LOCAL_FASTQ_DIR" ]]; then
    log_info "Reusing already-extracted FASTQs from NVMe: $LOCAL_FASTQ_DIR"
elif [[ -n "$FASTQ_TAR_PATH" ]]; then
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

if [[ "$DATASET" != "ko" || -n "$LOCAL_FASTQ_DIR" ]]; then
    # Find R1 files. The lanes are deliberately kept separate. process_fastq.py
    # grouped FASTQs by lane and processed each pair concurrently; concatenating them
    # leaves one oversized R2 stream, and since decompression is the critical path of
    # Split and Upload, that serialises the phase.
    R1_FILES=($(find "$FASTQ_DIR" -name "*R1_001.fastq.gz" | sort))
    [[ ${#R1_FILES[@]} -gt 0 ]] || die "No R1_001.fastq.gz files found"

    # The tar extracts into its own subdirectory, so keep the real paths rather than
    # rebuilding them from $FASTQ_DIR.
    LANE_BASENAMES=()
    LANE_R1_PATHS=()
    LANE_R2_PATHS=()
    for _r1 in "${R1_FILES[@]}"; do
        _lane="$(basename "$_r1")"
        _lane="${_lane/_R1_001.fastq.gz/}"
        _r2="$(dirname "$_r1")/${_lane}_R2_001.fastq.gz"
        [[ -f "$_r2" ]] || die "No R2 mate for lane $_lane (expected $_r2)"
        LANE_BASENAMES+=("$_lane")
        LANE_R1_PATHS+=("$_r1")
        LANE_R2_PATHS+=("$_r2")
    done

    BASENAME_WITH_LANE="${LANE_BASENAMES[0]}"
    log_info "Lanes found: ${#LANE_BASENAMES[@]} (${LANE_BASENAMES[*]})"
fi

log_info "FASTQ files ready"

phase_end

log_info "Step 1 complete"

################################################################################
# Step 2-4: Create S3 Buckets and Setup EventBridge
################################################################################

log_info "Step 2: Creating S3 buckets..."

aws s3 mb "s3://$INPUT_FASTQ_BUCKET" --region "$AWS_REGION" 2>/dev/null || true
aws s3 mb "s3://$INPUT_TXT_BUCKET" --region "$AWS_REGION" 2>/dev/null || true
aws s3 mb "s3://$OUTPUT_MAP_BUCKET" --region "$AWS_REGION" 2>/dev/null || true
aws s3 mb "s3://$OUTPUT_QUANT_BUCKET" --region "$AWS_REGION" 2>/dev/null || true

# Bucket names derive from the run id, which repeats across benchmark
# invocations, and "mb" is a no-op on an existing bucket. Without this purge the
# previous run's piscem_output/<lane>_p<N>/output.txt markers are still present,
# so the readiness poll below reports every shard complete within seconds and
# the download then races the Lambdas that are still writing those same objects,
# which surfaces as "did not match expected ETag" failures.
log_info "Purging previous outputs from $OUTPUT_MAP_BUCKET and $OUTPUT_QUANT_BUCKET..."
for _ob in "$OUTPUT_MAP_BUCKET" "$OUTPUT_QUANT_BUCKET"; do
    _stale=$(aws s3api list-objects-v2 --bucket "$_ob" --query 'length(Contents)' \
                 --output text --region "$AWS_REGION" 2>/dev/null || echo "0")
    [[ "$_stale" == "None" || -z "$_stale" ]] && _stale=0
    if [[ "$_stale" != "0" ]]; then
        log_info "  $_ob: removing $_stale stale object(s) from a previous run"
        s3_delete_disabled rm "s3://${_ob}/" --recursive --region "$AWS_REGION" --only-show-errors
    else
        log_info "  $_ob: already empty"
    fi
done

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

if [[ "$DATASET" == "ko" && -z "$LOCAL_FASTQ_DIR" ]]; then
    log_info "Copying KO FASTQs from cache to run bucket (S3-to-S3)..."
    aws s3 sync "s3://$KO_FASTQ_CACHE_BUCKET/ko/" "s3://$INPUT_FASTQ_BUCKET/ko/" \
        --region "$AWS_REGION" --only-show-errors
elif [[ -n "$LOCAL_FASTQ_DIR" ]]; then
    log_info "Skipping compressed FASTQ upload; split workers will read NVMe inputs directly"
else
    _upload_pids=()
    for _i in "${!LANE_BASENAMES[@]}"; do
        _lane="${LANE_BASENAMES[$_i]}"
        aws s3 cp "${LANE_R1_PATHS[$_i]}" \
            "s3://$INPUT_FASTQ_BUCKET/$DATASET/${_lane}_R1_001.fastq.gz" \
            --region "$AWS_REGION" &
        _upload_pids+=("$!")
        aws s3 cp "${LANE_R2_PATHS[$_i]}" \
            "s3://$INPUT_FASTQ_BUCKET/$DATASET/${_lane}_R2_001.fastq.gz" \
            --region "$AWS_REGION" &
        _upload_pids+=("$!")
    done
    for _pid in "${_upload_pids[@]}"; do
        wait "$_pid" || die "FASTQ upload to S3 failed"
    done
fi

log_info "FASTQs uploaded (${#LANE_BASENAMES[@]} lane pair(s))"

log_info "Step 3 complete"

################################################################################
# Step 5: Prepare Lambda Build Context
################################################################################

log_info "Step 5: Preparing Lambda build context..."

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
# Step 5b: Pre-flight cleanup — remove stale scrna resources from prior runs
#   Frees reserved concurrency and avoids resource conflicts.
################################################################################

if [[ "$ALLOW_DESTRUCTIVE_CLEANUP" != "1" || "$SKIP_PREFLIGHT_CLEANUP" == "1" ]]; then
    log_info "Pre-flight cleanup gated (ALLOW_DESTRUCTIVE_CLEANUP=$ALLOW_DESTRUCTIVE_CLEANUP, SKIP_PREFLIGHT_CLEANUP=$SKIP_PREFLIGHT_CLEANUP)."
else
log_info "Pre-flight cleanup: checking for stale scrna resources from prior runs..."

_stale_lambdas=$(aws lambda list-functions --region "$AWS_REGION" \
    --query "Functions[?starts_with(FunctionName,'scrna-map-')].FunctionName" \
    --output text 2>/dev/null || echo "")

if [[ -n "$_stale_lambdas" && "$_stale_lambdas" != "None" ]]; then
    for _fn in $_stale_lambdas; do
        log_warn "Removing stale Lambda function: $_fn"
        _fn_arn=$(aws lambda get-function --function-name "$_fn" \
            --region "$AWS_REGION" --query 'Configuration.FunctionArn' --output text 2>/dev/null || echo "")

        aws lambda delete-function-concurrency --function-name "$_fn" \
            --region "$AWS_REGION" 2>/dev/null || true
        aws lambda delete-function --function-name "$_fn" \
            --region "$AWS_REGION" 2>/dev/null || true
        delete_lambda_log_group "$_fn" "$AWS_REGION"

        if [[ -n "$_fn_arn" && "$_fn_arn" != "None" ]]; then
            _stale_rules=$(aws events list-rule-names-by-target --target-arn "$_fn_arn" \
                --region "$AWS_REGION" --query 'RuleNames[]' --output text 2>/dev/null || echo "")
            for _sr in $_stale_rules; do
                _tids=$(aws events list-targets-by-rule --rule "$_sr" \
                    --region "$AWS_REGION" --query 'Targets[].Id' --output text 2>/dev/null || echo "")
                [[ -n "$_tids" ]] && aws events remove-targets --rule "$_sr" --ids $_tids \
                    --region "$AWS_REGION" 2>/dev/null || true
                aws events delete-rule --name "$_sr" --region "$AWS_REGION" 2>/dev/null || true
            done
        fi
        aws events remove-targets --rule "${_fn}-rule" --ids "LambdaTarget" \
            --region "$AWS_REGION" 2>/dev/null || true
        aws events delete-rule --name "${_fn}-rule" \
            --region "$AWS_REGION" 2>/dev/null || true
    done
fi

_stale_roles=$(aws iam list-roles \
    --query "Roles[?starts_with(RoleName,'scrna-lambda-role-')].RoleName" \
    --output text 2>/dev/null || echo "")
if [[ -n "$_stale_roles" && "$_stale_roles" != "None" ]]; then
    for _sr in $_stale_roles; do
        log_warn "Removing stale IAM role: $_sr"
        aws iam list-attached-role-policies --role-name "$_sr" \
            --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | \
            tr '\t' '\n' | while read -r _pa; do
                [[ -n "$_pa" ]] && aws iam detach-role-policy --role-name "$_sr" \
                    --policy-arn "$_pa" 2>/dev/null || true
            done
        aws iam list-role-policies --role-name "$_sr" \
            --query 'PolicyNames[]' --output text 2>/dev/null | \
            tr '\t' '\n' | while read -r _pn; do
                [[ -n "$_pn" ]] && aws iam delete-role-policy --role-name "$_sr" \
                    --policy-name "$_pn" 2>/dev/null || true
            done
        aws iam delete-role --role-name "$_sr" 2>/dev/null || true
    done
fi

_stale_ecr=$(aws ecr describe-repositories --region "$AWS_REGION" \
    --query "repositories[?starts_with(repositoryName,'scrna-serverless-')].repositoryName" \
    --output text 2>/dev/null || echo "")
if [[ -n "$_stale_ecr" && "$_stale_ecr" != "None" ]]; then
    for _er in $_stale_ecr; do
        log_warn "Removing stale ECR repository: $_er"
        aws ecr delete-repository --repository-name "$_er" \
            --force --region "$AWS_REGION" 2>/dev/null || true
    done
fi

_stale_buckets=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'scrna-')].Name" \
    --output text 2>/dev/null || echo "")
if [[ -n "$_stale_buckets" && "$_stale_buckets" != "None" ]]; then
    for _sb in $_stale_buckets; do
        if [[ "$_sb" == "$INPUT_FASTQ_BUCKET" || "$_sb" == "$INPUT_TXT_BUCKET" || \
              "$_sb" == "$OUTPUT_MAP_BUCKET" || "$_sb" == "$OUTPUT_QUANT_BUCKET" || \
              "$_sb" == "${SSM_TRANSFER_BUCKET:-}" || "$_sb" == scrna-ssm-xfer-* || \
              "$_sb" == "${KO_FASTQ_CACHE_BUCKET:-}" || "$_sb" == scrna-ko-fastq-* ]]; then
            continue
        fi
        log_warn "Removing stale S3 bucket: $_sb"
        s3_delete_disabled rm "s3://$_sb" --recursive --region "$AWS_REGION"
        s3_delete_disabled rb "s3://$_sb" --region "$AWS_REGION"
    done
fi

log_info "Pre-flight cleanup complete."
fi

################################################################################
# Step 6: Setup Lambda and EventBridge (pure bash — no python)
################################################################################

log_info "Step 6: Setting up Lambda function and EventBridge..."

# 6a: Create ECR repository
ECR_REPO_URI=$(create_ecr_repo_if_needed "$ECR_REPO_NAME")

# 6b: Build and push Docker image to ECR
IMAGE_URI=$(build_and_push_lambda_image "$ECR_REPO_URI" "$DOCKER_IMAGE_NAME" "$BUILD_DIR")

log_info "Steps 5-6b complete"

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

# 6d2: Set reserved concurrency with fallback chain
set_lambda_concurrency() {
    local requested="${1:-0}"
    [[ "$requested" -le 0 ]] && return 0

    local -a chain=()
    for lvl in 1000 900 750 500 100 50 25 10; do
        [[ $lvl -le $requested ]] && chain+=("$lvl")
    done
    [[ ${#chain[@]} -eq 0 ]] && chain=("$requested")

    for c in "${chain[@]}"; do
        if aws lambda put-function-concurrency \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --reserved-concurrent-executions "$c" \
            --region "$AWS_REGION" >/dev/null 2>&1; then
            LAMBDA_CONCURRENCY="$c"
            log_info "Lambda reserved concurrency set to $c"
            return 0
        fi
        log_warn "Concurrency $c rejected by account quota, trying lower..."
    done
    # All reservation attempts failed — query actual account concurrency limit
    local acct_limit
    acct_limit=$(aws lambda get-account-settings --region "$AWS_REGION" \
        --query 'AccountLimit.UnreservedConcurrentExecutions' --output text 2>/dev/null) || acct_limit=""

    if [[ -n "$acct_limit" && "$acct_limit" =~ ^[0-9]+$ && "$acct_limit" -gt 0 ]]; then
        LAMBDA_CONCURRENCY="$acct_limit"
        log_warn "Could not reserve concurrency — account limit is $acct_limit (unreserved)"
    else
        LAMBDA_CONCURRENCY="unrestricted"
        log_warn "Could not determine account concurrency limit — running unrestricted"
    fi
}
set_lambda_concurrency "$LAMBDA_CONCURRENCY"

# 6d3: Select a read-pair target, then translate it to FASTQ lines. Explicit
# values win; the low-concurrency fallback applies to every large dataset.
if [[ -n "$SPLIT_LINES" ]]; then
    READ_PAIRS_PER_SHARD=$((SPLIT_LINES / 4))
elif [[ -n "$READ_PAIRS_PER_SHARD" ]]; then
    SPLIT_LINES=$((READ_PAIRS_PER_SHARD * 4))
elif [[ "$LAMBDA_CONCURRENCY" != "unrestricted" && "$LAMBDA_CONCURRENCY" -le 25 ]]; then
    READ_PAIRS_PER_SHARD=8000000
    SPLIT_LINES=$((READ_PAIRS_PER_SHARD * 4))
    log_info "Low Lambda concurrency ($LAMBDA_CONCURRENCY): using 8M read pairs per shard"
else
    READ_PAIRS_PER_SHARD=4000000
    SPLIT_LINES=$((READ_PAIRS_PER_SHARD * 4))
fi
export READ_PAIRS_PER_SHARD SPLIT_LINES
log_info "Shard policy: $READ_PAIRS_PER_SHARD read pairs ($SPLIT_LINES FASTQ lines) per Lambda"

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
log_info "  Lambda Concurrency:  ${LAMBDA_CONCURRENCY:-unrestricted}"
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

OUTPUT_DIR="$RUN_DIR/output"
mkdir -p "$OUTPUT_DIR"
EXPECTED_RAD_FOLDERS="$RUN_DIR/expected_rad_folders.txt"

process_fastq_bash "$OUTPUT_DIR" "$EXPECTED_RAD_FOLDERS"

if [[ "$EXECUTION_MODE" == "async-submit" ]]; then
    ASYNC_STATE_FILE="$RUN_DIR/async_state.env"
    ASYNC_SUBMITTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$ASYNC_STATE_FILE" <<EOF
RUN_ID=$RUN_ID
DATASET=$DATASET
AWS_REGION=$AWS_REGION
INPUT_FASTQ_BUCKET=$INPUT_FASTQ_BUCKET
INPUT_TXT_BUCKET=$INPUT_TXT_BUCKET
OUTPUT_MAP_BUCKET=$OUTPUT_MAP_BUCKET
OUTPUT_QUANT_BUCKET=$OUTPUT_QUANT_BUCKET
LAMBDA_FUNCTION=$LAMBDA_FUNCTION_NAME
S3_CLAIM_PREFIX=$S3_CLAIM_PREFIX
READ_PAIRS_PER_SHARD=$READ_PAIRS_PER_SHARD
SPLIT_LINES=$SPLIT_LINES
DIRECT_GZIP_MAX_BYTES=$DIRECT_GZIP_MAX_BYTES
EXPECTED_FOLDERS_FILE=$EXPECTED_RAD_FOLDERS
NOT_BEFORE=$(<"${EXPECTED_RAD_FOLDERS}.not-before")
SUBMITTED_AT=$ASYNC_SUBMITTED_AT
EOF
    aws s3 cp "$ASYNC_STATE_FILE" \
        "s3://$OUTPUT_QUANT_BUCKET/$RUN_ID/async_state.env" \
        --region "$AWS_REGION" --only-show-errors
    aws s3 cp "$EXPECTED_RAD_FOLDERS" \
        "s3://$OUTPUT_QUANT_BUCKET/$RUN_ID/expected_rad_folders.txt" \
        --region "$AWS_REGION" --only-show-errors
    log_info "Async submission complete. State: $ASYNC_STATE_FILE"
    log_info "Check progress: bash scripts/async_lambda_control.sh --state $ASYNC_STATE_FILE status"
    log_info "Wait only:      bash scripts/async_lambda_control.sh --state $ASYNC_STATE_FILE wait"
    log_info "Materialize:    bash scripts/async_lambda_control.sh --state $ASYNC_STATE_FILE materialize --output $RUN_DIR/combined/map.rad"
    exit 0
fi

log_info "Step 7 complete"

log_info "Lambda processing complete; non-RAD outputs downloaded to $OUTPUT_DIR"

################################################################################
# Step 8: Combine and Quantify
################################################################################

log_info "Step 8: Installing tools and running combine + alevin-fry quant..."

# Increase file descriptor limit for combine scripts
ulimit -n 2048

bash /home/ubuntu/scrna-repo/install_scripts/install_alevin_fry.sh
bash /home/ubuntu/scrna-repo/install_scripts/install_radtk.sh

if ! command -v s3-rad-materialize >/dev/null 2>&1; then
    _materializer_installer=/home/ubuntu/scrna-repo/install_scripts/install_s3_rad_materializer.sh
    [[ -f "$_materializer_installer" ]] || \
        die "s3-rad-materialize is not installed and installer is missing: $_materializer_installer"
    bash "$_materializer_installer"
fi

log_info "Running combine scripts..."

COMBINED_DIR="$RUN_DIR/combined"
mkdir -p "$COMBINED_DIR"

phase_begin "Parallel S3 .rad materializer [on-server]" 7
bash /home/ubuntu/scrna-repo/scripts/synchronous_s3_rad_materialize.sh \
    --output-bucket "$OUTPUT_MAP_BUCKET" \
    --expected-folders "$EXPECTED_RAD_FOLDERS" \
    --output "$COMBINED_DIR/map.rad" \
    --region "$AWS_REGION" \
    --threads "${MATERIALIZER_THREADS:-32}" \
    --timeout-seconds "$PROCESS_FASTQ_TIMEOUT_SEC" \
    --not-before "$(<"${EXPECTED_RAD_FOLDERS}.not-before")" \
    --timings-file "$RUN_DIR/rad_materializer_timings.csv"
phase_end

phase_begin "Concatenate unmapped_bc_count.bin [on-server]" 7
bash /home/ubuntu/scrna-repo/combine_unmapped_bc_count_bin.sh "$OUTPUT_DIR" "$COMBINED_DIR"
phase_end

log_info "Step 8a (combine) complete"

log_info "Running alevin-fry quant via alevin_process.sh..."

ALEVIN_OUTPUT="$RUN_DIR/alevin_output"
mkdir -p "$ALEVIN_OUTPUT"

TRANSCRIPTOME_GENE_MAPPING="/opt/scrna-seed/reference/t2g.tsv"

phase_begin "Alevin [on-server]" 7
bash /home/ubuntu/scrna-repo/alevin_process.sh "$COMBINED_DIR" "$ALEVIN_OUTPUT" "$TRANSCRIPTOME_GENE_MAPPING"
phase_end

log_info "Step 8b (quant) complete"

log_info "Quantification complete"

################################################################################
# Step 9: Upload Quant Outputs
################################################################################

log_info "Step 9: Uploading quantification outputs to S3..."

phase_begin "Upload Output Files [on-server]" 8
aws s3 sync "$ALEVIN_OUTPUT" "s3://$OUTPUT_QUANT_BUCKET/$RUN_ID/alevin_output/" \
    --region "$AWS_REGION"
phase_end

log_info "Step 9 complete"

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

PISCEM_VERSION=$(piscem --version 2>/dev/null | head -1 || true)
ALEVIN_FRY_VERSION=$(alevin-fry --version 2>/dev/null | head -1 || true)
RADTK_VERSION=$(radtk --version 2>/dev/null | head -1 || true)

# The remote side does not inherit INSTANCE_TYPE from the driver, so reading the
# variable here would record the script default rather than the machine that ran
# the work. Ask the instance itself instead.
_imds_token=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
if [[ -n "$_imds_token" ]]; then
    _imds_type=$(curl -fsS -H "X-aws-ec2-metadata-token: $_imds_token" \
        "http://169.254.169.254/latest/meta-data/instance-type" 2>/dev/null || true)
    [[ -n "$_imds_type" ]] && INSTANCE_TYPE="$_imds_type"
fi
DRIVER_VCPUS=$(nproc 2>/dev/null || echo "")
DRIVER_CPU_MODEL=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "")

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
LAMBDA_CONCURRENCY=${LAMBDA_CONCURRENCY:-unrestricted}
S3_CLAIM_PREFIX=$S3_CLAIM_PREFIX
CLAIM_LEASE_SECONDS=$CLAIM_LEASE_SECONDS
CLAIM_HEARTBEAT_SECONDS=$CLAIM_HEARTBEAT_SECONDS
READ_PAIRS_PER_SHARD=$READ_PAIRS_PER_SHARD
SPLIT_LINES=$SPLIT_LINES
DIRECT_GZIP_MAX_BYTES=$DIRECT_GZIP_MAX_BYTES
ALLOW_DESTRUCTIVE_CLEANUP=$ALLOW_DESTRUCTIVE_CLEANUP
ALLOW_S3_DELETE=$ALLOW_S3_DELETE
CLEANUP_AWS=$CLEANUP_AWS
CLEANUP_RESULTS=$CLEANUP_RESULTS
DELETE_CLOUDWATCH_LOGS=$DELETE_CLOUDWATCH_LOGS
SKIP_PREFLIGHT_CLEANUP=$SKIP_PREFLIGHT_CLEANUP
RUN_DIR=$RUN_DIR
BASENAME_WITH_LANE=$BASENAME_WITH_LANE
PISCEM_VERSION=$PISCEM_VERSION
ALEVIN_FRY_VERSION=$ALEVIN_FRY_VERSION
RADTK_VERSION=$RADTK_VERSION
RUN_QC=$RUN_QC
WRITE_H5AD=$WRITE_H5AD
ARM=serverless
INSTANCE_TYPE=$INSTANCE_TYPE
DRIVER_VCPUS=$DRIVER_VCPUS
DRIVER_CPU_MODEL=$DRIVER_CPU_MODEL
PISCEM_THREADS=${PISCEM_THREADS:-6}
TOTAL_INPUT_BYTES=${TOTAL_INPUT_BYTES:-0}
TOTAL_INPUT_GB=$(awk -v b="${TOTAL_INPUT_BYTES:-0}" 'BEGIN{printf "%.2f", b/1073741824}')
EOF

log_info "Run metadata saved to $RUN_DIR/run.env"

# Publish the metadata and step timings to S3 directly from this instance.
# Retrieving them via the results tarball depends on the SSM transfer, which is
# the least reliable part of the run; a plain S3 copy is not.
for _artifact in run.env timings.csv; do
    if [[ -f "$RUN_DIR/$_artifact" ]]; then
        aws s3 cp "$RUN_DIR/$_artifact" \
            "s3://$OUTPUT_QUANT_BUCKET/$RUN_ID/$_artifact" \
            --region "$AWS_REGION" >/dev/null 2>&1 \
            && log_info "  published $_artifact to s3://$OUTPUT_QUANT_BUCKET/$RUN_ID/"
        if [[ "$DATASET" == "ko" && -n "${KO_FASTQ_CACHE_BUCKET:-}" ]]; then
            aws s3 cp "$RUN_DIR/$_artifact" \
                "s3://$KO_FASTQ_CACHE_BUCKET/results/$RUN_ID/$_artifact" \
                --region "$AWS_REGION" >/dev/null 2>&1 \
                && log_info "  published $_artifact to s3://$KO_FASTQ_CACHE_BUCKET/results/$RUN_ID/"
        fi
    fi
done


################################################################################
# Cleanup
################################################################################

log_info "Step 12: Cleanup..."

if [[ $ALLOW_DESTRUCTIVE_CLEANUP -eq 1 && $CLEANUP_AWS -eq 1 ]]; then
    log_info "Cleaning up AWS resources..."
    
    # Get Lambda ARN before deleting (needed for EventBridge rule discovery)
    LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" \
        --region "$AWS_REGION" --query 'Configuration.FunctionArn' --output text 2>/dev/null || echo "")
    
    # Delete Lambda function
    aws lambda delete-function --function-name "$LAMBDA_FUNCTION_NAME" \
        --region "$AWS_REGION" 2>/dev/null || true
    
    # Delete Lambda CloudWatch log group
    delete_lambda_log_group "$LAMBDA_FUNCTION_NAME" "$AWS_REGION"
    
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
        if [[ "$CLEANUP_RESULTS" -ne 1 && "$bucket" == "$OUTPUT_QUANT_BUCKET" ]]; then
            log_info "Keeping results bucket: $bucket (CLEANUP_RESULTS=0)"
            continue
        fi
        log_info "Deleting bucket: $bucket"
        s3_delete_disabled rm "s3://$bucket" --recursive --region "$AWS_REGION"
        s3_delete_disabled rb "s3://$bucket" --region "$AWS_REGION"
    done
    
    log_info "AWS resources cleaned up"
else
    log_info "Skipping AWS cleanup (ALLOW_DESTRUCTIVE_CLEANUP=$ALLOW_DESTRUCTIVE_CLEANUP, CLEANUP_AWS=$CLEANUP_AWS)"
fi

################################################################################
# Summary
################################################################################

log_info "======== Pipeline Complete ========"
log_info "Run ID: $RUN_ID"
log_info "Dataset: $DATASET"
log_info "Output directory: $RUN_DIR"
log_info "Quantification output: s3://$OUTPUT_QUANT_BUCKET/$RUN_ID/alevin_output/"

if [[ "${CLEANUP_RESULTS:-1}" -ne 1 ]]; then
    log_info "Results bucket preserved (CLEANUP_RESULTS=0). Download later with:"
    log_info "  aws s3 sync s3://$OUTPUT_QUANT_BUCKET/ ./$RUN_ID/ --region $AWS_REGION"
    if [[ -n "${SSM_TRANSFER_BUCKET:-}" ]]; then
        log_info "  aws s3 cp s3://$SSM_TRANSFER_BUCKET/results/${RUN_ID}_results.tgz . --region $AWS_REGION"
    fi
fi

if [[ "${RUN_QC:-0}" == "1" ]]; then
    log_info "QC plots: $RUN_DIR/analysis/out/"
    if [[ $WRITE_H5AD -eq 1 ]]; then
        log_info "H5AD file: $RUN_DIR/analysis/out/pbmc_adata.h5ad"
    fi
fi

log_info "Run.env: $RUN_DIR/run.env"

exit 0
