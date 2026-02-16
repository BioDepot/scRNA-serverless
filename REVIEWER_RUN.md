# Reviewer Run Guide

## Quick Start

This guide helps reviewers reproduce the e2e serverless scRNA-seq pipeline without modifying tracked files or baking credentials into AMIs.

## Prerequisites

Before running, validate your setup:

```bash
bash scripts/e2e_serverless_pbmc.sh pbmc1k --dry-run
```

This checks:
- AWS CLI authentication
- Docker accessibility
- Seed AMI availability
- PEM file exists
- FASTQ URL reachability
- EC2 instance profile exists

## Required AWS Setup

1. **EC2 Keypair**: Create or identify an existing keypair
   ```bash
   aws ec2 create-key-pair --key-name my-scrna-key --query 'KeyMaterial' --output text > ~/my-scrna-key.pem
   chmod 600 ~/my-scrna-key.pem
   ```

2. **IAM Instance Profile**: Create a profile that grants Lambda, S3, IAM, EventBridge, ECR permissions
   ```bash
   # Create role with necessary permissions (see AWS docs for policy)
   aws iam create-instance-profile --instance-profile-name scrna-ec2-profile
   aws iam add-role-to-instance-profile --instance-profile-name scrna-ec2-profile --role-name scrna-ec2-role
   ```

3. **Seed AMI** (one of):
   - Use author's pre-built AMI: `ami-0b80485dc95b72c33` (default)
   - Auto-detect by name prefix:
     ```bash
     export AUTO_DETECT_SEED_AMI=1
     export SEED_AMI_OWNER=<publisher-account-id>
     ```
   - Build custom seed AMI with reference data and tools pre-installed

## Run Pipeline

### 1. Validate Requirements
```bash
bash scripts/e2e_serverless_pbmc.sh pbmc1k --dry-run
```

### 2. Run Full Pipeline (with logs, no cleanup, no termination)

```bash
export KEY_NAME="my-scrna-key"
export KEY_PEM_PATH="$HOME/my-scrna-key.pem"
export EC2_INSTANCE_PROFILE_NAME="scrna-ec2-profile"
export CLEANUP_AWS=0
export TERMINATE_DRIVER_ON_EXIT=0
export RUN_QC=1
export WRITE_H5AD=1

bash scripts/e2e_serverless_pbmc.sh pbmc1k 2>&1 | tee pbmc1k.log
```

### Optional: Auto-Detect Infrastructure

```bash
# Auto-pick subnet from default VPC (enabled by default)
# Auto-create temporary security group (enabled by default)
# Auto-authorize caller IP for SSH (enabled by default)

# Just set credentials and run:
export KEY_NAME="my-scrna-key"
export KEY_PEM_PATH="$HOME/my-scrna-key.pem"
export EC2_INSTANCE_PROFILE_NAME="scrna-ec2-profile"
export RUN_QC=1
export WRITE_H5AD=1

bash scripts/e2e_serverless_pbmc.sh pbmc1k 2>&1 | tee pbmc1k.log
```

## Environment Variables

| Variable | Default | Required? | Notes |
|----------|---------|-----------|-------|
| KEY_NAME | - | Yes | EC2 keypair name |
| KEY_PEM_PATH | - | Yes | Path to private key (e.g., `~/.ssh/id_rsa`) |
| EC2_INSTANCE_PROFILE_NAME | - | Yes | IAM instance profile with sufficient permissions |
| SEED_AMI_ID | ami-0b80485dc95b72c33 | No | Use default (author's AMI) or override |
| AWS_REGION | us-east-2 | No | AWS region |
| INSTANCE_TYPE | m6id.16xlarge | No | EC2 instance type |
| CLEANUP_AWS | 1 | No | Set to 0 to keep AWS resources |
| TERMINATE_DRIVER_ON_EXIT | 1 | No | Set to 0 to keep instance running |
| RUN_QC | 1 | No | Run QC analysis |
| WRITE_H5AD | 0 | No | Save h5ad output from QC |
| AUTO_DETECT_SEED_AMI | 0 | No | Set to 1 to auto-detect by name |
| SEED_AMI_OWNER | self | No | Publisher account ID if auto-detecting |
| AUTO_PICK_SUBNET | 1 | No | Auto-pick subnet from default VPC |
| AUTO_CREATE_SG | 1 | No | Auto-create temparary security group |

## Output

Results are saved to:
- **Local machine**: `./runs/<RUN_ID>/` (if DOWNLOAD_RESULTS=1, default)
- **EC2 instance**: `/mnt/nvme/runs/<RUN_ID>/`
- **S3**: `scrna-output-quant-<ACCOUNT>-<REGION>-<RUN_ID>/`

Key outputs:
- `alevin_output/`: Quantification matrices
- `analysis/out/`: QC plots and metrics
- `analysis/out/pbmc_adata.h5ad`: h5ad object (if WRITE_H5AD=1)

## Troubleshooting

**"Seed AMI not found"**
- Check the AMI ID exists in your account/region
- Use `aws ec2 describe-images --image-ids ami-xxx --region us-east-2`
- Or use auto-detection: `AUTO_DETECT_SEED_AMI=1 SEED_AMI_OWNER=<account-id>`

**"Docker not accessible"**
- Run `docker ps` to verify docker is running
- On Linux, add user to docker group: `sudo usermod -aG docker $USER`

**"AWS authentication failed"**
- Configure AWS credentials: `aws configure`
- Or set env vars: `AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...`

**"FASTQ URL not reachable"**
- Check internet connectivity
- Verify URL is correct (must be direct tar download, not landing page)

**Lambda creation fails with memory/ephemeral limits**
- Set explicit limits: `export LAMBDA_MEMORY_MB=3008 LAMBDA_EPHEMERAL_MB=512`
- Script will auto-fallback to smaller values if needed

## Clean Up

After run completes (if CLEANUP_AWS=0):

```bash
# Delete EC2 instance
aws ec2 terminate-instances --instance-ids i-xxxxx --region us-east-2

# Delete S3 buckets
aws s3 rm s3://scrna-output-quant-<account>-<region>-<run-id> --recursive --region us-east-2
aws s3 rb s3://scrna-output-quant-<account>-<region>-<run-id> --region us-east-2

# Delete security group (after instance termination)
aws ec2 delete-security-group --group-id sg-xxxxx --region us-east-2
```
