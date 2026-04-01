# Serverless scRNA Pipeline

This pipeline processes single-cell RNA sequencing (scRNA-seq) data using the Piscem-Alevin-Fry workflow. It supports two execution modes:

1. **Serverless (AWS Lambda)** — Parallel read mapping across multiple Lambda instances for large-scale speedup.
2. **Standalone (any Linux machine)** — Run the full pipeline locally with no cloud dependencies.

Both modes produce identical gene-by-cell count matrices.

---

## Quick start (standalone)

```bash
git clone https://github.com/BioDepot/scRNA-serverless.git
cd scRNA-serverless
bash scripts/e2e_standalone_pbmc.sh pbmc1k
```

Everything (tools, reference data, FASTQs) is downloaded automatically from public sources. See the [On-Server Pipeline Guide](docs/ONSERVER_GUIDE.md) for details.

---

## Documentation

| Guide | Description |
|---|---|
| [On-Server Pipeline Guide](docs/ONSERVER_GUIDE.md) | Run the on-server pipeline on any Linux machine — no credentials needed, everything downloaded automatically |
| [Serverless Pipeline Guide](docs/SERVERLESS_GUIDE.md) | Step-by-step instructions to run the serverless pipeline on your own AWS account (requires AWS, **us-east-2** region) |
| [Reproducibility Notes](docs/REPRODUCIBILITY_NOTES.md) | Automatic fallbacks for AWS account limits, configuration reference, and local disk requirements |
