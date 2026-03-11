# On-Server Pipeline Guide

Run the scRNA-seq pipeline on a dedicated Linux server at UW Tacoma. Three ways to trigger it — all produce identical results:

| Method | What you need | Best for |
|---|---|---|
| **GitHub Actions** | Web browser + GitHub account | One-click runs, artifact download |
| **GitHub Codespaces** | Web browser + GitHub account | Interactive terminal, live output |
| **Local terminal** | Git Bash / terminal + `.env` file | Running against your own server |

> **No AWS account needed.** No S3, no Lambda, no EC2.

---

## Option A: GitHub Actions (recommended)

### What you need

- A web browser
- A GitHub account ([sign up free](https://github.com/signup))

### Steps

#### 1. Go to the repository

Open **https://github.com/BioDepot/scRNA-serverless** in your browser.

#### 2. Open the Actions tab

Click **Actions** in the top navigation bar.

#### 3. Select the workflow

Click **On-Server scRNA Pipeline** in the left sidebar.

#### 4. Configure and run

Click **Run workflow**. A dropdown appears with these options:

- **Branch:** select the branch containing the pipeline code (e.g. `pr/repro-ami-e2e`)
- **Dataset:** `pbmc1k` (~2 min pipeline, ~5 GB data) or `pbmc10k` (~10 min pipeline, ~44 GB data)
- **Run QC:** `1` (recommended — generates UMAP + violin plots) or `0` (skip)
- **Save h5ad:** `1` (save AnnData file for downstream analysis) or `0` (default, skip)
- **Execution mode:** `full-run` or `dry-run` (checks tools/refs/disk without running)

Click the green **Run workflow** button.

#### 5. Wait for completion

Click the running workflow to watch live logs. A green checkmark means it finished successfully.

- **PBMC 1K** typically takes 3–5 minutes total
- **PBMC 10K** typically takes 15–25 minutes total (longer if FASTQs need downloading)

#### 6. Download results

Scroll to **Artifacts** at the bottom of the completed run. Click the artifact (e.g. `onserver-pbmc1k-results`) to download a ZIP file.

---

## Option B: GitHub Codespaces

Run the pipeline from an interactive cloud terminal — no local software needed.

### What you need

- A web browser
- A GitHub account ([sign up free](https://github.com/signup))

### One-time setup

#### 1. Add Codespaces secrets

Go to **https://github.com/settings/codespaces** and add three secrets:

| Secret name | Value | Repository access |
|---|---|---|
| `SSH_USER` | Server username | `BioDepot/scRNA-serverless` |
| `SSH_PASSWORD` | Server password | `BioDepot/scRNA-serverless` |
| `SERVER_HOST` | Server IP address | `BioDepot/scRNA-serverless` |

These are the same credentials used by GitHub Actions. Set each secret's repository access to **BioDepot/scRNA-serverless** (or "All repositories").

#### 2. Create a Codespace

Go to the repository on GitHub. Click **Code** → **Codespaces** → **Create codespace on pr/repro-ami-e2e** (or the branch with the pipeline code).

The Codespace will build automatically using the included `.devcontainer/devcontainer.json` configuration, which installs `sshpass` and Python.

### Running the pipeline

Once the Codespace terminal is ready:

```bash
# Dry-run (verify connectivity, tools, references, disk — takes < 1 min)
bash scripts/e2e_onserver_pbmc.sh pbmc1k --dry-run

# Full run — PBMC 1K (~3–5 min)
bash scripts/e2e_onserver_pbmc.sh pbmc1k

# Full run — PBMC 10K (~15–25 min)
bash scripts/e2e_onserver_pbmc.sh pbmc10k
```

Optional flags:

```bash
RUN_QC=0 bash scripts/e2e_onserver_pbmc.sh pbmc1k          # skip QC
WRITE_H5AD=1 bash scripts/e2e_onserver_pbmc.sh pbmc1k       # save h5ad
```

### Where are results?

Results are downloaded to the `onserver_runs/` directory inside the Codespace. You can browse them in the Codespace file explorer (left sidebar) or download them from the terminal:

1. Right-click any file in the file explorer → **Download**
2. Or use the terminal: the files are at `onserver_runs/<run-id>/`

### Credential safety

Codespaces secrets are injected as environment variables at startup. They are **never** visible in code, terminal history, or logs — the pipeline automatically masks the username and IP in all output (including third-party tool logs), replacing them with `***`.

---

## Output structure

Whether you use Actions, Codespaces, or a local terminal, the output directory looks the same:

```
onserver_runs/<run-id>/
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

The pipeline executes the Piscem-Alevin Fry steps described in the Methods section of the paper:

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

Server credentials are stored as **GitHub Secrets** — encrypted, injected at runtime, never visible in logs or code. Three secrets are required: `SSH_USER`, `SSH_PASSWORD`, and `SERVER_HOST`. All three must be configured for whichever method you use:

| Method | Where to set all 3 secrets |
|---|---|
| GitHub Actions | Repo **Settings → Secrets and variables → Actions** (set by repo owner) |
| Codespaces | **github.com/settings/codespaces** (set by each user) |
| Local terminal | `.env` file in the repo root (see Option C) |

All output — including third-party tool logs from piscem, alevin-fry, and Python — is automatically masked. The username and IP are replaced with `***` in every log line.

---

## Option C: Local terminal / your own server (advanced)

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
| "SERVER_HOST and SSH_USER are not set" | **Actions:** GitHub Secrets not configured — contact the repo owner. **Codespaces:** add secrets at github.com/settings/codespaces with access to this repo. **Local:** create a `.env` file from `.env.example`. |
| "Insufficient disk space" | Previous run may not have cleaned up. The pre-run cleanup should handle this automatically. If it persists, contact authors. |
| "No such file or directory: e2e_onserver_pbmc.sh" | Wrong branch selected. Make sure you pick the branch with the pipeline code (e.g. `pr/repro-ami-e2e`), not `master`. |
| Stuck on "Downloading FASTQ files" | PBMC 1K is ~5 GB, 10K is ~44 GB. First download takes time. Subsequent runs use cache. |
| No artifacts after Actions run | Make sure you selected `full-run`, not `dry-run`. |
| Where are old runs? | **Actions:** click any previous run → download artifact (kept 30 days). **Codespaces:** check `onserver_runs/` in the file explorer. |
| Run cancelled / interrupted | No cleanup needed. The next run auto-cleans leftover files before starting. |
| Codespace can't connect to server | Run `echo $SSH_USER` in the terminal — if blank, your Codespaces secrets aren't set or don't have access to this repo. |
| Codespace shows raw IP/username | Pull the latest code: `git pull origin pr/repro-ami-e2e`. The masking fix requires the latest version. |
