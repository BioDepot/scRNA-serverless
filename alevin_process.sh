COMBINED_OUTPUT_DIR="$1"
QUANT="$2"
TRANSCRIPTOME_GENE_MAPPING="$3"
echo "generating permit list"
alevin-fry generate-permit-list -d fw -k -i ${COMBINED_OUTPUT_DIR} -o ${QUANT}
echo "collating"
alevin-fry collate -t 16 -i ${QUANT} -r ${COMBINED_OUTPUT_DIR}
echo "quant"
alevin-fry quant -t 16 -i ${QUANT} -o ${QUANT} --tg-map ${TRANSCRIPTOME_GENE_MAPPING} --resolution cr-like --use-mtx
echo "alevin processing complete"
