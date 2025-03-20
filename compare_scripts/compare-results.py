import scanpy as sc

print("reading Data")
adata1 = sc.read_mtx('/mnt/nvme/pbmc1k-final-pipeline/quant/alevin/quants_mat.mtx')
print("reading serverless Data")
adata2 = sc.read_mtx('/mnt/nvme/pbmc1k_reference_output/alevin/quants_mat.mtx')
print(f"Dataset 1: {adata1.shape[0]} cells, {adata1.shape[1]} genes")
print(f"Dataset 2: {adata2.shape[0]} cells, {adata2.shape[1]} genes")

print(f"Dataset 1 sparsity: {adata1.X.nnz / adata1.X.size:.4f}")
print(f"Dataset 2 sparsity: {adata2.X.nnz / adata2.X.size:.4f}")


print(f"Dataset 1 Nonzero Count: {adata1.X.nnz}")
print(f"Dataset 2 Nonzero Count: {adata2.X.nnz}")

# Identify mitochondrial genes
adata1.var['mt'] = adata1.var_names.str.startswith('MT-') | adata1.var_names.str.startswith('mt-')
adata2.var['mt'] = adata2.var_names.str.startswith('MT-') | adata2.var_names.str.startswith('mt-')

# Add quality control metrics to AnnData objects
sc.pp.calculate_qc_metrics(adata1, qc_vars=['mt'], inplace=True)
sc.pp.calculate_qc_metrics(adata2, qc_vars=['mt'], inplace=True)

# Print QC metrics
print("Dataset 1 QC metrics:")
print(adata1.obs[['total_counts', 'n_genes_by_counts', 'pct_counts_mt']].describe())

print("Dataset 2 QC metrics:")
print(adata2.obs[['total_counts', 'n_genes_by_counts', 'pct_counts_mt']].describe())

