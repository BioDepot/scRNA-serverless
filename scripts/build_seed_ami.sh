#!/usr/bin/env bash
################################################################################
# build_seed_ami.sh
#
# MAINTAINER-ONLY TOOL — DO NOT RUN
#
# This script documents how the public seed AMI (ami-079f71ff8e580ef1f) was
# created. It is kept in the repository for reproducibility and transparency
# so reviewers can see exactly how the AMI was built. The AMI is already
# public in us-east-2 and hardcoded in e2e_serverless_pbmc.sh — there is no
# need to rebuild it.
#
# What the seed AMI contains:
#   /opt/scrna-seed/index_output_transcriptome/   (187 MB, 6 piscem index files)
#   /opt/scrna-seed/reference/t2g.tsv             (6.1 MB, 199,138 lines)
#   /opt/scrna-seed/reference/refdata-gex-GRCh38-2020-A.tar.gz  (11 GB)
#
# How reviewers use it:
#   The AMI ID is hardcoded in scripts/e2e_serverless_pbmc.sh as
#   DEFAULT_SEED_AMI_ID. Reviewers just clone the repo and run the pipeline;
#   the script launches an EC2 instance from this public AMI automatically.
#
# How the AMI was built (steps performed by this script):
#   1. Launch a fresh Ubuntu 22.04 EC2 instance
#   2. Upload pre-built piscem index and reference data (from local tar files)
#   3. Extract to /opt/scrna-seed/ and validate checksums
#   4. Create an AMI snapshot from the instance
#   5. Disable "Block Public Access for AMIs" (AWS account-level setting)
#   6. Make the AMI and its EBS snapshot public so any AWS account can use it
#   7. Terminate the build instance
#
################################################################################

set -euo pipefail

################################################################################
# Configuration and validation
################################################################################

# Required environment variables
: "${AWS_REGION:?ERROR: AWS_REGION must be set}"
: "${AWS_ACCOUNT_ID:?ERROR: AWS_ACCOUNT_ID must be set}"
: "${KEY_NAME:?ERROR: KEY_NAME must be set (existing EC2 keypair name)}"
: "${KEY_PEM_PATH:?ERROR: KEY_PEM_PATH must be set (path to .pem file for SSH)}"
: "${SUBNET_ID:?ERROR: SUBNET_ID must be set}"
: "${SECURITY_GROUP_ID:?ERROR: SECURITY_GROUP_ID must be set}"
: "${INDEX_TAR:?ERROR: INDEX_TAR must be set (path to index_output_transcriptome tar.gz)}"
: "${REFERENCE_TAR:?ERROR: REFERENCE_TAR must be set (path to reference tar.gz)}"

# Optional with defaults
SEED_EBS_GB="${SEED_EBS_GB:-120}"
UBUNTU_AMI_ID="${UBUNTU_AMI_ID:-}"
MAKE_PUBLIC="${MAKE_PUBLIC:-1}"
AMI_NAME_PREFIX="${AMI_NAME_PREFIX:-scrna-seed}"
SSH_MAX_ATTEMPTS="${SSH_MAX_ATTEMPTS:-90}"
SSH_SLEEP_SECONDS="${SSH_SLEEP_SECONDS:-10}"
KEEP_INSTANCE_ON_EXIT="${KEEP_INSTANCE_ON_EXIT:-0}"
AMI_WAIT_MAX_ATTEMPTS="${AMI_WAIT_MAX_ATTEMPTS:-240}"
AMI_WAIT_DELAY="${AMI_WAIT_DELAY:-15}"

# Validate required files exist
if [[ ! -f "${KEY_PEM_PATH}" ]]; then
    echo "FAIL: KEY_PEM_PATH does not exist: ${KEY_PEM_PATH}"
    exit 1
fi

if [[ ! -f "${INDEX_TAR}" ]]; then
    echo "FAIL: INDEX_TAR does not exist: ${INDEX_TAR}"
    exit 1
fi

if [[ ! -f "${REFERENCE_TAR}" ]]; then
    echo "FAIL: REFERENCE_TAR does not exist: ${REFERENCE_TAR}"
    exit 1
fi

# Generate timestamp for unique resource names
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
INSTANCE_NAME="seed-ami-builder-${TIMESTAMP}"
AMI_NAME="${AMI_NAME_PREFIX}-${TIMESTAMP}"

echo "======================================================================="
echo "Seed AMI Builder - Maintainer Tool"
echo "========================================================================"
echo "AWS Region:         ${AWS_REGION}"
echo "AWS Account:        ${AWS_ACCOUNT_ID}"
echo "Subnet:             ${SUBNET_ID}"
echo "Security Group:     ${SECURITY_GROUP_ID}"
echo "EBS Size:           ${SEED_EBS_GB} GB"
echo "Instance Name:      ${INSTANCE_NAME}"
echo "Target AMI Name:    ${AMI_NAME}"
echo "Make Public:        ${MAKE_PUBLIC}"
echo "========================================================================"

################################################################################
# Validate caller AWS account
################################################################################

echo ""
echo "Validating caller AWS account..."
CALLER_ACCOUNT=$(aws sts get-caller-identity --region "${AWS_REGION}" --query Account --output text)

if [[ "${CALLER_ACCOUNT}" != "${AWS_ACCOUNT_ID}" ]]; then
    echo "FAIL: AWS account mismatch. Expected ${AWS_ACCOUNT_ID}, but caller is ${CALLER_ACCOUNT}"
    exit 1
fi

echo "PASS: Caller account ${CALLER_ACCOUNT} matches AWS_ACCOUNT_ID ${AWS_ACCOUNT_ID}"

################################################################################
# Validate subnet routing
################################################################################

echo ""
echo "Validating subnet routing..."

# Get VPC for this subnet
SUBNET_VPC=$(aws ec2 describe-subnets \
    --region "${AWS_REGION}" \
    --subnet-ids "${SUBNET_ID}" \
    --query 'Subnets[0].VpcId' \
    --output text)

# Find the route table associated with SUBNET_ID
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --region "${AWS_REGION}" \
    --filters "Name=association.subnet-id,Values=${SUBNET_ID}" \
    --query 'RouteTables[0].RouteTableId' \
    --output text)

if [[ -z "${ROUTE_TABLE_ID}" || "${ROUTE_TABLE_ID}" == "None" ]]; then
    # Subnet uses VPC main route table
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
        --region "${AWS_REGION}" \
        --filters "Name=vpc-id,Values=${SUBNET_VPC}" "Name=association.main,Values=true" \
        --query 'RouteTables[0].RouteTableId' \
        --output text)
fi

if [[ -z "${ROUTE_TABLE_ID}" || "${ROUTE_TABLE_ID}" == "None" ]]; then
    echo "FAIL: Could not find route table for SUBNET_ID=${SUBNET_ID}"
    exit 1
fi

# Verify route table has 0.0.0.0/0 -> igw-* route
IGW_ROUTE=$(aws ec2 describe-route-tables \
    --region "${AWS_REGION}" \
    --route-table-ids "${ROUTE_TABLE_ID}" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
    --output text)

if [[ -z "${IGW_ROUTE}" || "${IGW_ROUTE}" == "None" || ! "${IGW_ROUTE}" =~ ^igw- ]]; then
    echo "FAIL: Subnet route table (${ROUTE_TABLE_ID}) does not have internet gateway route (0.0.0.0/0 -> igw-*)"
    echo "SUBNET_ID: ${SUBNET_ID}"
    echo "ROUTE_TABLE_ID: ${ROUTE_TABLE_ID}"
    exit 1
fi

echo "PASS: Subnet has correct internet gateway route (0.0.0.0/0 -> ${IGW_ROUTE})"

################################################################################
# Cleanup trap
################################################################################

INSTANCE_ID=""
INSTANCE_IP=""
AMI_ID=""
LAST_SSH_ERR=""
PRESERVE_INSTANCE_ON_EXIT=0

cleanup() {
    local exit_code=$?
    echo ""
    echo "========================================================================"
    echo "Cleanup: Terminating resources..."
    echo "========================================================================"
    
    if [[ -n "${INSTANCE_ID}" ]]; then
        # Check if instance should be preserved (e.g., AMI still pending)
        if [[ ${PRESERVE_INSTANCE_ON_EXIT} -eq 1 ]]; then
            echo "Instance ${INSTANCE_ID} preserved in STOPPED state."
            echo "To terminate manually after AMI is available, run:"
            echo "  aws ec2 terminate-instances --instance-ids ${INSTANCE_ID} --region ${AWS_REGION}"
            return
        fi
        
        if [[ ${KEEP_INSTANCE_ON_EXIT} -eq 1 && ${exit_code} -ne 0 ]]; then
            echo "DEBUG: KEEP_INSTANCE_ON_EXIT=1, preserving instance for debugging"
            echo "Instance ID: ${INSTANCE_ID}"
            echo "Instance IP: ${INSTANCE_IP}"
            echo "To terminate manually, run:"
            echo "  aws ec2 terminate-instances --instance-ids ${INSTANCE_ID} --region ${AWS_REGION}"
        else
            echo "Terminating instance: ${INSTANCE_ID}"
            aws ec2 terminate-instances \
                --instance-ids "${INSTANCE_ID}" \
                --region "${AWS_REGION}" \
                --output text >/dev/null 2>&1 || true
            
            echo "Waiting for instance to terminate..."
            aws ec2 wait instance-terminated \
                --instance-ids "${INSTANCE_ID}" \
                --region "${AWS_REGION}" 2>/dev/null || true
            echo "Instance terminated."
        fi
    fi
    
    if [[ ${exit_code} -ne 0 ]]; then
        echo "FAIL: Script failed with exit code ${exit_code}"
        if [[ -n "${AMI_ID}" ]]; then
            echo "Note: AMI ${AMI_ID} was created but may be incomplete."
        fi
    fi
}

trap cleanup EXIT

################################################################################
# Find Ubuntu 22.04 AMI if not provided
################################################################################

if [[ -z "${UBUNTU_AMI_ID}" ]]; then
    echo "Looking up latest Ubuntu 22.04 LTS AMI in ${AWS_REGION}..."
    UBUNTU_AMI_ID=$(aws ec2 describe-images \
        --region "${AWS_REGION}" \
        --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text)
    
    if [[ -z "${UBUNTU_AMI_ID}" || "${UBUNTU_AMI_ID}" == "None" ]]; then
        echo "FAIL: Could not find Ubuntu 22.04 AMI in ${AWS_REGION}"
        exit 1
    fi
    echo "Found Ubuntu AMI: ${UBUNTU_AMI_ID}"
fi

################################################################################
# Launch EC2 instance
################################################################################

echo ""
echo "========================================================================"
echo "Step 1: Launching EC2 instance..."
echo "========================================================================"

INSTANCE_ID=$(aws ec2 run-instances \
    --region "${AWS_REGION}" \
    --image-id "${UBUNTU_AMI_ID}" \
    --instance-type t3.xlarge \
    --key-name "${KEY_NAME}" \
    --network-interfaces "DeviceIndex=0,SubnetId=${SUBNET_ID},Groups=${SECURITY_GROUP_ID},AssociatePublicIpAddress=true" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${SEED_EBS_GB},\"VolumeType\":\"gp3\"}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

if [[ -z "${INSTANCE_ID}" ]]; then
    echo "FAIL: Failed to launch instance"
    exit 1
fi

echo "Instance launched: ${INSTANCE_ID}"
echo "Waiting for instance to be running..."

aws ec2 wait instance-running \
    --instance-ids "${INSTANCE_ID}" \
    --region "${AWS_REGION}"

echo "Instance is running."

################################################################################
# Get instance IP and wait for SSH
################################################################################

echo ""
echo "========================================================================"
echo "Step 2: Waiting for SSH to be ready..."
echo "========================================================================"

# Poll for public IP (may take a few seconds after instance is running)
INSTANCE_IP=""
for i in {1..10}; do
    INSTANCE_IP=$(aws ec2 describe-instances \
        --region "${AWS_REGION}" \
        --instance-ids "${INSTANCE_ID}" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    if [[ -n "${INSTANCE_IP}" && "${INSTANCE_IP}" != "None" ]]; then
        break
    fi
    echo "Waiting for public IP (attempt ${i}/10)..."
    sleep 3
done

if [[ -z "${INSTANCE_IP}" || "${INSTANCE_IP}" == "None" ]]; then
    echo "FAIL: Instance has no public IPv4. Use a public subnet or enable auto-assign public IPv4 on the subnet. SUBNET_ID=${SUBNET_ID} INSTANCE_ID=${INSTANCE_ID}"
    exit 1
fi

echo "Instance IP: ${INSTANCE_IP}"

# Auto-update security group with current public IP before SSH
echo "Detecting local public IP and authorizing SSH access in security group..."
LOCAL_PUBLIC_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com | tr -d ' \n')
if [[ -n "${LOCAL_PUBLIC_IP}" ]]; then
    echo "  Local public IP: ${LOCAL_PUBLIC_IP}"
    # Try to authorize; ignore errors if rule already exists
    aws ec2 authorize-security-group-ingress \
        --region "${AWS_REGION}" \
        --group-id "${SECURITY_GROUP_ID}" \
        --protocol tcp \
        --port 22 \
        --cidr "${LOCAL_PUBLIC_IP}/32" \
        >/dev/null 2>&1 || true
    echo "  Authorized SSH access for ${LOCAL_PUBLIC_IP}/32"
else
    echo "WARNING: Could not detect local public IP; SSH may timeout if SG rules are restrictive"
fi

# Wait for SSH to be ready (configurable attempts and sleep)
echo "SSH_MAX_ATTEMPTS: ${SSH_MAX_ATTEMPTS}, SSH_SLEEP_SECONDS: ${SSH_SLEEP_SECONDS}"
SSH_READY=0
for i in $(seq 1 ${SSH_MAX_ATTEMPTS}); do
    # Refresh SG authorization every 5 attempts in case IP changed
    if [[ $((i % 5)) -eq 1 ]] && [[ ${i} -gt 1 ]]; then
        REFRESH_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com | tr -d ' \n')
        if [[ -n "${REFRESH_IP}" && "${REFRESH_IP}" != "${LOCAL_PUBLIC_IP}" ]]; then
            echo "  IP changed detected (${LOCAL_PUBLIC_IP} → ${REFRESH_IP}); updating SG..."
            aws ec2 authorize-security-group-ingress \
                --region "${AWS_REGION}" \
                --group-id "${SECURITY_GROUP_ID}" \
                --protocol tcp \
                --port 22 \
                --cidr "${REFRESH_IP}/32" \
                >/dev/null 2>&1 || true
            LOCAL_PUBLIC_IP="${REFRESH_IP}"
        fi
    fi
    echo "Checking SSH (attempt ${i}/${SSH_MAX_ATTEMPTS})..."
    set +e
    LAST_SSH_ERR=$( ssh -i "${KEY_PEM_PATH}" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=5 \
           -o BatchMode=yes \
           -o ServerAliveInterval=30 \
           -o ServerAliveCountMax=120 \
           "ubuntu@${INSTANCE_IP}" \
           "echo READY" 2>&1 )
    SSH_RC=$?
    set -e
    if [[ ${SSH_RC} -eq 0 ]]; then
        SSH_READY=1
        echo "SSH is ready!"
        break
    fi
    if [[ ${i} -lt ${SSH_MAX_ATTEMPTS} ]]; then
        sleep ${SSH_SLEEP_SECONDS}
    fi
done

if [[ ${SSH_READY} -eq 0 ]]; then
    echo ""
    echo "========================================================================"
    echo "SSH Connection Failed - Diagnostic Report"
    echo "========================================================================"
    echo "Instance ID: ${INSTANCE_ID}"
    echo "Instance IP: ${INSTANCE_IP}"
    echo ""
    echo "Testing TCP port 22 connectivity..."
    if (echo >/dev/tcp/${INSTANCE_IP}/22) >/dev/null 2>&1; then
        echo "  PORT 22: OPEN (network reachable)"
    else
        echo "  PORT 22: CLOSED or unreachable (network issue)"
    fi
    echo ""
    echo "Last SSH error:"
    echo "${LAST_SSH_ERR}"
    echo "========================================================================"
    echo "FAIL: SSH never became ready"
    exit 1
fi

################################################################################
# Upload tar files
################################################################################

echo ""
echo "========================================================================"
echo "Step 3: Uploading reference data..."
echo "========================================================================"

echo "Uploading INDEX_TAR ($(du -h "${INDEX_TAR}" | cut -f1))..."
scp -i "${KEY_PEM_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=120 \
    "${INDEX_TAR}" \
    "ubuntu@${INSTANCE_IP}:/tmp/index.tar.gz"

echo "Uploading REFERENCE_TAR ($(du -h "${REFERENCE_TAR}" | cut -f1))..."
scp -i "${KEY_PEM_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=120 \
    "${REFERENCE_TAR}" \
    "ubuntu@${INSTANCE_IP}:/tmp/reference.tar.gz"

echo "Upload complete."

################################################################################
# Extract and organize data on instance
################################################################################

echo ""
echo "========================================================================"
echo "Step 4: Extracting and organizing data..."
echo "========================================================================"

ssh -i "${KEY_PEM_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=120 \
    "ubuntu@${INSTANCE_IP}" bash <<'EOF'
set -euo pipefail

echo "Creating /opt/scrna-seed directory..."
sudo mkdir -p /opt/scrna-seed
sudo rm -rf /opt/scrna-seed/index_output_transcriptome /opt/scrna-seed/reference

# ---- INDEX TAR ----
echo "Extracting index_output_transcriptome..."
idx_tmp=$(mktemp -d)
tar -xzf /tmp/index.tar.gz -C "$idx_tmp"
if [[ -d "$idx_tmp/index_output_transcriptome" ]]; then
  echo "  Found index_output_transcriptome/ folder in archive"
  sudo mv "$idx_tmp/index_output_transcriptome" /opt/scrna-seed/
else
  echo "  Archive contains files directly, creating index_output_transcriptome/"
  sudo mkdir -p /opt/scrna-seed/index_output_transcriptome
  shopt -s dotglob nullglob
  sudo mv "$idx_tmp"/* /opt/scrna-seed/index_output_transcriptome/
fi
rm -rf "$idx_tmp"

# ---- REFERENCE TAR ----
echo "Extracting reference..."
ref_tmp=$(mktemp -d)
tar -xzf /tmp/reference.tar.gz -C "$ref_tmp"
if [[ -d "$ref_tmp/reference" ]]; then
  echo "  Found reference/ folder in archive"
  sudo mv "$ref_tmp/reference" /opt/scrna-seed/
else
  echo "  Archive contains files directly, creating reference/"
  sudo mkdir -p /opt/scrna-seed/reference
  shopt -s dotglob nullglob
  sudo mv "$ref_tmp"/* /opt/scrna-seed/reference/
fi
rm -rf "$ref_tmp"

# Set permissions and show structure
sudo chmod -R a+rX /opt/scrna-seed
sudo ls -lah /opt/scrna-seed
sudo du -sh /opt/scrna-seed/index_output_transcriptome /opt/scrna-seed/reference

# Clean up tar files
echo "Cleaning up temporary files..."
rm -f /tmp/index.tar.gz /tmp/reference.tar.gz

echo "Extraction complete."
EOF

################################################################################
# Validate extracted data
################################################################################

echo ""
echo "========================================================================"
echo "Step 5: Validating extracted data..."
echo "========================================================================"

ssh -i "${KEY_PEM_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=120 \
    "ubuntu@${INSTANCE_IP}" bash <<'EOF'
set -euo pipefail

echo "Checking /opt/scrna-seed/index_output_transcriptome..."
if [[ ! -d "/opt/scrna-seed/index_output_transcriptome" ]]; then
    echo "FAIL: /opt/scrna-seed/index_output_transcriptome does not exist"
    exit 1
fi

INDEX_SIZE=$(sudo du -sh /opt/scrna-seed/index_output_transcriptome | cut -f1)
INDEX_FILES=$(sudo find /opt/scrna-seed/index_output_transcriptome -type f | wc -l)
echo "  Size: ${INDEX_SIZE}, Files: ${INDEX_FILES}"

if [[ ${INDEX_FILES} -eq 0 ]]; then
    echo "FAIL: index_output_transcriptome is empty (no files found)"
    exit 1
fi

echo "Checking /opt/scrna-seed/reference..."
if [[ ! -d "/opt/scrna-seed/reference" ]]; then
    echo "FAIL: /opt/scrna-seed/reference does not exist"
    exit 1
fi

REF_SIZE=$(sudo du -sh /opt/scrna-seed/reference | cut -f1)
REF_FILES=$(sudo find /opt/scrna-seed/reference -type f | wc -l)
echo "  Size: ${REF_SIZE}, Files: ${REF_FILES}"

if [[ ${REF_FILES} -eq 0 ]]; then
    echo "FAIL: reference is empty (no files found)"
    exit 1
fi

echo "Checking for unexpected files in /opt/scrna-seed..."
UNEXPECTED=$(sudo find /opt/scrna-seed -maxdepth 1 -mindepth 1 ! -name 'index_output_transcriptome' ! -name 'reference' | wc -l)
if [[ ${UNEXPECTED} -gt 0 ]]; then
    echo "FAIL: Unexpected files/directories found in /opt/scrna-seed:"
    sudo find /opt/scrna-seed -maxdepth 1 -mindepth 1 ! -name 'index_output_transcriptome' ! -name 'reference'
    exit 1
fi

echo "Listing reference files:"
sudo ls -lh /opt/scrna-seed/reference/

echo "PASS: All data validated successfully."
EOF

################################################################################
# Create AMI
################################################################################

echo ""
echo "========================================================================"
echo "Step 6: Creating AMI..."
echo "========================================================================"

echo "Creating AMI: ${AMI_NAME}"
AMI_ID=$(aws ec2 create-image \
    --instance-id "${INSTANCE_ID}" \
    --name "${AMI_NAME}" \
    --description "Seed AMI for scRNA-serverless pipeline with pre-installed reference data" \
    --region "${AWS_REGION}" \
    --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=${AMI_NAME}},{Key=Purpose,Value=scRNA-serverless-seed}]" \
    --query 'ImageId' \
    --output text)

if [[ -z "${AMI_ID}" ]]; then
    echo "FAIL: Failed to create AMI"
    exit 1
fi

echo "AMI creation initiated: ${AMI_ID}"

echo "Stopping instance to reduce compute cost while AMI snapshot completes..."
aws ec2 stop-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --output text >/dev/null

echo "Waiting for instance to stop..."
aws ec2 wait instance-stopped \
    --instance-ids "${INSTANCE_ID}" \
    --region "${AWS_REGION}"

echo "Instance stopped. Waiting for AMI to become available (max attempts: ${AMI_WAIT_MAX_ATTEMPTS}, delay: ${AMI_WAIT_DELAY}s)..."
echo "This may take several minutes for large snapshots."

# Attempt to wait for AMI availability with configurable timeout
set +e
aws ec2 wait image-available \
    --image-ids "${AMI_ID}" \
    --region "${AWS_REGION}" \
    --max-attempts "${AMI_WAIT_MAX_ATTEMPTS}" \
    --delay "${AMI_WAIT_DELAY}"
WAIT_EXIT_CODE=$?
set -e

AMI_AVAILABLE=0

if [[ ${WAIT_EXIT_CODE} -eq 0 ]]; then
    echo "AMI is available: ${AMI_ID}"
    AMI_AVAILABLE=1
    
    # Terminate instance if KEEP_INSTANCE_ON_EXIT is not set to 1
    if [[ ${KEEP_INSTANCE_ON_EXIT} -ne 1 ]]; then
        echo "Terminating instance ${INSTANCE_ID}..."
        aws ec2 terminate-instances \
            --instance-ids "${INSTANCE_ID}" \
            --region "${AWS_REGION}" \
            --output text >/dev/null
        echo "Instance ${INSTANCE_ID} terminated."
        # Prevent cleanup() from trying to terminate again
        INSTANCE_ID=""
    else
        echo "KEEP_INSTANCE_ON_EXIT=1 is set. Instance ${INSTANCE_ID} left in stopped state."
        echo "To terminate manually after AMI is available, run:"
        echo "  aws ec2 terminate-instances --instance-ids ${INSTANCE_ID} --region ${AWS_REGION}"
        # Preserve instance on exit
        PRESERVE_INSTANCE_ON_EXIT=1
    fi
else
    echo "WARN: Wait for AMI timed out after ${AMI_WAIT_MAX_ATTEMPTS} attempts (exit code: ${WAIT_EXIT_CODE})."
    echo "This does not necessarily mean AMI creation failed - it may still be in progress."
    echo ""
    
    # Query current AMI state and snapshot progress
    echo "Querying current AMI state..."
    AMI_STATE=$(aws ec2 describe-images \
        --region "${AWS_REGION}" \
        --image-ids "${AMI_ID}" \
        --query 'Images[0].State' \
        --output text 2>/dev/null || echo "unknown")
    
    echo "AMI State: ${AMI_STATE}"
    
    # Get snapshot ID and progress
    SNAPSHOT_ID=$(aws ec2 describe-images \
        --region "${AWS_REGION}" \
        --image-ids "${AMI_ID}" \
        --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' \
        --output text 2>/dev/null || echo "unknown")
    
    if [[ "${SNAPSHOT_ID}" != "unknown" && "${SNAPSHOT_ID}" != "None" ]]; then
        SNAPSHOT_STATE=$(aws ec2 describe-snapshots \
            --region "${AWS_REGION}" \
            --snapshot-ids "${SNAPSHOT_ID}" \
            --query 'Snapshots[0].State' \
            --output text 2>/dev/null || echo "unknown")
        
        SNAPSHOT_PROGRESS=$(aws ec2 describe-snapshots \
            --region "${AWS_REGION}" \
            --snapshot-ids "${SNAPSHOT_ID}" \
            --query 'Snapshots[0].Progress' \
            --output text 2>/dev/null || echo "unknown")
        
        echo "Snapshot ID: ${SNAPSHOT_ID}"
        echo "Snapshot State: ${SNAPSHOT_STATE}"
        echo "Snapshot Progress: ${SNAPSHOT_PROGRESS}"
    fi
    
    echo ""
    echo "Instance ${INSTANCE_ID} has been STOPPED to minimize cost."
    echo ""
    echo "To check AMI status later, run:"
    echo "  aws ec2 describe-images --region ${AWS_REGION} --image-ids ${AMI_ID} --query 'Images[0].[ImageId,State,Name,CreationDate]' --output table"
    echo ""
    
    if [[ "${SNAPSHOT_ID}" != "unknown" && "${SNAPSHOT_ID}" != "None" ]]; then
        echo "To check snapshot progress, run:"
        echo "  aws ec2 describe-snapshots --region ${AWS_REGION} --snapshot-ids ${SNAPSHOT_ID} --query 'Snapshots[0].[SnapshotId,State,Progress,VolumeSize]' --output table"
        echo ""
    fi
    
    echo "Once AMI state becomes 'available', terminate the instance with:"
    echo "  aws ec2 terminate-instances --region ${AWS_REGION} --instance-ids ${INSTANCE_ID}"
    echo ""
    
    if [[ "${AMI_STATE}" == "pending" ]]; then
        echo "AMI is still pending - snapshot creation is in progress."
        echo "This is normal for large EBS volumes. The AMI will become available when snapshotting completes."
        
        echo ""
        echo "========================================================================"
        echo "AMI Creation In Progress: ${AMI_ID}"
        echo "========================================================================"
        echo "AMI ID:         ${AMI_ID}"
        echo "AMI Name:       ${AMI_NAME}"
        echo "AMI State:      ${AMI_STATE}"
        echo "Instance ID:    ${INSTANCE_ID} (STOPPED)"
        echo "Region:         ${AWS_REGION}"
        echo ""
        echo "The AMI snapshot is still processing. Check back later using the"
        echo "commands printed above. Once available, you can terminate the instance."
        echo "========================================================================"
        
        # Preserve the stopped instance (don't let cleanup() terminate it)
        PRESERVE_INSTANCE_ON_EXIT=1
        exit 0
        
    elif [[ "${AMI_STATE}" == "failed" ]]; then
        echo "ERROR: AMI creation failed. Check AWS console for details."
        echo "Instance ${INSTANCE_ID} left in stopped state for troubleshooting."
        
        echo ""
        echo "========================================================================"
        echo "AMI Creation Failed: ${AMI_ID}"
        echo "========================================================================"
        echo "AMI ID:         ${AMI_ID}"
        echo "AMI Name:       ${AMI_NAME}"
        echo "AMI State:      ${AMI_STATE}"
        echo "Instance ID:    ${INSTANCE_ID} (STOPPED)"
        echo "Region:         ${AWS_REGION}"
        echo "========================================================================"
        
        # Preserve the stopped instance for troubleshooting
        PRESERVE_INSTANCE_ON_EXIT=1
        exit 1
        
    else
        # Unknown state (neither pending nor failed)
        echo "WARN: AMI state is '${AMI_STATE}' - unexpected state."
        echo ""
        echo "========================================================================"
        echo "AMI Status Unknown: ${AMI_ID}"
        echo "========================================================================"
        echo "AMI ID:         ${AMI_ID}"
        echo "AMI Name:       ${AMI_NAME}"
        echo "AMI State:      ${AMI_STATE}"
        echo "Instance ID:    ${INSTANCE_ID} (STOPPED)"
        echo "Region:         ${AWS_REGION}"
        echo "========================================================================"
        
        # Preserve the stopped instance to be safe
        PRESERVE_INSTANCE_ON_EXIT=1
        exit 0
    fi
fi

################################################################################
# Make AMI public if requested
################################################################################

if [[ ${MAKE_PUBLIC} -eq 1 && ${AMI_AVAILABLE} -eq 1 ]]; then
    echo ""
    echo "========================================================================"
    echo "Step 7: Making AMI public..."
    echo "========================================================================"

    # AWS accounts have "Block Public Access for AMIs" enabled by default.
    # This must be disabled before an AMI can be shared publicly.
    echo "Disabling 'Block Public Access for AMIs' (account-level setting)..."
    BPA_STATE=$(aws ec2 disable-image-block-public-access \
        --region "${AWS_REGION}" \
        --query 'ImageBlockPublicAccessState' \
        --output text)
    echo "  Block Public Access state: ${BPA_STATE}"
    sleep 5
    
    # Check for encrypted root snapshot before attempting to make public
    echo "Checking if AMI root snapshot is encrypted..."
    
    ROOT_DEV=$(aws ec2 describe-images \
        --image-ids "${AMI_ID}" \
        --region "${AWS_REGION}" \
        --query 'Images[0].RootDeviceName' \
        --output text)
    
    SNAP_ID=$(aws ec2 describe-images \
        --image-ids "${AMI_ID}" \
        --region "${AWS_REGION}" \
        --query "Images[0].BlockDeviceMappings[?DeviceName=='${ROOT_DEV}'].Ebs.SnapshotId | [0]" \
        --output text)
    
    if [[ -z "${SNAP_ID}" || "${SNAP_ID}" == "None" ]]; then
        echo "FAIL: Could not find root snapshot ID for AMI ${AMI_ID}"
        exit 1
    fi
    
    echo "Root snapshot: ${SNAP_ID}"
    
    ENC=$(aws ec2 describe-snapshots \
        --snapshot-ids "${SNAP_ID}" \
        --region "${AWS_REGION}" \
        --query 'Snapshots[0].Encrypted' \
        --output text)
    
    if [[ "${ENC}" == "true" ]]; then
        echo "FAIL: Root snapshot is encrypted; public AMIs cannot use encrypted snapshots. Disable default EBS encryption or run with MAKE_PUBLIC=0."
        exit 1
    fi
    
    echo "Root snapshot is not encrypted. Proceeding to make AMI public..."
    
    # Collect all snapshot IDs from BlockDeviceMappings and make them publicly launchable
    echo "Making all AMI snapshots publicly launchable..."
    
    SNAPSHOT_IDS=$(aws ec2 describe-images \
        --image-ids "${AMI_ID}" \
        --region "${AWS_REGION}" \
        --query 'Images[0].BlockDeviceMappings[?Ebs.SnapshotId].Ebs.SnapshotId' \
        --output text)
    
    if [[ -z "${SNAPSHOT_IDS}" ]]; then
        echo "FAIL: Could not find any snapshots for AMI ${AMI_ID}"
        exit 1
    fi
    
    # Deduplicate and process each snapshot
    declare -A seen_snaps
    for snap_id in ${SNAPSHOT_IDS}; do
        if [[ -z "${seen_snaps[${snap_id}]:-}" ]]; then
            seen_snaps["${snap_id}"]=1
            echo "  Making snapshot ${snap_id} publicly launchable..."
            if ! aws ec2 modify-snapshot-attribute \
                --snapshot-id "${snap_id}" \
                --attribute createVolumePermission \
                --operation-type add \
                --group-names all \
                --region "${AWS_REGION}"; then
                echo "FAIL: Could not modify snapshot ${snap_id} to be publicly launchable"
                exit 1
            fi
        fi
    done
    
    echo "All snapshots are now publicly launchable."
    
    # Make the AMI public
    aws ec2 modify-image-attribute \
        --image-id "${AMI_ID}" \
        --launch-permission "Add=[{Group=all}]" \
        --region "${AWS_REGION}"
    
    echo "AMI is now public."
fi

################################################################################
# Success
################################################################################

echo ""
echo "========================================================================"
echo "PASS: Created AMI ${AMI_ID} (name: ${AMI_NAME})"
echo "========================================================================"
echo "AMI ID:     ${AMI_ID}"
echo "AMI Name:   ${AMI_NAME}"
echo "Region:     ${AWS_REGION}"
echo "Public:     $(if [[ ${MAKE_PUBLIC} -eq 1 ]]; then echo 'Yes'; else echo 'No'; fi)"
echo ""
echo "The AMI contains:"
echo "  /opt/scrna-seed/index_output_transcriptome/"
echo "  /opt/scrna-seed/reference/"
echo ""
echo "Next steps:"
echo "  1. Update DEFAULT_SEED_AMI_ID in scripts/e2e_serverless_pbmc.sh"
echo "     with the AMI ID printed above."
echo "  2. Reviewers can then clone the repo and run:"
echo "       bash scripts/e2e_serverless_pbmc.sh pbmc1k"
echo "     The script will automatically launch an EC2 instance from this AMI."
echo "========================================================================"

exit 0
