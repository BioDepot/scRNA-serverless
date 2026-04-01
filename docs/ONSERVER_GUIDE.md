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
- Server credentials provided by the authors

### Steps

#### 1. Fork the repository

Open **https://github.com/BioDepot/scRNA-serverless** and click **Fork** (top right). This creates a copy under your own GitHub account.

#### 2. Add server credentials

In your fork, go to **Settings → Secrets and variables → Actions** and add three secrets using the values provided by the authors:

| Secret name | Value |
|---|---|
| `SSH_USER` | *(provided by authors)* |
| `SSH_PASSWORD` | *(provided by authors)* |
| `SERVER_HOST` | *(provided by authors)* |

#### 3. Run the workflow

Go to the **Actions** tab in your fork. Click **On-Server scRNA Pipeline** in the left sidebar, then click **Run workflow**.

- **Branch:** `master`
- **Dataset:** `pbmc1k`
- **Run QC:** `1` (recommended)
- **Save h5ad:** `0` (default)
- **Execution mode:** `full-run`

Click the green **Run workflow** button.

#### 4. Wait for completion

Click the running workflow to watch live logs. A green checkmark means it finished successfully.

- **PBMC 1K** typically takes 3–5 minutes total

#### 5. Download results

Scroll to **Artifacts** at the bottom of the completed run. Click the artifact (e.g. `onserver-pbmc1k-results`) to download a ZIP file.

---

## Option B: GitHub Codespaces

Run the pipeline from an interactive cloud terminal — no local software needed.

### What you need

- A web browser
- A GitHub account ([sign up free](https://github.com/signup))
- Server credentials provided by the authors

### One-time setup

#### 1. Fork the repository

If you haven't already (from Option A), fork **https://github.com/BioDepot/scRNA-serverless** to your own GitHub account.

#### 2. Add Codespaces secrets

Go to **https://github.com/settings/codespaces** and add three secrets using the values provided by the authors:

| Secret name | Value | Repository access |
|---|---|---|
| `SSH_USER` | *(provided by authors)* | Your fork (e.g. `your-username/scRNA-serverless`) |
| `SSH_PASSWORD` | *(provided by authors)* | Your fork |
| `SERVER_HOST` | *(provided by authors)* | Your fork |

Set each secret's repository access to your fork (or "All repositories").

#### 3. Create a Codespace

Go to **your fork** on GitHub. Click **Code** → **Codespaces** → **Create codespace on master**.

The Codespace will build automatically using the included `.devcontainer/devcontainer.json` configuration, which installs `sshpass` and Python.

> **Important:** Delete the Codespace when you're done (go to github.com/codespaces → delete). Stopped Codespaces still consume storage quota.

### Running the pipeline

Once the Codespace terminal is ready:

```bash
# Dry-run (verify connectivity, tools, references, disk — takes < 1 min)
bash scripts/e2e_onserver_pbmc.sh pbmc1k --dry-run

# Full run — PBMC 1K (~3–5 min)
bash scripts/e2e_onserver_pbmc.sh pbmc1k
```

Optional flags:

```bash
RUN_QC=0 bash scripts/e2e_onserver_pbmc.sh pbmc1k          # skip QC
WRITE_H5AD=1 bash scripts/e2e_onserver_pbmc.sh pbmc1k       # save h5ad
```

### Where are results?

Results are downloaded to the `onserver_runs/` directory inside the Codespace. You can browse them in the Codespace file explorer (left sidebar) or download them:

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

## Running PBMC 10K (optional)

By default, only PBMC 1K is enabled. The pipeline fully supports PBMC 10K — it is disabled to conserve server disk space for routine reviewer runs. To enable it:

### Via Codespaces

Open a Codespace on the repository, then run:

```bash
ALLOW_10K=1 bash scripts/e2e_onserver_pbmc.sh pbmc10k
```

No file edits needed — the `ALLOW_10K=1` flag bypasses the guard.

### Via GitHub Actions (requires a fork)

1. **Fork** the repository to your own GitHub account
2. In your fork, edit `.github/workflows/onserver-pipeline.yml`
3. Find the `dataset` options and uncomment `pbmc10k`:

```yaml
        options:
          - pbmc1k
          - pbmc10k  # uncomment this line
```

4. Set your three secrets (`SSH_USER`, `SSH_PASSWORD`, `SERVER_HOST`) in your fork's **Settings → Secrets and variables → Actions**
5. Run the workflow from your fork — select `pbmc10k` as the dataset

### Disk requirements

PBMC 10K requires **20 GB+ free** on the server (with cached FASTQs) or **60 GB+** (first run, FASTQs not yet downloaded). The PBMC 10K FASTQ dataset is approximately 44 GB.

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

The pipeline connects to the server over SSH. Three credentials are required: `SSH_USER`, `SSH_PASSWORD`, and `SERVER_HOST`.

**For reviewers:** The authors will provide server credentials (a guest account). To use them:

1. **Fork** the repository to your own GitHub account
2. In your fork, go to **Settings → Secrets and variables → Actions**
3. Add the three secrets with the values provided by the authors
4. Run the workflow from your fork's **Actions** tab

The secrets are encrypted by GitHub and injected at runtime — they are never visible in logs, code, or workflow output. All terminal output (including third-party tool logs) automatically masks the username and IP, replacing them with `***`.

| Method | Where to set all 3 secrets |
|---|---|
| GitHub Actions | Fork the repo → **Settings → Secrets and variables → Actions** |
| Codespaces | **github.com/settings/codespaces** (set repository access to your fork) |
| Local terminal | `.env` file in the repo root (see Option C) |

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
| "No such file or directory: e2e_onserver_pbmc.sh" | Make sure you selected the `master` branch when triggering the workflow. |
| Stuck on "Downloading FASTQ files" | PBMC 1K is ~5 GB, 10K is ~44 GB. First download takes time. Subsequent runs use cache. |
| No artifacts after Actions run | Make sure you selected `full-run`, not `dry-run`. |
| Where are old runs? | **Actions:** click any previous run → download artifact (kept 30 days). **Codespaces:** check `onserver_runs/` in the file explorer. |
| Run cancelled / interrupted | No cleanup needed. The next run auto-cleans leftover files before starting. |
| Codespace can't connect to server | Run `echo $SSH_USER` in the terminal — if blank, your Codespaces secrets aren't set or don't have access to this repo. |
| Codespace shows raw IP/username | Pull the latest code: `git pull origin master`. The masking fix requires the latest version. |
