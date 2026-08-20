# Serverless Pipeline Guide

The pipeline launches an EC2 instance from a pre-built AMI, maps reads in parallel using AWS Lambda, then runs alevin-fry on the EC2 instance to produce the final count matrix.

> **Region:** Everything runs in **us-east-2 (Ohio)**. The script enforces this automatically.

---

## Requirements

**Tested on:** Windows (Git Bash).

**Local software:**
- [Git for Windows](https://gitforwindows.org/) (includes Git Bash)
- [AWS CLI v2](https://aws.amazon.com/cli/) — verify with `aws --version`

**AWS account:**
- Valid access key configured via `aws configure`
- An IAM role with `AdministratorAccess` (created in Step C below)
- An EC2 keypair in us-east-2 (created in Step D below)

**EC2 instance:** The script launches **m5dn.8xlarge** (32 vCPU, two NVMe disks). That is the machine used for the completed 1K, 10K, and KO runs. You do not launch the instance yourself. If that type is unavailable, the script tries smaller types. See [Reproducibility Notes](REPRODUCIBILITY_NOTES.md).

**Storage:** The script creates a 500 GB EBS root volume (matching the paper). A 500 GB volume for a 15-minute run costs ~$0.03-$0.05. Override with `export ROOT_VOL_GB=50` for PBMC 1K.

**Local disk space:** Keep at least **5 GB free** (PBMC 1K) or **30 GB free** (PBMC 10K) on the drive where you cloned this repository. The script creates a temporary file during setup and downloads results to `serverless_runs/`.

---

## Setup (one-time)

### A) Install software

1. Install **Git for Windows** (includes Git Bash).
2. Install **AWS CLI v2**. Verify:

```bash
aws --version
```

### B) Configure AWS credentials

1. In the AWS Console: click your **username** (top right) → **Security credentials** → **Access keys** → **Create access key**. Follow the prompts; choose "Command Line Interface (CLI)" if asked. **Save the Access Key ID and Secret Access Key** — the secret is shown only once.
2. Open **Git Bash** and run:

```bash
aws configure
```

3. When prompted, enter:
   - **AWS Access Key ID:** (paste the Access Key ID you saved)
   - **AWS Secret Access Key:** (paste the Secret Access Key you saved)
   - **Default region name:** `us-east-2`
   - **Default output format:** `json`

4. Verify:

```bash
aws sts get-caller-identity
```

**If this fails, stop.** Fix credentials before continuing.

### C) Create IAM role

1. AWS Console → **IAM → Roles → Create role**
2. **Trusted entity type:** select **AWS service**
3. **Use case:** select **EC2** (so the role can be used by EC2 instances) → Next
4. Search `AdministratorAccess`, check it → Next
5. Role name: `scrna-serverless-ec2-role` → Create role

This role name is your `EC2_INSTANCE_PROFILE_NAME`.

### D) Create EC2 keypair + fix PEM permissions

**Create the keypair:**

1. AWS Console → **EC2 → Key Pairs** (make sure region is **us-east-2**)
2. Create key pair: name `scrna-reviewer-key`, type **RSA**, format **.pem**
3. Save the downloaded `.pem` file to a permanent location (e.g. `D:\Keys\scrna-reviewer-key.pem`)

**Fix PEM permissions** (run in **PowerShell**, not Git Bash):

```powershell
$Pem = "D:\Keys\scrna-reviewer-key.pem"
icacls "$Pem" /inheritance:r
icacls "$Pem" /grant:r "$($env:USERNAME):R"
icacls "$Pem" /grant:r "Administrators:R"
icacls "$Pem" /grant:r "SYSTEM:R"
icacls "$Pem" /remove "Users" "Everyone"
```

Use the path where you saved your `.pem` file in place of `D:\Keys\scrna-reviewer-key.pem`.

### E) Clone the repository

```bash
git clone https://github.com/BioDepot/scRNA-serverless.git
cd scRNA-serverless
```

---

## Running the pipeline

### F) Open Git Bash and set environment variables

All commands below must be run in **Git Bash** (not PowerShell, CMD, or WSL). Verify with `uname -a` — you should see `MINGW` or `MSYS`.

Set these every time before a run:

```bash
export AWS_REGION="us-east-2"
export SEED_AMI_ID="ami-079f71ff8e580ef1f"
export EC2_INSTANCE_PROFILE_NAME="scrna-serverless-ec2-role"
export KEY_NAME="scrna-reviewer-key"
export KEY_PEM_PATH="/d/Keys/scrna-reviewer-key.pem"
chmod 600 "$KEY_PEM_PATH" 2>/dev/null || true
```

- `AWS_REGION` and `SEED_AMI_ID` — do not change these.
- `EC2_INSTANCE_PROFILE_NAME` — the role name from Step C.
- `KEY_NAME` — the keypair name from Step D (without `.pem`).
- `KEY_PEM_PATH` — full path to your `.pem` file. Use forward slashes on Windows (e.g. `/d/Keys/...`).

### G) Dry run (recommended first)

```bash
bash scripts/e2e_serverless_pbmc.sh pbmc1k --dry-run
```

Checks credentials, AMI, subnet, security group, instance profile, and keypair. Costs nothing.

### H) Run the pipeline

Each of these uses m5dn.8xlarge, RAID 0 on both NVMe disks, rapidgzip `-P 8`, and 2 lanes at a time. No extra flags.

> **Do not run two datasets at the same time.** Each run shares AWS resources that are cleaned up when it finishes.

Run one dataset, wait until it finishes, then run the next.

**Minimal first run** (no QC, keep resources for inspection):

```bash
export CLEANUP_AWS=0 CLEANUP_RESULTS=0 TERMINATE_DRIVER_ON_EXIT=0
export RUN_QC=0 WRITE_H5AD=0
bash scripts/e2e_serverless_pbmc.sh pbmc1k
```

**Full run** (QC + h5ad + auto-cleanup):

```bash
bash scripts/e2e_serverless_pbmc.sh pbmc1k
```

**PBMC 10K:**

```bash
bash scripts/e2e_serverless_pbmc.sh pbmc10k
```

**MSK KO:**

```bash
bash scripts/e2e_serverless_pbmc.sh ko
```

KO uses the same RAID 0, rapidgzip `-P 8`, and lane-concurrency settings as 1K/10K. QC and the local results download are turned off (the matrix is huge). `timings.csv` stays on the instance and in the run log. Set `DOWNLOAD_KO_RESULTS=1` only if you really want the matrix copied home.

**PBMC 10K on slow wifi** (skip download, fetch results later):

```bash
export DOWNLOAD_RESULTS=0 CLEANUP_RESULTS=0
bash scripts/e2e_serverless_pbmc.sh pbmc10k
```

The pipeline prints the S3 bucket name and download commands at the end. Download at your own pace, then delete the bucket manually.

The log is saved automatically to `serverless_runs/<RUN_ID>.log`.

---

## What the pipeline does

1. Launches an EC2 instance from the public seed AMI
2. Uploads the repository code to the instance
3. If two or more NVMe instance-store disks are present, stripes them as RAID 0 at `/mnt/nvme`
4. Builds a Docker image with piscem + reference index, pushes to ECR
5. Creates S3 buckets, Lambda function, and EventBridge rule
6. Downloads FASTQs. Split and Upload uses rapidgzip `-P 8` per stream and only as many lanes at once as fit on the box
7. Lambda functions map each split in parallel (piscem)
8. If mapping stops making progress for longer than the Lambda timeout plus 3 minutes, the script exits and lists the missing shards
9. Downloads the non-RAD Lambda outputs and concurrently range-materializes the S3 `map.rad` shards into one local `combined/map.rad`
10. Runs alevin-fry (generate-permit-list, collate, quant)
11. Runs QC (optional), downloads results locally, cleans up

---

## Optional flags

| Flag | Default | Effect |
|---|---|---|
| `RUN_QC` | `1` | QC analysis (UMAP + violin). `0` to skip. |
| `WRITE_H5AD` | `1` | Save `.h5ad` file. Needs `RUN_QC=1`. |
| `ALLOW_DESTRUCTIVE_CLEANUP` | `0` | Master cleanup gate. Must be `1` before any AWS cleanup can run. |
| `ALLOW_S3_DELETE` | `0` | Additional gate required before any S3 object or bucket deletion. |
| `CLEANUP_AWS` | `0` | Request AWS resource cleanup; also requires the master gate. |
| `CLEANUP_RESULTS` | `0` | Request results-bucket cleanup; also requires both cleanup gates. |
| `DELETE_CLOUDWATCH_LOGS` | `0` | Request Lambda log-group deletion; also requires the master gate. |
| `SKIP_PREFLIGHT_CLEANUP` | `1` | Keep prior `scrna-*` Lambda/IAM/ECR resources during development. |
| `TERMINATE_DRIVER_ON_EXIT` | `1` | Terminate EC2 after run. `0` to keep. |
| `DOWNLOAD_RESULTS` | `1` | Download results locally. `0` to skip. |
| `MATERIALIZER_THREADS` | `32` | Concurrent ranged-S3 workers used to build the final `map.rad`. |

---

## Output structure

Results appear in `serverless_runs/`:

```
serverless_runs/
  <RUN_ID>.log                          <-- Pipeline log
  <RUN_ID>/
  ├── run.env                           <-- Run metadata
  ├── timings.csv                       <-- End-to-end phase timings
  ├── rad_materializer_timings.csv      <-- Wait/manifest/materializer timings
  ├── split_timings/                    <-- Per-lane download/split/upload timings
  ├── combined/
  │   ├── map.rad                       <-- Merged mapping output
  │   └── unmapped_bc_count.bin
  ├── alevin_output/alevin/
  │   ├── quants_mat.mtx                <-- *** COUNT MATRIX ***
  │   ├── quants_mat_rows.txt           <-- Gene names
  │   └── quants_mat_cols.txt           <-- Cell barcodes
  └── analysis/out/                      <-- If RUN_QC=1
      ├── umap_leiden.png
      ├── qc_violin.png
      └── pbmc_adata.h5ad               <-- If WRITE_H5AD=1
```

The RAD handoff is synchronous, but Lambda launch overlaps split and upload.
As soon as both mates of one shard are in S3, the uploader publishes that
shard's `*_input.txt`; EventBridge may start its Lambda while later shards are
still being produced. The driver records the exact Lambda folder names, waits
until every folder contains both `map.rad` and the later `output.txt` completion
marker, and then runs `s3-rad-materialize`. It does not infer completion by
counting everything already present in the bucket, so retained objects from
another run are not accepted as new results.

The standalone handoff can also be run after publishing the input manifests:

```bash
bash scripts/synchronous_s3_rad_materialize.sh \
  --output-bucket "$OUTPUT_MAP_BUCKET" \
  --expected-folders expected_rad_folders.txt \
  --output /mnt/nvme/run/combined/map.rad \
  --not-before 2026-08-20T07:00:00Z \
  --threads 32
```

Use the timestamp captured immediately before publishing the manifests for
`--not-before` when a bucket can contain older output under the same keys.
Neither the handoff script nor the S3 materializer deletes S3 data.

---

## Auto-handled constraints

| Constraint | Behavior |
|---|---|
| Lambda memory quota too low | Falls back to 3,008 MB automatically |
| EC2 vCPU quota too low | Falls through instance chain automatically |
| No NVMe storage | Uses EBS root volume |
| Two or more NVMe disks | RAID 0 at `/mnt/nvme` |
| SSH blocked | Falls back to SSM automatically |
| Lambda shard dies mid-map | Stops polling after timeout + 3 min with no new `output.txt` |
| Lambda produces zero outputs | Fails after 2x the Lambda timeout |

For details on automatic fallbacks (instance types, memory, threads, splitting), see [Reproducibility Notes](REPRODUCIBILITY_NOTES.md).

---

## Manual overrides

Edit `scripts/e2e_serverless_pbmc.sh` to change defaults:

| Setting | Line | Default | Effect |
|---|---|---|---|
| `DEFAULT_SEED_AMI_ID` | 219 | `ami-079f71ff8e580ef1f` | Seed AMI |
| `DEFAULT_AWS_REGION` | 215 | `us-east-2` | Region |
| `INSTANCE_TYPE` | 241 | `m5dn.8xlarge` | EC2 type |
| `ROOT_VOL_GB` | 235 | `500` | EBS size (GB) |
| `LAMBDA_MEMORY_MB` | 248 | `10240` | Lambda RAM |
| `LAMBDA_TIMEOUT_SEC` | 250 | `900` | Lambda timeout |
| `RUN_QC` | 258 | `1` | QC on/off |
| `WRITE_H5AD` | 265 | `1` | h5ad on/off |
| `LOCAL_RESULTS_DIR` | 260 | `./serverless_runs` | Output dir |

---

## Cleanup

**Auto-cleanup is disabled during development.** Cleanup only runs when
`ALLOW_DESTRUCTIVE_CLEANUP=1` and `CLEANUP_AWS=1`. S3 object or bucket
deletion additionally requires `ALLOW_S3_DELETE=1`. With
`CLEANUP_RESULTS=0`, the results S3 bucket is preserved.

**On failure:** the same master gate applies. With its default value of `0`,
resources and CloudWatch logs are retained for diagnosis.

**Not cleaned up:** your IAM role (reuse it), the seed AMI (shared resource), and `serverless_runs/` (your results).

**Manual cleanup** (after a run with `CLEANUP_AWS=0` or `CLEANUP_RESULTS=0`):

```bash
# Leftover EC2 instances
aws ec2 describe-instances --filters "Name=tag:Name,Values=scrna-*" \
  "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key=='Name'].Value|[0]]" \
  --output table --region us-east-2
# Terminate: aws ec2 terminate-instances --instance-ids i-xxxxx --region us-east-2

# Leftover S3 buckets (results bucket from CLEANUP_RESULTS=0, or all buckets from CLEANUP_AWS=0)
aws s3 ls --region us-east-2 | grep scrna
# Remove: aws s3 rb s3://bucket-name --force --region us-east-2

# Leftover Lambda functions
aws lambda list-functions --query "Functions[?starts_with(FunctionName,'scrna-')].FunctionName" \
  --output text --region us-east-2
# Delete: aws lambda delete-function --function-name scrna-xxx --region us-east-2

# Leftover security groups
aws ec2 describe-security-groups \
  --query "SecurityGroups[?starts_with(GroupName,'scrna-driver-')].{Name:GroupName,Id:GroupId}" \
  --output table --region us-east-2
# Delete: aws ec2 delete-security-group --group-id sg-xxxxx --region us-east-2
```

---

## Cost estimate

| Resource | PBMC 1K | PBMC 10K |
|---|---|---|
| EC2 | ~$0.30 | ~$0.80 |
| Lambda | ~$0.05 | ~$0.20 |
| S3 + ECR | <$0.01 | <$0.01 |
| **Total** | **~$0.35** | **~$1.00** |

With `t3.xlarge`: EC2 drops to ~$0.01-$0.03 for PBMC 1K.

---

## Troubleshooting

| Error | Fix |
|---|---|
| `aws sts get-caller-identity` fails | Run `aws configure` with valid keys in the same terminal |
| `EC2_INSTANCE_PROFILE_NAME must be set` | `export EC2_INSTANCE_PROFILE_NAME=scrna-serverless-ec2-role` |
| `All instance types exhausted` | Request vCPU quota increase: **Service Quotas → EC2** |
| `Failed to create Lambda (memory=3008MB)` | Check **Service Quotas → Lambda** |
| Results not downloaded | Check `DOWNLOAD_RESULTS=1`. Results also on EC2 at `/mnt/nvme/runs/<RUN_ID>/` |
| `$'\r': command not found` | Fix line endings: `sed -i 's/\r$//' scripts/*.sh install_scripts/*.sh *.sh` |
| `icacls` fails in Git Bash | Run `icacls` in **PowerShell** only (Step D) |
| `uname -a` shows Linux/Microsoft | You're in WSL. Open **Git Bash** instead (this guide is for Windows). |
