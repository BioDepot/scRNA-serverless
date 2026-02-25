#!/usr/bin/env python3
"""
qc_serverless.py

Quality control analysis for alevin-fry quantification outputs using scanpy.
Used by the serverless pipeline (e2e_serverless_pbmc.sh).

USAGE:
    python3 scripts/qc_serverless.py <quants_dir> [--outdir <output_dir>] [--write-h5ad]

ARGUMENTS:
    quants_dir      Path to alevin-fry quantification output directory
                    (should contain quants_mat.mtx and barcodes/genes files)

OPTIONS:
    --outdir        Output directory for plots and h5ad (default: analysis/out)
    --write-h5ad    Save AnnData object as h5ad file

OUTPUT:
    - umap_leiden.png      UMAP with Leiden clustering
    - qc_violin.png        QC metrics violin plot
    - pbmc_adata.h5ad      (optional) Full AnnData object
"""

import argparse
import os
import sys
import logging
import gzip
from pathlib import Path
from typing import Optional, Tuple, Union, IO

import numpy as np
import scanpy as sc
import matplotlib.pyplot as plt
import seaborn as sns
from scipy.io import mmread

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(levelname)s] %(message)s'
)
logger = logging.getLogger(__name__)


def open_maybe_gzip(path: Path, mode: str = 'rt') -> Union[IO, gzip.GzipFile]:
    """
    Open a file, using gzip if it has .gz extension.
    
    Args:
        path: Path to file
        mode: File open mode ('rt' for text, 'rb' for binary)
        
    Returns:
        File handle
    """
    if str(path).endswith('.gz'):
        return gzip.open(path, mode)
    else:
        return open(path, mode)


def _search_file(base_dir: Path, names: list) -> Optional[Path]:
    """Search for a file by name in a directory and its immediate subdirectories."""
    for name in names:
        path = base_dir / name
        if path.exists():
            return path
    for subdir in sorted(base_dir.iterdir()):
        if subdir.is_dir():
            for name in names:
                path = subdir / name
                if path.exists():
                    return path
    return None


def find_matrix_file(quants_dir: Path) -> Path:
    """Find the matrix file in quantification directory."""
    common_names = ['quants_mat.mtx', 'quants_mat.mtx.gz']
    result = _search_file(quants_dir, common_names)
    if result:
        return result
    raise FileNotFoundError(
        f"Could not find matrix file in {quants_dir}. "
        f"Looked for: {', '.join(common_names)}"
    )


def find_feature_file(quants_dir: Path) -> Path:
    """Find the gene/feature file in quantification directory."""
    common_names = ['quants_mat_rows.txt', 'genes.tsv', 'genes.tsv.gz']
    result = _search_file(quants_dir, common_names)
    if result:
        return result
    raise FileNotFoundError(
        f"Could not find feature/gene file in {quants_dir}. "
        f"Looked for: {', '.join(common_names)}"
    )


def find_barcode_file(quants_dir: Path) -> Path:
    """Find the barcode/cell file in quantification directory."""
    common_names = ['quants_mat_cols.txt', 'barcodes.tsv', 'barcodes.tsv.gz']
    result = _search_file(quants_dir, common_names)
    if result:
        return result
    raise FileNotFoundError(
        f"Could not find barcode/cell file in {quants_dir}. "
        f"Looked for: {', '.join(common_names)}"
    )


def load_mtx_data(quants_dir: Path) -> sc.AnnData:
    """
    Load MTX format matrix and create AnnData object.
    
    Args:
        quants_dir: Path to quantification directory
        
    Returns:
        sc.AnnData object with matrix, genes, and barcodes
    """
    logger.info(f"Loading quantification data from {quants_dir}")
    
    # Find files
    matrix_file = find_matrix_file(quants_dir)
    feature_file = find_feature_file(quants_dir)
    barcode_file = find_barcode_file(quants_dir)
    
    logger.info(f"Matrix file: {matrix_file.name}")
    logger.info(f"Feature file: {feature_file.name}")
    logger.info(f"Barcode file: {barcode_file.name}")
    
    # Load matrix (MTX is cells x genes, we need to transpose)
    logger.info("Reading matrix...")
    if str(matrix_file).endswith('.gz'):
        with gzip.open(matrix_file, 'rb') as fh:
            matrix = mmread(fh)
    else:
        matrix = mmread(str(matrix_file))
    matrix = matrix.T.tocsr()  # Transpose: genes x cells -> cells x genes
    
    # Load features (genes)
    logger.info("Reading features...")
    with open_maybe_gzip(feature_file, 'rt') as f:
        # Try reading as TSV first (might have description column), then fallback to plain text
        genes = []
        for line in f:
            parts = line.strip().split('\t')
            genes.append(parts[0])
    
    # Load barcodes (cells)
    logger.info("Reading barcodes...")
    with open_maybe_gzip(barcode_file, 'rt') as f:
        barcodes = [line.strip() for line in f]
    
    logger.info(f"Matrix shape: {matrix.shape}")
    logger.info(f"Genes: {len(genes)}, Barcodes: {len(barcodes)}")
    
    if matrix.shape[1] != len(genes):
        raise ValueError(
            f"Matrix genes ({matrix.shape[1]}) != loaded genes ({len(genes)})"
        )
    
    if matrix.shape[0] != len(barcodes):
        raise ValueError(
            f"Matrix barcodes ({matrix.shape[0]}) != loaded barcodes ({len(barcodes)})"
        )
    
    # Create AnnData
    adata = sc.AnnData(X=matrix)
    adata.obs_names = barcodes
    adata.var_names = genes
    
    logger.info(f"AnnData object created: {adata.n_obs} cells x {adata.n_vars} genes")
    
    return adata


def compute_qc_metrics(adata: sc.AnnData) -> sc.AnnData:
    """
    Compute QC metrics including mitochondrial gene content.
    
    Args:
        adata: AnnData object
        
    Returns:
        AnnData with QC metrics in .obs
    """
    logger.info("Computing QC metrics...")
    
    # Identify mitochondrial genes (common patterns)
    mt_patterns = ['MT-', 'mt-', 'MT_', 'mt_']
    mt_genes = adata.var_names.str.contains('|'.join(mt_patterns), case=False)
    
    logger.info(f"Found {mt_genes.sum()} mitochondrial genes")
    
    # Compute metrics
    adata.var['MT'] = mt_genes
    qc_var_list = ['MT'] if mt_genes.sum() > 0 else []
    sc.pp.calculate_qc_metrics(adata, qc_vars=qc_var_list, inplace=True)
    
    # Manual MT gene percentage calculation
    if mt_genes.sum() > 0:
        mt_counts = adata.X[:, mt_genes].sum(axis=1).A1 if hasattr(adata.X, 'A1') else adata.X[:, mt_genes].sum(axis=1)
        total_counts = adata.obs['total_counts'].values
        adata.obs['pct_mt'] = (mt_counts / total_counts) * 100
        logger.info(f"Computed MT% per cell (range: {adata.obs['pct_mt'].min():.2f}%-{adata.obs['pct_mt'].max():.2f}%)")
    else:
        logger.warning("No mitochondrial genes detected")
        adata.obs['pct_mt'] = 0
    
    return adata


def preprocess_and_analyze(adata: sc.AnnData) -> sc.AnnData:
    """
    Normalize, find HVGs, compute PCA, neighbors, UMAP, and Leiden clustering.
    
    Args:
        adata: AnnData object with QC metrics
        
    Returns:
        Processed AnnData object
    """
    logger.info("Preprocessing data...")
    
    # Remove cells with very low counts
    sc.pp.filter_cells(adata, min_counts=500)
    logger.info(f"After cell filtering: {adata.n_obs} cells")
    
    # Remove genes with very low expression
    sc.pp.filter_genes(adata, min_cells=3)
    logger.info(f"After gene filtering: {adata.n_vars} genes")
    
    # Normalize
    logger.info("Normalizing...")
    sc.pp.normalize_total(adata, target_sum=1e6)
    sc.pp.log1p(adata)
    
    # Find highly variable genes
    logger.info("Finding highly variable genes...")
    sc.pp.highly_variable_genes(adata, min_mean=0.0125, max_mean=3, min_disp=0.5)
    hvg_count = int(adata.var['highly_variable'].sum())
    logger.info(f"Found {hvg_count} HVGs")
    
    if hvg_count < 2:
        logger.warning("Too few HVGs — skipping PCA/UMAP")
        adata.obs['leiden'] = 'unclustered'
        return adata
    
    # Subset to HVGs
    adata = adata[:, adata.var['highly_variable']].copy()
    
    # PCA
    sc.pp.scale(adata, max_value=10)
    n_comps = min(50, adata.n_obs - 1, adata.n_vars - 1)
    if n_comps < 2:
        logger.warning("Not enough dimensions for PCA")
        adata.obs['leiden'] = 'unclustered'
        return adata
    logger.info(f"Computing PCA (n_comps={n_comps})...")
    sc.tl.pca(adata, n_comps=n_comps)
    
    # Neighbors
    n_pcs = min(30, n_comps)
    n_neighbors = min(15, adata.n_obs - 1)
    logger.info(f"Computing neighbors (n_neighbors={n_neighbors}, n_pcs={n_pcs})...")
    sc.pp.neighbors(adata, use_rep='X_pca', n_neighbors=n_neighbors, n_pcs=n_pcs)
    
    # UMAP
    logger.info("Computing UMAP...")
    sc.tl.umap(adata)
    
    # Leiden clustering with fallback to Louvain
    logger.info("Running Leiden clustering...")
    try:
        sc.tl.leiden(adata, key_added='leiden', flavor='igraph')
        cluster_count = adata.obs['leiden'].nunique()
        logger.info(f"Found {cluster_count} Leiden clusters")
    except Exception as e:
        logger.warning(f"Leiden clustering failed ({str(e)[:50]}...), falling back to Louvain")
        try:
            sc.tl.louvain(adata, key_added='leiden')
            cluster_count = adata.obs['leiden'].nunique()
            logger.info(f"Found {cluster_count} Louvain clusters")
        except Exception as e2:
            logger.warning(f"Louvain clustering also failed ({str(e2)[:50]}...). Skipping clustering, will use other metadata for plots.")
            adata.obs['leiden'] = 'unclustered'
    
    return adata


def generate_plots(adata: sc.AnnData, outdir: Path) -> None:
    """
    Generate UMAP and QC violin plots.
    
    Args:
        adata: Processed AnnData object
        outdir: Output directory for plots
    """
    outdir.mkdir(parents=True, exist_ok=True)
    
    # Set style
    sc.set_figure_params(dpi=100, facecolor='white')
    
    # UMAP with clustering (leiden if available, else all same color)
    logger.info("Generating UMAP plot...")
    fig = plt.figure(figsize=(10, 8))
    
    color_by = 'leiden' if 'leiden' in adata.obs else None
    title = 'UMAP with Leiden Clusters' if color_by else 'UMAP (no clustering)'
    
    try:
        sc.pl.umap(adata, color=color_by, legend_loc='on data' if color_by else None, 
                   title=title, show=False, size=30)
        plt.tight_layout()
        umap_path = outdir / 'umap_leiden.png'
        plt.savefig(umap_path, dpi=150, bbox_inches='tight')
        plt.close()
        logger.info(f"Saved: {umap_path}")
    except Exception as e:
        logger.warning(f"UMAP plot generation failed ({str(e)[:50]}...). Skipping.")
        plt.close('all')
    
    # QC metrics violin plot
    logger.info("Generating QC violin plot...")
    try:
        fig, axes = plt.subplots(1, 3, figsize=(15, 5))
        
        # n_counts violin
        sns.violinplot(y=adata.obs['total_counts'], ax=axes[0])
        axes[0].set_ylabel('Total Counts')
        axes[0].set_title('UMI per Cell')
        
        # n_genes violin
        sns.violinplot(y=adata.obs['n_genes_by_counts'], ax=axes[1])
        axes[1].set_ylabel('Genes Detected')
        axes[1].set_title('Genes per Cell')
        
        # MT% violin (if available)
        if 'pct_mt' in adata.obs:
            sns.violinplot(y=adata.obs['pct_mt'], ax=axes[2])
            axes[2].set_ylabel('MT%')
            axes[2].set_title('Mitochondrial %')
        else:
            axes[2].text(0.5, 0.5, 'No MT data', ha='center', va='center')
        
        plt.tight_layout()
        qc_path = outdir / 'qc_violin.png'
        plt.savefig(qc_path, dpi=150, bbox_inches='tight')
        plt.close()
        logger.info(f"Saved: {qc_path}")
    except Exception as e:
        logger.warning(f"QC violin plot generation failed ({str(e)[:50]}...). Skipping.")
        plt.close('all')


def main():
    run_qc_env = os.getenv("RUN_QC", "1")
    if run_qc_env == "0":
        logger.info("RUN_QC=0 detected. Skipping QC analysis.")
        return

    parser = argparse.ArgumentParser(
        description='QC analysis for alevin-fry quantification using scanpy (serverless pipeline)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python3 qc_serverless.py /path/to/alevin_output
    python3 qc_serverless.py /path/to/alevin_output --outdir ./qc_results
    python3 qc_serverless.py /path/to/alevin_output --outdir ./qc_results --write-h5ad
        """
    )
    
    parser.add_argument(
        'quants_dir',
        type=str,
        help='Path to alevin-fry quantification output directory'
    )
    
    parser.add_argument(
        '--outdir',
        type=str,
        default='analysis/out',
        help='Output directory for plots and h5ad (default: analysis/out)'
    )
    
    parser.add_argument(
        '--write-h5ad',
        action='store_true',
        help='Save AnnData object as h5ad file'
    )
    
    args = parser.parse_args()
    
    # Validate input
    quants_dir = Path(args.quants_dir)
    if not quants_dir.exists():
        logger.error(f"Quantification directory does not exist: {quants_dir}")
        sys.exit(1)
    
    outdir = Path(args.outdir)
    
    try:
        # Load data
        adata = load_mtx_data(quants_dir)
        
        # Compute QC metrics
        adata = compute_qc_metrics(adata)
        
        # Preprocess and analyze
        adata = preprocess_and_analyze(adata)
        
        # Generate plots
        generate_plots(adata, outdir)
        
        # Save H5AD if requested
        if args.write_h5ad:
            outdir.mkdir(parents=True, exist_ok=True)
            h5ad_path = outdir / 'pbmc_adata.h5ad'
            logger.info(f"Saving h5ad file: {h5ad_path}")
            adata.write_h5ad(str(h5ad_path))
            logger.info(f"Saved: {h5ad_path}")
        
        logger.info("========== QC Analysis Complete ==========")
        logger.info(f"Output directory: {outdir}")
        
    except Exception as e:
        logger.error(f"Error during QC analysis: {e}", exc_info=True)
        sys.exit(1)


if __name__ == '__main__':
    main()
