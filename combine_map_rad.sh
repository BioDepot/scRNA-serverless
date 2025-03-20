#!/bin/bash

# Base directory containing the piscem_output subdirectories
# BASE_DIR="/mnt/nvme/morphic-msk/output"
BASE_DIR="$1"

# Output directory for the concatenated files
#COMBINED_OUTPUT_DIR="/mnt/nvme/morphic-msk/combined_output"
COMBINED_OUTPUT_DIR="$2"
mkdir -p "$COMBINED_OUTPUT_DIR"

# Initialize an empty array to hold the map.rad paths
map_rad_paths=()

# Loop through each subdirectory in piscem_output in sorted order
for sub_dir in $(find "$BASE_DIR"/piscem_output/ -mindepth 1 -maxdepth 1 -type d | sort); do
    # Check if the subdirectory contains a map.rad file
    if [[ -f "$sub_dir/map.rad" ]]; then
        # Add the map.rad path to the array
        map_rad_paths+=("$sub_dir/map.rad")
    fi
done

# Join the array elements into a comma-separated string
map_rad_paths_combined=$(IFS=,; echo "${map_rad_paths[*]}")

# Concatenate the map.rad files using radtk
radtk cat -i "${map_rad_paths_combined}" -o "$COMBINED_OUTPUT_DIR/map.rad"

if [ $? -eq 0 ]; then
   echo "Concatenated map.rad files into $COMBINED_OUTPUT_DIR/map.rad"
else
   echo "Concatenating map.rad files failed"
fi