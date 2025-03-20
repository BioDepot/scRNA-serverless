#!/bin/bash

# Download the binary
wget https://github.com/COMBINE-lab/alevin-fry/releases/download/v0.9.0/alevin-fry-x86_64-unknown-linux-gnu.tar.xz

# Extract the archive
tar -xvf alevin-fry-x86_64-unknown-linux-gnu.tar.xz

# Move the binary to /usr/local/bin
sudo mv alevin-fry-x86_64-unknown-linux-gnu/alevin-fry /usr/local/bin/

# Give execution permissions
sudo chmod +x /usr/local/bin/alevin-fry

# Verify installation
alevin-fry --help

# cleanup
rm alevin-fry-x86_64-unknown-linux-gnu.tar.xz
rm -rf alevin-fry-x86_64-unknown-linux-gnu