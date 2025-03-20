#!/bin/bash

# Base directory containing the set_1, set_2 subdirectories
#BASE_DIR="/mnt/nvme/morphic-msk/output"
BASE_DIR="$1"

# Output directory for the concatenated files
#COMBINED_OUTPUT_DIR="/mnt/nvme/morphic-msk/combined_output"
COMBINED_OUTPUT_DIR="$2"
mkdir -p "$COMBINED_OUTPUT_DIR"

# Output file for concatenated unmapped_bc_count.bin files
OUTPUT_FILE="$COMBINED_OUTPUT_DIR/unmapped_bc_count.bin"

# Initialize an empty array to hold the unmapped_bc_count.bin paths
bin_paths=()

# Loop through each set directory in BASE_DIR
for sub_dir in $(find "$BASE_DIR"/piscem_output/ -mindepth 1 -maxdepth 1 -type d | sort); do
    # Check if the subdirectory contains an unmapped_bc_count.bin file
    if [[ -f "$sub_dir/unmapped_bc_count.bin" ]]; then
        # Add the unmapped_bc_count.bin path to the array
        bin_paths+=("$sub_dir/unmapped_bc_count.bin")
    fi
done

# Concatenate all the unmapped_bc_count.bin files into one file
cat "${bin_paths[@]}" > "$OUTPUT_FILE"
echo "Concatenated unmapped_bc_count.bin files into $OUTPUT_FILE"