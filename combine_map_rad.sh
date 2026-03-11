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

# Single file: copy directly (radtk cat skips output for single inputs)
if [ ${#map_rad_paths[@]} -eq 1 ]; then
    cp "${map_rad_paths[0]}" "$COMBINED_OUTPUT_DIR/map.rad"
    echo "Copied single map.rad to $COMBINED_OUTPUT_DIR/map.rad"
elif [ ${#map_rad_paths[@]} -gt 1 ]; then
    map_rad_paths_combined=$(IFS=,; echo "${map_rad_paths[*]}")
    radtk cat -i "${map_rad_paths_combined}" -o "$COMBINED_OUTPUT_DIR/map.rad"
    if [ $? -eq 0 ]; then
        echo "Concatenated map.rad files into $COMBINED_OUTPUT_DIR/map.rad"
    else
        echo "Concatenating map.rad files failed"
        exit 1
    fi
else
    echo "No map.rad files found in $BASE_DIR/piscem_output/"
    exit 1
fi