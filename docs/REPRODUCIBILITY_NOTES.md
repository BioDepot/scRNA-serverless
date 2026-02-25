# Reproducibility Notes

The script reproduces the paper's pipeline exactly when run on a fully provisioned AWS account. For accounts with lower quotas or limits, the script automatically falls back to compatible settings. No manual configuration is needed. The output count matrices are identical regardless of which settings are used.

---

## Automatic fallbacks for AWS account limits

### Lambda memory fallback

The paper uses **10,240 MB** Lambda functions (~6 vCPUs, piscem `-t 6`). This repo tries 10,240 MB first, and falls back to **3,008 MB** (~2 vCPUs, `-t 2`) if the account quota is exceeded.

### PBMC 1K automatic splitting

The paper processes PBMC 1K (~5 GB) in a single Lambda. At 3,008 MB, splitting is forced to avoid OOM — PBMC 1K becomes **17 chunks** (4M reads each), processed by 17 parallel Lambdas. For PBMC 10K, splitting occurs at both memory tiers.

### Piscem thread auto-configuration

`scrna-pipeline/map.py` reads `LAMBDA_MEMORY_MB` at runtime and sets threads accordingly. No configuration needed.

### EC2 instance type fallback

The paper uses a fixed **m6id.16xlarge** (64 vCPUs, 256 GB RAM). This repo tries m6id.16xlarge first, then falls back through smaller instances if the account's vCPU quota is too low:

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

This repo defaults to **500 GB**, matching the paper. On m6id instances, most data goes on the NVMe instance-store SSD, so the EBS root is lightly used. Override with `export ROOT_VOL_GB=50` for PBMC 1K to save costs.

### NVMe storage fallback

The paper assumes NVMe instance storage (m6id family). This repo falls back to the EBS root volume if no NVMe device is found (m6i, t3 families).

### Configuration summary

| Setting | Paper | Script default (auto-adjusted if needed) |
|---|---|---|
| Lambda memory | 10,240 MB | 10,240 MB (falls back to 3,008 MB) |
| Lambda ephemeral storage | 10,240 MB | 10,240 MB (unchanged) |
| Piscem threads | 6 | 6 or 2 (auto) |
| PBMC 1K splitting | Not split (1 Lambda) | 17 parts at 3,008 MB |
| Split threshold | 7 GB | 7 GB or 0 (auto) |
| Split chunk size | 16M lines / 4M reads | 16M lines / 4M reads (unchanged) |
| EC2 driver instance | m6id.16xlarge | m6id.16xlarge (fallback chain) |
| EBS root volume | 500 GB | 500 GB (unchanged) |
| NVMe storage | Required | Optional (EBS fallback) |
| Lambda timeout | 900 s | 900 s (unchanged) |

### Local disk space requirements

The script creates a temporary tarball (~200 MB) in the repo directory during setup, uploads it to EC2, then deletes it. Results are also downloaded to the repo directory under `serverless_runs/`. Keep this much free space on the drive where you cloned the repository:

| Dataset | Temp space (deleted after upload) | Results download | Total recommended free |
|---|---|---|---|
| PBMC 1K | ~200 MB | ~200 MB | ~1 GB |
| PBMC 10K | ~200 MB | ~10-15 GB | ~20 GB |

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

> **Tip for PBMC 10K:** Results are ~15 GB. On slow wifi this download can take hours.
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

### `scripts/compare_results.sh` — Results comparison

Compares outputs from two pipeline runs (typically serverless vs. on-server) to verify they produce identical results.

**Usage:**

```bash
bash scripts/compare_results.sh <dataset> <reference_zip_or_dir> [local_results_dir]
```

- `<dataset>`: `1k` or `10k` — controls which local serverless run to auto-detect
- `<reference_zip_or_dir>`: path to the on-server results zip (downloaded from GitHub Actions Artifacts) or an already-extracted directory
- `[local_results_dir]`: *(optional)* explicit path to a serverless results directory. If omitted, the script finds the **latest** matching run (1k or 10k) under `serverless_runs/`.

**Auto-detection behavior:**

- If you pass `1k`, the script scans `serverless_runs/` and picks the most recent run whose `run.env` contains `DATASET=pbmc1k`
- If you pass `10k`, it picks the most recent `DATASET=pbmc10k` run
- If no matching run exists, the script lists what runs are available and exits
- Cross-comparisons work: you can compare a 1k zip against a 10k local run and vice versa — the dataset argument only controls which local run to auto-detect

**What it compares:**

| Check | Method |
|---|---|
| Count matrix (`quants_mat.mtx`) | Exact value match (barcode-normalised to handle row ordering) |
| Cell barcodes (`quants_mat_rows.txt`) | Set equality (order-independent) |
| Gene list (`quants_mat_cols.txt`) | Exact line-by-line match |
| Quantification metrics (`quant.json`) | Key-by-key numeric comparison |
| Permit-list metrics (`generate_permit_list.json`) | Key-by-key comparison |
| Per-barcode QC (`featureDump.txt`) | Row-by-row comparison |
| Timing (`timing_summary.txt`) | Side-by-side display, excluding infrastructure steps (FASTQ download, Docker build, S3 uploads) |
| File presence and sizes | Lists all output files in both directories |

**Log output:**

The script automatically saves a log to `serverless_runs/compare_<dataset>_<timestamp>.log` (e.g. `serverless_runs/compare_pbmc1k_20260226_143022.log`). The full output is still printed to the terminal — the log is an additional copy for later reference.

**Examples:**

```bash
# Compare latest local 1k serverless run against the on-server 1k zip
bash scripts/compare_results.sh 1k "C:/Users/me/Downloads/onserver-pbmc1k-results.zip"

# Compare latest local 10k serverless run against the on-server 10k zip
bash scripts/compare_results.sh 10k "C:/Users/me/Downloads/onserver-pbmc10k-results.zip"

# Explicit local results directory
bash scripts/compare_results.sh 1k "/path/to/ref.zip" "/path/to/local/results"

# Compare cross-dataset (1k zip against 10k local run)
bash scripts/compare_results.sh 10k "C:/Users/me/Downloads/onserver-pbmc1k-results.zip"
```
