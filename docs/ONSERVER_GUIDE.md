# On-Server Pipeline Guide

Run the scRNA-seq pipeline on **any Linux machine**. Everything is downloaded automatically from public sources — no special accounts, no credentials, no remote server access needed.

| Component | Source | Size |
|---|---|---|
| Tools (piscem, alevin-fry, radtk) | [GitHub Releases](https://github.com/COMBINE-lab) | ~30 MB |
| Reference index + t2g.tsv | [Zenodo (record 19375096)](https://zenodo.org/records/19375096) | ~177 MB |
| PBMC 1K FASTQs | [10x Genomics](https://www.10xgenomics.com/datasets) | ~5 GB |

> **No AWS account needed.** No S3, no Lambda, no EC2. No server credentials.

---

## Prerequisites

- A **Linux x86_64** machine (Ubuntu, Debian, CentOS, or similar; WSL2 on Windows also works)
- `git`, `curl`, `tar`, `gzip`, `bc` (standard on virtually all Linux systems)
- `python3` (for QC plots — pre-installed on most systems)
- **~10 GB free disk space** for PBMC 1K

That's it. The script installs all pipeline tools automatically.

---

## Quick start

```bash
# 1. Clone the repository
git clone https://github.com/BioDepot/scRNA-serverless.git
cd scRNA-serverless

# 2. (Optional) Dry-run — checks tools, downloads reference, validates FASTQs
bash scripts/e2e_standalone_pbmc.sh pbmc1k --dry-run

# 3. Full run
bash scripts/e2e_standalone_pbmc.sh pbmc1k
```

The script will:
1. **Install tools** (piscem 0.10.3, alevin-fry 0.9.0, radtk 0.1.0) to `./tools/bin/` — no sudo needed
2. **Download the reference** (pre-built piscem index + t2g.tsv) from Zenodo (~177 MB)
3. **Download PBMC 1K FASTQs** from 10x Genomics (~5 GB)
4. **Run the pipeline** (piscem mapping → permit list → collate → quant)
5. **Generate QC plots** (UMAP + violin plots using scanpy)
6. **Save results** to `./standalone_runs/<run-id>/`

First run takes longer due to downloads. Subsequent runs reuse cached data.

---

## What the script checks automatically

| Check | What happens if it fails |
|---|---|
| Disk space | Exits with clear error message |
| Tools installed | Auto-installs from GitHub releases |
| Reference exists | Auto-downloads from Zenodo |
| FASTQs exist | Auto-downloads from 10x Genomics |
| FASTQ integrity | gzip integrity check; re-downloads if corrupt |
| R1/R2 file pairing | Exits if mismatched |

Use `--dry-run` to verify everything without running the pipeline.

---

## Output structure

```
standalone_runs/<run-id>/
├── run.env                         <-- Machine info, tool versions, timing
├── logs/
│   ├── piscem_map.log              <-- Piscem mapping log
│   ├── alevin_gpl.log              <-- generate-permit-list log
│   ├── alevin_collate.log          <-- Collate log
│   └── alevin_quant.log            <-- Quant log
├── piscem_output/
│   └── map_output/
│       └── map.rad                 <-- Raw piscem mapping output
├── alevin_output/
│   ├── alevin/
│   │   ├── quants_mat.mtx          <-- *** COUNT MATRIX ***
│   │   ├── quants_mat_rows.txt     <-- Gene names
│   │   └── quants_mat_cols.txt     <-- Cell barcodes
│   └── ...
└── analysis/out/                   (only if RUN_QC=1)
    ├── umap_leiden.png             <-- UMAP clustering plot
    ├── qc_violin.png               <-- QC violin plot
    └── pbmc_adata.h5ad             (only if WRITE_H5AD=1)
```

---

## Pipeline steps

The pipeline executes the Piscem-Alevin-Fry workflow described in the Methods section of the paper:

| Step | Tool | What it does |
|---|---|---|
| 0 | (auto) | Check/install piscem, alevin-fry, radtk |
| 1a | curl | Download reference from Zenodo (if not cached) |
| 1b | curl | Download FASTQs from 10x Genomics (if not cached) |
| 2 | piscem 0.10.3 | Map reads to transcriptome → `map.rad` |
| 3 | alevin-fry 0.9.0 | Generate permit list (knee-distance filtering) |
| 4 | alevin-fry 0.9.0 | Collate RAD file |
| 5 | alevin-fry 0.9.0 | Quantify → `quants_mat.mtx` |
| 6 | scanpy (optional) | UMAP + violin QC plots |

Download time (steps 0, 1a, 1b) is **not included** in the pipeline total — the paper assumes pre-staged data.

---

## Optional flags

```bash
RUN_QC=0 bash scripts/e2e_standalone_pbmc.sh pbmc1k          # skip QC plots
WRITE_H5AD=1 bash scripts/e2e_standalone_pbmc.sh pbmc1k       # save AnnData h5ad
THREADS=8 bash scripts/e2e_standalone_pbmc.sh pbmc1k           # limit threads (default: all cores)
```

---

## Running PBMC 10K (optional)

PBMC 10K is disabled by default. To enable:

```bash
ALLOW_10K=1 bash scripts/e2e_standalone_pbmc.sh pbmc10k
```

**Disk requirements:** ~50 GB free (the PBMC 10K FASTQ dataset alone is ~44 GB).

---

## Data caching

Downloaded data is cached in `./data/` and reused across runs:

```
data/
├── reference/
│   ├── index_output_transcriptome/   <-- piscem index (from Zenodo)
│   └── t2g.tsv                       <-- transcript-to-gene map
└── datasets/10x/
    └── pbmc_1k_v3/pbmc_1k_v3_fastqs/ <-- FASTQs (from 10x Genomics)
```

To force a fresh download, delete the corresponding directory and re-run.

---

## Directory overrides

You can customize where data, tools, and results are stored:

```bash
DATA_DIR=/path/to/data TOOLS_DIR=/path/to/tools RESULTS_DIR=/path/to/results \
    bash scripts/e2e_standalone_pbmc.sh pbmc1k
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "curl is required but not installed" | Install with `sudo apt-get install curl` (or your distro's package manager) |
| "python3 is required for QC" | Install with `sudo apt-get install python3 python3-venv` or skip QC with `RUN_QC=0` |
| "Insufficient disk space" | Free up space or use `DATA_DIR` to point to a larger partition |
| "Failed to install piscem" | Check internet connectivity; the script downloads from GitHub releases |
| "Reference download failed" | Check internet; try `curl -L https://zenodo.org/records/19375096/files/piscem_reference.tar.gz -o test.tar.gz` manually |
| Slow first run | First run downloads ~5 GB of FASTQs + 177 MB reference. Subsequent runs use cache |
| "Cannot find .sshash file" | Reference extraction failed. Delete `./data/reference/` and re-run |
| Want to use pre-existing tools | If piscem/alevin-fry/radtk are already in your PATH, the script uses them |
