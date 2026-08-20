# Serverless scRNA Pipeline

This pipeline processes single-cell RNA sequencing (scRNA-seq) data using the Piscem-Alevin-Fry workflow. It supports two execution modes:

1. **Serverless (AWS Lambda)** — Parallel read mapping across multiple Lambda instances for large-scale speedup.
2. **On-server / Standalone (any Linux machine)** — Reproduces the traditional on-server execution baseline from the paper, running the full pipeline locally with no cloud dependencies.

Both modes produce identical gene-by-cell count matrices.

---

## Quick start (on-server baseline)

The standalone script reproduces the "On-Server (SSD) Execution" baseline from the paper (Table 2). It runs the identical Piscem-Alevin-Fry pipeline on any Linux x86_64 machine:

```bash
git clone https://github.com/BioDepot/scRNA-serverless.git
cd scRNA-serverless
bash scripts/e2e_standalone_pbmc.sh pbmc1k
```

Everything (tools, reference data, FASTQs) is downloaded automatically from public sources. The pre-built reference index is archived on Zenodo ([DOI: 10.5281/zenodo.19375096](https://doi.org/10.5281/zenodo.19375096)). See the [On-Server Pipeline Guide](docs/ONSERVER_GUIDE.md) for details.

## Quick start (serverless)

One script covers PBMC 1K, PBMC 10K, and the MSK KO dataset. After the one-time AWS setup in the [Serverless Pipeline Guide](docs/SERVERLESS_GUIDE.md):

```bash
bash scripts/e2e_serverless_pbmc.sh pbmc1k
bash scripts/e2e_serverless_pbmc.sh pbmc10k
bash scripts/e2e_serverless_pbmc.sh ko
```

The driver launches an **m5dn.8xlarge**, stripes both NVMe disks as RAID 0, splits FASTQs with rapidgzip `-P 8` and 2 lanes at a time, maps on Lambda, then runs alevin-fry on the instance.

---

## Documentation

| Guide | Description |
|---|---|
| [On-Server Pipeline Guide](docs/ONSERVER_GUIDE.md) | Run the on-server pipeline on any Linux machine — no credentials needed, everything downloaded automatically |
| [Serverless Pipeline Guide](docs/SERVERLESS_GUIDE.md) | Step-by-step instructions to run the serverless pipeline on your own AWS account (requires AWS, **us-east-2** region) |
| [Reproducibility Notes](docs/REPRODUCIBILITY_NOTES.md) | Automatic fallbacks for AWS account limits, configuration reference, and local disk requirements |
| [Direct S3 RAD Materializer](docs/S3_RAD_MATERIALIZER.md) | Ranged-download implementation and PBMC 1K benchmark |
| [Piscem Single-Shard NVMe Profile](docs/PISCEM_SHARD_PROFILE.md) | Six-thread PBMC shard timings for index loading, mapping, and RAD output |
| [Cloud Piscem Profiling Handoff](docs/CLOUD_PISCEM_PROFILE_HANDOFF.md) | Reproduce and diagnose one PBMC 1K shard on cloud NVMe |
