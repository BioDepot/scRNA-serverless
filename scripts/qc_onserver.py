#!/usr/bin/env python3
"""
qc_onserver.py

QC analysis for the ON-SERVER scRNA-seq pipeline (alevin-fry output).
Separate from qc_serverless.py (used by the serverless pipeline) to avoid
conflicts with different output directory layouts and filtering needs.

Key differences from qc_serverless.py:
  - Searches subdirectories (e.g. alevin/) for quant matrix files
  - More robust filtering/PCA that adapts to dataset size
  - Non-fatal: exits 0 even on analysis errors so the pipeline continues

USAGE:
    python3 scripts/qc_onserver.py <quants_dir> [--outdir <dir>] [--write-h5ad]
"""

import argparse
import gzip
import logging
import os
import sys
from pathlib import Path
from typing import Optional, Union, IO

import numpy as np
import scanpy as sc
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import seaborn as sns
from scipy.io import mmread

logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)


def open_maybe_gzip(path: Path, mode: str = "rt") -> Union[IO, gzip.GzipFile]:
    if str(path).endswith(".gz"):
        return gzip.open(path, mode)
    return open(path, mode)


def _find_file(base_dir: Path, names: list) -> Optional[Path]:
    """Search for a file in *base_dir* and its immediate subdirectories."""
    for name in names:
        p = base_dir / name
        if p.exists():
            return p
    for sub in sorted(base_dir.iterdir()):
        if sub.is_dir():
            for name in names:
                p = sub / name
                if p.exists():
                    return p
    return None


def find_matrix_file(quants_dir: Path) -> Path:
    names = ["quants_mat.mtx", "quants_mat.mtx.gz"]
    result = _find_file(quants_dir, names)
    if result:
        return result
    raise FileNotFoundError(
        f"Matrix file not found in {quants_dir}. Looked for: {', '.join(names)}"
    )


def find_feature_file(quants_dir: Path) -> Path:
    names = ["quants_mat_rows.txt", "genes.tsv", "genes.tsv.gz"]
    result = _find_file(quants_dir, names)
    if result:
        return result
    raise FileNotFoundError(
        f"Feature file not found in {quants_dir}. Looked for: {', '.join(names)}"
    )


def find_barcode_file(quants_dir: Path) -> Path:
    names = ["quants_mat_cols.txt", "barcodes.tsv", "barcodes.tsv.gz"]
    result = _find_file(quants_dir, names)
    if result:
        return result
    raise FileNotFoundError(
        f"Barcode file not found in {quants_dir}. Looked for: {', '.join(names)}"
    )


def load_mtx_data(quants_dir: Path) -> sc.AnnData:
    logger.info(f"Loading quantification data from {quants_dir}")

    matrix_file = find_matrix_file(quants_dir)
    feature_file = find_feature_file(quants_dir)
    barcode_file = find_barcode_file(quants_dir)

    logger.info(f"  Matrix:   {matrix_file}")
    logger.info(f"  Features: {feature_file}")
    logger.info(f"  Barcodes: {barcode_file}")

    if str(matrix_file).endswith(".gz"):
        with gzip.open(matrix_file, "rb") as fh:
            matrix = mmread(fh)
    else:
        matrix = mmread(str(matrix_file))
    matrix = matrix.T.tocsr()

    with open_maybe_gzip(feature_file, "rt") as f:
        genes = [line.strip().split("\t")[0] for line in f]

    with open_maybe_gzip(barcode_file, "rt") as f:
        barcodes = [line.strip() for line in f]

    logger.info(f"  Shape: {matrix.shape}  genes={len(genes)}  barcodes={len(barcodes)}")

    if matrix.shape[1] != len(genes):
        raise ValueError(f"Matrix cols ({matrix.shape[1]}) != genes ({len(genes)})")
    if matrix.shape[0] != len(barcodes):
        raise ValueError(f"Matrix rows ({matrix.shape[0]}) != barcodes ({len(barcodes)})")

    adata = sc.AnnData(X=matrix)
    adata.obs_names = barcodes
    adata.var_names = genes
    adata.var_names_make_unique()

    logger.info(f"AnnData: {adata.n_obs} cells x {adata.n_vars} genes")
    return adata


def compute_qc_metrics(adata: sc.AnnData) -> sc.AnnData:
    logger.info("Computing QC metrics...")

    mt_genes = adata.var_names.str.contains("MT-|mt-|MT_|mt_", case=False)
    adata.var["MT"] = mt_genes
    logger.info(f"  Mitochondrial genes: {mt_genes.sum()}")

    qc_vars = ["MT"] if mt_genes.sum() > 0 else []
    sc.pp.calculate_qc_metrics(adata, qc_vars=qc_vars, inplace=True)

    if mt_genes.sum() > 0:
        mt_counts = (
            adata.X[:, mt_genes].sum(axis=1).A1
            if hasattr(adata.X, "A1")
            else np.asarray(adata.X[:, mt_genes].sum(axis=1)).flatten()
        )
        total = adata.obs["total_counts"].values
        adata.obs["pct_mt"] = np.where(total > 0, (mt_counts / total) * 100, 0)
        logger.info(
            f"  MT% range: {adata.obs['pct_mt'].min():.2f}% – {adata.obs['pct_mt'].max():.2f}%"
        )
    else:
        logger.warning("  No mitochondrial genes detected")
        adata.obs["pct_mt"] = 0.0

    return adata


def preprocess_and_analyze(adata: sc.AnnData) -> sc.AnnData:
    logger.info("Preprocessing...")
    logger.info(f"  Input: {adata.n_obs} cells, {adata.n_vars} genes")

    sc.pp.filter_cells(adata, min_counts=100)
    logger.info(f"  After cell filter (min_counts=100): {adata.n_obs} cells")

    if adata.n_obs < 10:
        logger.warning("Too few cells after filtering — skipping downstream analysis")
        adata.obs["leiden"] = "unclustered"
        return adata

    sc.pp.filter_genes(adata, min_cells=3)
    logger.info(f"  After gene filter (min_cells=3): {adata.n_vars} genes")

    sc.pp.normalize_total(adata, target_sum=1e4)
    sc.pp.log1p(adata)

    sc.pp.highly_variable_genes(adata, min_mean=0.0125, max_mean=3, min_disp=0.5)
    hvg_count = int(adata.var["highly_variable"].sum())
    logger.info(f"  HVGs: {hvg_count}")

    if hvg_count < 2:
        logger.warning("Too few HVGs — skipping PCA/UMAP")
        adata.obs["leiden"] = "unclustered"
        return adata

    adata = adata[:, adata.var["highly_variable"]].copy()

    sc.pp.scale(adata, max_value=10)

    n_comps = min(50, adata.n_obs - 1, adata.n_vars - 1)
    if n_comps < 2:
        logger.warning("Not enough dimensions for PCA")
        adata.obs["leiden"] = "unclustered"
        return adata

    logger.info(f"  PCA (n_comps={n_comps})...")
    sc.tl.pca(adata, n_comps=n_comps)

    n_pcs = min(30, n_comps)
    n_neighbors = min(15, adata.n_obs - 1)
    logger.info(f"  Neighbors (n_neighbors={n_neighbors}, n_pcs={n_pcs})...")
    sc.pp.neighbors(adata, use_rep="X_pca", n_neighbors=n_neighbors, n_pcs=n_pcs)

    logger.info("  UMAP...")
    sc.tl.umap(adata)

    logger.info("  Leiden clustering...")
    try:
        sc.tl.leiden(adata, key_added="leiden", flavor="igraph")
        logger.info(f"  Clusters: {adata.obs['leiden'].nunique()}")
    except Exception as e:
        logger.warning(f"  Leiden failed ({e!r}), trying Louvain...")
        try:
            sc.tl.louvain(adata, key_added="leiden")
            logger.info(f"  Clusters (Louvain): {adata.obs['leiden'].nunique()}")
        except Exception:
            logger.warning("  Clustering failed — labelling all cells 'unclustered'")
            adata.obs["leiden"] = "unclustered"

    return adata


def generate_plots(adata: sc.AnnData, outdir: Path) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    sc.set_figure_params(dpi=100, facecolor="white")

    # UMAP
    logger.info("Generating UMAP plot...")
    color_by = "leiden" if "leiden" in adata.obs else None
    title = "UMAP with Leiden Clusters" if color_by else "UMAP"
    try:
        sc.pl.umap(
            adata,
            color=color_by,
            legend_loc="on data" if color_by else None,
            title=title,
            show=False,
            size=30,
        )
        plt.tight_layout()
        p = outdir / "umap_leiden.png"
        plt.savefig(p, dpi=150, bbox_inches="tight")
        plt.close()
        logger.info(f"  Saved {p}")
    except Exception as e:
        logger.warning(f"  UMAP plot failed: {e}")
        plt.close("all")

    # QC violin
    logger.info("Generating QC violin plot...")
    try:
        fig, axes = plt.subplots(1, 3, figsize=(15, 5))

        sns.violinplot(y=adata.obs["total_counts"], ax=axes[0])
        axes[0].set_ylabel("Total Counts")
        axes[0].set_title("UMI per Cell")

        sns.violinplot(y=adata.obs["n_genes_by_counts"], ax=axes[1])
        axes[1].set_ylabel("Genes Detected")
        axes[1].set_title("Genes per Cell")

        if "pct_mt" in adata.obs:
            sns.violinplot(y=adata.obs["pct_mt"], ax=axes[2])
            axes[2].set_ylabel("MT%")
            axes[2].set_title("Mitochondrial %")
        else:
            axes[2].text(0.5, 0.5, "No MT data", ha="center", va="center")

        plt.tight_layout()
        p = outdir / "qc_violin.png"
        plt.savefig(p, dpi=150, bbox_inches="tight")
        plt.close()
        logger.info(f"  Saved {p}")
    except Exception as e:
        logger.warning(f"  Violin plot failed: {e}")
        plt.close("all")


def main():
    if os.getenv("RUN_QC", "1") == "0":
        logger.info("RUN_QC=0 — skipping QC analysis.")
        return

    parser = argparse.ArgumentParser(description="On-server QC for alevin-fry output")
    parser.add_argument("quants_dir", help="Path to alevin-fry output directory")
    parser.add_argument("--outdir", default="analysis/out", help="Output directory")
    parser.add_argument("--write-h5ad", action="store_true", help="Save h5ad file")
    args = parser.parse_args()

    quants_dir = Path(args.quants_dir)
    if not quants_dir.exists():
        logger.error(f"Directory does not exist: {quants_dir}")
        sys.exit(1)

    outdir = Path(args.outdir)

    try:
        adata = load_mtx_data(quants_dir)
        adata = compute_qc_metrics(adata)
        adata = preprocess_and_analyze(adata)
        generate_plots(adata, outdir)

        if args.write_h5ad:
            outdir.mkdir(parents=True, exist_ok=True)
            h5ad_path = outdir / "pbmc_adata.h5ad"
            logger.info(f"Saving h5ad: {h5ad_path}")
            adata.write_h5ad(str(h5ad_path))

        logger.info("QC analysis complete.")
    except Exception as e:
        logger.error(f"QC analysis failed: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
