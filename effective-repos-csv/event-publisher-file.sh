#!/bin/bash

# File system event publisher
# Copies repos-lock.csv to a local directory

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <source-file> <destination-path>"
    exit 1
fi

source_file="$1"
destination="$2"

# Extract directory and filename from destination
dest_dir=$(dirname "$destination")
dest_file=$(basename "$destination")

# Create destination directory if it doesn't exist
if [ ! -d "$dest_dir" ]; then
    echo "Creating directory: $dest_dir"
    mkdir -p "$dest_dir"
fi

# Create pending subdirectory if path doesn't explicitly include it
if [[ ! "$dest_dir" =~ pending/?$ ]] && [[ ! "$dest_dir" =~ processed/?$ ]]; then
    dest_dir="$dest_dir/pending"
    mkdir -p "$dest_dir"
    destination="$dest_dir/$dest_file"
fi

# Copy the file
echo "Copying $source_file to $destination"
cp "$source_file" "$destination"

# Verify the copy was successful
if [ -f "$destination" ]; then
    echo "File successfully published to: $destination"
    # Show file size for verification
    ls -lh "$destination" | awk '{print "  Size: " $5 " bytes"}'
else
    echo "Error: Failed to copy file to $destination"
    exit 1
fi