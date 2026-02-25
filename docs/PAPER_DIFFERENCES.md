# Differences From the Paper

All differences are handled automatically by the script. No manual configuration is needed. The output count matrices are identical regardless of which settings are used.

---

## Serverless pipeline differences

### Lambda memory: 10,240 MB → 3,008 MB fallback

The paper uses **10,240 MB** Lambda functions (~6 vCPUs, piscem `-t 6`). This repo tries 10,240 MB first, and falls back to **3,008 MB** (~2 vCPUs, `-t 2`) if the account quota is exceeded.

### PBMC 1K splitting: 1 Lambda → 17 Lambdas

The paper processes PBMC 1K (~5 GB) in a single Lambda. At 3,008 MB, splitting is forced to avoid OOM — PBMC 1K becomes **17 chunks** (4M reads each), processed by 17 parallel Lambdas. For PBMC 10K, splitting occurs at both memory tiers.

### Piscem threads: `-t 6` → `-t 2`

`scrna-pipeline/map.py` reads `LAMBDA_MEMORY_MB` at runtime and sets threads accordingly. No configuration needed.

### EC2 driver instance: m6id.16xlarge → automatic fallback

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

### EBS root volume: 500 GB → 200 GB

The paper uses a 500 GB root volume. This repo defaults to **200 GB**, which is sufficient for both datasets. On m6id instances, most data goes on the NVMe instance-store SSD, so the EBS root is lightly used.

### NVMe storage: required → optional

The paper assumes NVMe instance storage (m6id family). This repo falls back to the EBS root volume if no NVMe device is found (m6i, t3 families).

### Summary table

| Setting | Paper | This repo |
|---|---|---|
| Lambda memory | 10,240 MB | 10,240 MB (falls back to 3,008 MB) |
| Lambda ephemeral storage | 10,240 MB | 10,240 MB (unchanged) |
| Piscem threads | 6 | 6 or 2 (auto) |
| PBMC 1K splitting | Not split (1 Lambda) | 17 parts at 3,008 MB |
| Split threshold | 7 GB | 7 GB or 0 (auto) |
| Split chunk size | 16M lines / 4M reads | 16M lines / 4M reads (unchanged) |
| EC2 driver instance | m6id.16xlarge | m6id.16xlarge (fallback chain) |
| EBS root volume | 500 GB | 200 GB |
| NVMe storage | Required | Optional (EBS fallback) |
| Lambda timeout | 900 s | 900 s (unchanged) |

All other steps (alevin-fry generate-permit-list, collate, quant, resource creation, cleanup) are identical.
