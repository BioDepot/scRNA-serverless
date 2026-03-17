# Reproducibility Notes

The script reproduces the paper's pipeline exactly when run on a fully provisioned AWS account. For accounts with lower quotas or limits, the script automatically falls back to compatible settings. No manual configuration is needed. The output count matrices are identical regardless of which settings are used.

> **Important:** Do not run PBMC 1K and PBMC 10K at the same time. Each run shares resources (S3 buckets, security groups, working directories) that are cleaned up when the run finishes. Running two datasets in parallel will cause the first to finish to destroy resources the other is still using. Always run one dataset at a time.

---

## Automatic fallbacks for AWS account limits

### Lambda memory fallback

The script uses **10,240 MB** Lambda functions (~6 vCPUs, piscem `-t 6`), matching the paper. If the account's Lambda memory quota is lower, it automatically falls back to **3,008 MB** (~2 vCPUs, `-t 2`).

### PBMC 1K automatic splitting

The script processes PBMC 1K (~5 GB) in a single Lambda, matching the paper. If the account falls back to 3,008 MB memory, splitting is forced to avoid OOM — PBMC 1K becomes **17 chunks** (4M reads each), processed by 17 parallel Lambdas. For PBMC 10K, splitting occurs at both memory tiers.

### Piscem thread auto-configuration

`scrna-pipeline/map.py` reads `LAMBDA_MEMORY_MB` at runtime and sets threads accordingly. No configuration needed.

### EC2 instance type fallback

The script uses **m6id.16xlarge** (64 vCPUs, 256 GB RAM), matching the paper. If the account's vCPU quota is too low, it automatically falls back through smaller instances:

| Instance | vCPUs | RAM | Notes |
|---|---|---|---|
| m6id.16xlarge | 64 | 256 GB | Paper configuration |
| m6id.8xlarge | 32 | 128 GB | Fits default 32 vCPU quota |
| m6id.4xlarge | 16 | 64 GB | |
| m6id.xlarge | 4 | 16 GB | |
| m6i.xlarge | 4 | 16 GB | EBS only, no NVMe |
| t3.2xlarge | 8 | 32 GB | |
| t3.xlarge | 4 | 16 GB | Min for PBMC 10K |
| t3.large | 2 | 8 GB | Min for PBMC 1K |

### EBS root volume: 500 GB (unchanged)

The script defaults to **500 GB**, matching the paper. On m6id instances, most data goes on the NVMe instance-store SSD, so the EBS root is lightly used. Override with `export ROOT_VOL_GB=50` for PBMC 1K to save costs.

### NVMe storage fallback

The script uses NVMe instance storage (m6id family), matching the paper. If the EC2 instance has no NVMe device (m6i, t3 families), it automatically falls back to the EBS root volume.

### Configuration summary

| Setting | Paper | Script default | If account quota is too low |
|---|---|---|---|
| Lambda memory | 10,240 MB | 10,240 MB | Falls back to 3,008 MB |
| Lambda ephemeral storage | 10,240 MB | 10,240 MB | *(unchanged)* |
| Piscem threads | 6 | 6 | 2 (at 3,008 MB) |
| PBMC 1K splitting | Not split (1 Lambda) | Not split (1 Lambda) | 17 parts (at 3,008 MB) |
| Split threshold | 7 GB | 7 GB | 0 GB (at 3,008 MB — forces splitting) |
| Split chunk size | 16M lines / 4M reads | 16M lines / 4M reads | *(unchanged)* |
| EC2 driver instance | m6id.16xlarge | m6id.16xlarge | Falls through smaller instances |
| EBS root volume | 500 GB | 500 GB | *(unchanged)* |
| NVMe storage | Available (m6id) | Used if available | EBS root volume (m6i/t3 families) |
| Lambda timeout | 900 s | 900 s | *(unchanged)* |

### Local disk space requirements

The script creates a temporary tarball (~200 MB) in the repo directory during setup, uploads it to EC2, then deletes it. Results are also downloaded to the repo directory under `serverless_runs/`. Keep this much free space on the drive where you cloned the repository:

| Dataset | Temp space (deleted after upload) | Results download | Total recommended free |
|---|---|---|---|
| PBMC 1K | ~200 MB | ~1 GB | ~5 GB |
| PBMC 10K | ~200 MB | ~9 GB | ~30 GB |

The FASTQs and intermediate files stay on the EC2 instance (500 GB EBS). Only the final count matrix, QC plots, and merged .rad file are downloaded locally.

All other steps (alevin-fry generate-permit-list, collate, quant, resource creation, cleanup) are identical.

---

## Script reference

This repository includes three scripts. Each can run PBMC 1K or PBMC 10K.

---

### `scripts/e2e_serverless_pbmc.sh` — Serverless pipeline

Provisions AWS resources (EC2, Lambda, S3, ECR, EventBridge), runs the mapping/quantification pipeline, and optionally cleans everything up.

**Usage:**

```bash
bash scripts/e2e_serverless_pbmc.sh <dataset> [--dry-run]
```

- `<dataset>`: `pbmc1k` or `pbmc10k`
- `--dry-run`: validate credentials, AMI, network, keypair — creates nothing

**Required environment variables** (set before every run):

| Variable | Example | Purpose |
|---|---|---|
| `AWS_REGION` | `us-east-2` | AWS region (must match AMI) |
| `SEED_AMI_ID` | `ami-079f71ff8e580ef1f` | Pre-built seed AMI |
| `EC2_INSTANCE_PROFILE_NAME` | `scrna-serverless-ec2-role` | IAM role for EC2 |
| `KEY_NAME` | `scrna-reviewer-key` | EC2 keypair name |
| `KEY_PEM_PATH` | `/d/Keys/scrna-reviewer-key.pem` | Path to PEM file |

**Optional environment variables:**

| Variable | Default | Purpose |
|---|---|---|
| `CLEANUP_AWS` | `1` | `1` = delete AWS infrastructure after run. `0` = keep everything. On failure, always cleans up. |
| `CLEANUP_RESULTS` | `1` | `1` = delete results S3 bucket after run. `0` = keep for manual download. On failure, always cleans up. |
| `TERMINATE_DRIVER_ON_EXIT` | `1` | `1` = terminate EC2 when done. `0` = leave it running. |
| `RUN_QC` | `1` | `1` = generate UMAP + violin plots. `0` = skip QC. |
| `WRITE_H5AD` | `1` | `1` = save `.h5ad` AnnData file (requires `RUN_QC=1`). `0` = skip. |
| `DOWNLOAD_RESULTS` | `1` | `1` = download results to local machine. `0` = leave on S3. |
| `LOCAL_RESULTS_DIR` | `./serverless_runs` | Where downloaded results are saved. |

> **Tip for PBMC 10K:** The results tarball is ~9 GB. On slow wifi this download can take a while.
> Set `DOWNLOAD_RESULTS=0 CLEANUP_RESULTS=0` to skip the download and keep the results bucket.
> The pipeline prints the bucket name and download commands at the end. To download later:
>
> ```bash
> # Find your results bucket
> aws s3 ls --region us-east-2 | grep scrna-quant
>
> # Download everything
> aws s3 sync s3://scrna-quant-<ACCOUNT_ID>-us-east-2-<RUN_ID>/ ./results/ --region us-east-2
>
> # Clean up when done
> aws s3 rb s3://scrna-quant-<ACCOUNT_ID>-us-east-2-<RUN_ID> --force --region us-east-2
> ```
| `INSTANCE_TYPE` | `m6id.16xlarge` | Preferred EC2 type (auto-fallback if quota is too low). |
| `ROOT_VOL_GB` | `500` | EBS root volume size in GB. |
| `LAMBDA_MEMORY_MB` | `10240` | Lambda memory in MB (falls back to 3008 if quota exceeded). |
| `LAMBDA_EPHEMERAL_MB` | `10240` | Lambda ephemeral storage in MB. |
| `LAMBDA_TIMEOUT_SEC` | `900` | Lambda function timeout in seconds. |
| `LAMBDA_CONCURRENCY` | `1000` | Max parallel Lambda invocations (fallback: 1000→500→100→10). Set `0` for unrestricted. |
| `THREADS` | auto (`nproc`) | CPU threads for on-instance processing. |
| `USE_SSM` | `auto` | `auto` = try SSH, fall back to SSM. `1` = force SSM. `0` = force SSH. |
| `SSH_USER` | `ubuntu` | SSH username on the EC2 instance. |
| `FASTQ_TAR_PATH` | *(empty)* | Path to a local FASTQ tarball (skip download). |
| `FASTQ_TAR_URL` | *(empty)* | URL to download FASTQs from (overrides default). |
| `RUN_ID` | auto-generated | Custom run identifier. |

**Examples:**

```bash
# Minimal first run — keep resources, no QC
export CLEANUP_AWS=0 TERMINATE_DRIVER_ON_EXIT=0 RUN_QC=0 WRITE_H5AD=0
bash scripts/e2e_serverless_pbmc.sh pbmc1k

# Full run with QC + cleanup
export CLEANUP_AWS=1 TERMINATE_DRIVER_ON_EXIT=1 RUN_QC=1 WRITE_H5AD=1
bash scripts/e2e_serverless_pbmc.sh pbmc1k

# PBMC 10K
bash scripts/e2e_serverless_pbmc.sh pbmc10k

# Dry run only
bash scripts/e2e_serverless_pbmc.sh pbmc1k --dry-run
```

---

### `scripts/e2e_onserver_pbmc.sh` — On-server pipeline

Runs the pipeline on a dedicated Linux server (UW Tacoma) over SSH. Normally triggered by GitHub Actions, but can also be run locally.

**Usage:**

```bash
bash scripts/e2e_onserver_pbmc.sh <dataset> [--dry-run]
```

- `<dataset>`: `pbmc1k` or `pbmc10k`
- `--dry-run`: check tools, references, and disk on the server without running

**Via GitHub Actions** (recommended):

1. Go to the repository **Actions** tab
2. Select **On-Server scRNA Pipeline**
3. Click **Run workflow**, choose branch, dataset, QC, h5ad, and mode
4. Download results from **Artifacts** when finished

**Required environment variables** (for local use — GitHub Actions sets these automatically):

| Variable | Purpose |
|---|---|
| `SERVER_HOST` | Server IP or hostname |
| `SSH_USER` | SSH username |
| `SSH_PASSWORD` | SSH password |

**Optional environment variables:**

| Variable | Default | Purpose |
|---|---|---|
| `RUN_QC` | `1` | `1` = generate UMAP + violin plots. `0` = skip. |
| `WRITE_H5AD` | `0` | `1` = save `.h5ad` file. `0` = skip. |
| `DOWNLOAD_RESULTS` | `1` | `1` = download results locally. `0` = leave on server. |
| `LOCAL_RESULTS_DIR` | `./onserver_runs` | Where downloaded results are saved. |
| `THREADS` | auto (server cores) | CPU threads on the server. |
| `RUN_ID` | auto-generated | Custom run identifier. |

**Examples:**

```bash
# Local run (needs .env or exported vars)
bash scripts/e2e_onserver_pbmc.sh pbmc1k

# Skip QC
RUN_QC=0 bash scripts/e2e_onserver_pbmc.sh pbmc1k

# 10K with h5ad
WRITE_H5AD=1 bash scripts/e2e_onserver_pbmc.sh pbmc10k

# Dry run
bash scripts/e2e_onserver_pbmc.sh pbmc1k --dry-run
```

---

### `scripts/compare_results.sh` — Comparing Results

This script verifies that two pipeline runs produced identical count matrices. Use it to compare your serverless results against on-server results (or any two runs against each other).

**What you need:**

1. **Run A (reference)** — a zip file or folder containing results from one pipeline run (e.g. the on-server results zip from GitHub Actions).
2. **Run B (local)** — a folder containing results from another pipeline run (e.g. your serverless results in `serverless_runs/`).

**Quick start:**

```bash
bash scripts/compare_results.sh <1k|10k> <path-to-run-A> [path-to-run-B]
```

- First argument: `1k` or `10k` (which dataset you ran).
- Second argument: path to Run A — can be a `.zip` file or a folder.
- Third argument *(optional)*: path to Run B. If you skip this, the script automatically finds your **most recent** matching run inside `serverless_runs/`.

**Example 1 — Zip against a specific serverless run folder**

After downloading the on-server results zip from GitHub Actions Artifacts:

```bash
bash scripts/compare_results.sh 1k "D:/Users/me/Downloads/onserver-pbmc1k-results.zip" serverless_runs/pbmc-1773250297-b2057eb4
```

**Example 2 — Zip only (auto-detect local run)**

If you skip the third argument, the script finds your latest matching run in `serverless_runs/` automatically:

```bash
# PBMC 1K
bash scripts/compare_results.sh 1k "D:/Users/me/Downloads/onserver-pbmc1k-results.zip"

# PBMC 10K
bash scripts/compare_results.sh 10k "D:/Users/me/Downloads/onserver-pbmc10k-results.zip"
```

**Example 3 — Two serverless runs against each other**

```bash
bash scripts/compare_results.sh 1k serverless_runs/pbmc-1773250297-b2057eb4 serverless_runs/pbmc-1773260412-a1c3f9d0
```

Each path can be a `.zip` file or a folder. The folder must contain `alevin_output/` somewhere inside it (the script searches up to 4 levels deep).

**What it checks:**

| Check | What it does |
|---|---|
| Count matrix (`quants_mat.mtx`) | Exact value match (handles different barcode ordering) |
| Cell barcodes (`quants_mat_rows.txt`) | Same barcodes in both |
| Gene list (`quants_mat_cols.txt`) | Exact line-by-line match |
| Quantification metrics (`quant.json`) | Compares cell count, gene count, versions |
| Permit-list metrics (`generate_permit_list.json`) | Key-by-key match |
| Per-barcode QC (`featureDump.txt`) | Row-by-row match |
| File inventory | Lists all output files with sizes |

**Output:**

- Results print to the terminal with color-coded PASS/FAIL/WARN.
- A log copy is saved to `serverless_runs/compare_<dataset>_<timestamp>.log`.
