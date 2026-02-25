# On-Server Pipeline Guide

Run the scRNA-seq pipeline on a dedicated Linux server at UW Tacoma. Trigger it by clicking a button on GitHub. No local setup required.

> **No AWS account needed.** No S3, no Lambda, no EC2.

## What you need

- A web browser
- A GitHub account ([sign up free](https://github.com/signup))

## Steps

### 1. Go to the repository

Open **https://github.com/BioDepot/scRNA-serverless** in your browser.

### 2. Open the Actions tab

Click **Actions** in the top navigation bar.

### 3. Select the workflow

Click **On-Server scRNA Pipeline** in the left sidebar.

### 4. Configure and run

Click **Run workflow**. A dropdown appears with these options:

- **Branch:** select the branch containing the pipeline code (e.g. `pr/repro-ami-e2e`)
- **Dataset:** `pbmc1k` (~2 min pipeline, ~5 GB data) or `pbmc10k` (~10 min pipeline, ~44 GB data)
- **Run QC:** `1` (recommended — generates UMAP + violin plots) or `0` (skip)
- **Save h5ad:** `1` (save AnnData file for downstream analysis) or `0` (default, skip)
- **Execution mode:** `full-run` or `dry-run` (checks tools/refs/disk without running)

Click the green **Run workflow** button.

### 5. Wait for completion

Click the running workflow to watch live logs. A green checkmark means it finished successfully.

- **PBMC 1K** typically takes 3–5 minutes total
- **PBMC 10K** typically takes 15–25 minutes total (longer if FASTQs need downloading)

### 6. Download results

Scroll to **Artifacts** at the bottom of the completed run. Click the artifact (e.g. `onserver-pbmc1k-results`) to download a ZIP file.

### 7. Open results

Unzip the file. Full contents:

```
onserver_runs/<run-id>/
├── timing_summary.txt              <-- Step-by-step timings
├── run.env                         <-- Server info, tool versions, settings
├── logs/
│   ├── piscem_map.log              <-- Piscem mapping log
│   ├── alevin_gpl.log              <-- generate-permit-list log
│   ├── alevin_collate.log          <-- Collate log
│   └── alevin_quant.log            <-- Quant log
├── alevin_output/
│   ├── alevin/
│   │   ├── quants_mat.mtx          <-- *** COUNT MATRIX ***
│   │   ├── quants_mat_rows.txt     <-- Gene names
│   │   └── quants_mat_cols.txt     <-- Cell barcodes
│   ├── map.collated.rad            <-- Collated RAD file
│   ├── permit_freq.bin             <-- Permit frequencies
│   ├── permit_map.bin              <-- Permit map
│   ├── all_freq.bin                <-- All barcode frequencies
│   ├── unmapped_bc_count_collated.bin
│   ├── generate_permit_list.json
│   ├── collate.json
│   ├── quant.json
│   └── featureDump.txt
├── combined/
│   ├── map.rad                     <-- Raw piscem mapping output
│   └── unmapped_bc_count.bin       <-- Unmapped barcode counts
└── analysis/out/                   (only if Run QC = 1)
    ├── umap_leiden.png             <-- UMAP clustering plot
    ├── qc_violin.png               <-- QC violin plot
    └── pbmc_adata.h5ad             (only if Save h5ad = 1)
```

---

## Pipeline steps

The pipeline executes the same steps described in Table 2 of the paper:

| Step | Tool | Output |
|---|---|---|
| 1. FASTQ locate/download | curl / cached | FASTQs in `datasets/10x/` |
| 2. Piscem mapping | piscem 0.10.3 | `map.rad`, `unmapped_bc_count.bin` |
| 3. Generate permit list | alevin-fry 0.9.0 | `permit_freq.bin`, `all_freq.bin` |
| 4. Collate | alevin-fry 0.9.0 | `map.collated.rad` |
| 5. Quant | alevin-fry 0.9.0 | `quants_mat.mtx`, rows, cols |
| 6. QC analysis (optional) | scanpy | UMAP + violin plots |

FASTQ download time is **not included** in the pipeline total — the paper assumes pre-staged FASTQs. If FASTQs need downloading, the time is reported separately.

---

## FASTQ caching

FASTQs are cached on the server after the first download. On subsequent runs:

- If FASTQs are present and valid (gzip integrity check), they are reused — no download
- If FASTQs are corrupt or incomplete, they are deleted and re-downloaded automatically
- Cached FASTQs are **never deleted** by the cleanup process

---

## Automatic cleanup

Each run automatically cleans up after itself:

- **Before a run:** removes any leftover run directories, repo copies, and stale tarballs from interrupted previous runs
- **After a run:** removes the current run directory and repo copy from the server once results are downloaded

What is **never** deleted:
- Cached FASTQs (`datasets/10x/`)
- Reference index (`reference/index_output_transcriptome/`)
- `t2g.tsv` transcript-to-gene map

---

## Server details

- **CPU:** Intel i9-13900KF (32 cores) | **RAM:** 125 GB | **OS:** Ubuntu 22.04
- **Tools:** piscem 0.10.3, alevin-fry 0.9.0, radtk 0.1.0
- **Disk:** ~1.6 TB total on `/home`

---

## Credentials

Server credentials are stored as **GitHub Secrets** — encrypted, injected at runtime, never visible in logs or code. Three secrets are configured:

- `SSH_USER` — server username
- `SSH_PASSWORD` — server password
- `SERVER_HOST` — server IP address

These are set once by the repository owner and never need to be touched by reviewers.

---

## Using your own server (advanced)

If you want to run the pipeline on your own server instead of the UW Tacoma server:

1. Clone the repo and create a `.env` file:

```bash
git clone https://github.com/BioDepot/scRNA-serverless.git
cd scRNA-serverless
cp .env.example .env
```

2. Edit `.env` with your server details:

```
SSH_USER=your_username
SSH_PASSWORD=your_password
SERVER_HOST=your.server.ip.address
```

3. Run:

```bash
bash scripts/e2e_onserver_pbmc.sh pbmc1k
```

**Server requirements:**
- Linux (Ubuntu 22.04 recommended)
- 10 GB+ free disk (20 GB+ for 10K with cached FASTQs, 60 GB+ without)
- `sudo` access (for installing tools if not present)
- Git Bash (Windows) or terminal (Mac/Linux) on your local machine

**Optional settings:**

```bash
RUN_QC=0 bash scripts/e2e_onserver_pbmc.sh pbmc1k          # skip QC
WRITE_H5AD=1 bash scripts/e2e_onserver_pbmc.sh pbmc1k       # save h5ad
bash scripts/e2e_onserver_pbmc.sh pbmc1k --dry-run           # check tools/refs/disk only
bash scripts/e2e_onserver_pbmc.sh pbmc10k                    # run 10K dataset
```

---

## Troubleshooting

| Error | Fix |
|---|---|
| "SERVER_HOST and SSH_USER are not set" | GitHub Secrets not configured. Contact the repository owner. |
| "Insufficient disk space" | Previous run may not have cleaned up. The pre-run cleanup should handle this automatically. If it persists, contact authors. |
| "No such file or directory: e2e_onserver_pbmc.sh" | Wrong branch selected. Make sure you pick the branch with the pipeline code (e.g. `pr/repro-ami-e2e`), not `master`. |
| Stuck on "Downloading FASTQ files" | PBMC 1K is ~5 GB, 10K is ~44 GB. First download takes time. Subsequent runs use cache. |
| No artifacts after run | Make sure you selected `full-run`, not `dry-run`. |
| Where are old runs? | **Actions** tab → click any previous run → download artifact (kept 30 days). |
| Run cancelled / interrupted | No cleanup needed. The next run auto-cleans leftover files before starting. |
