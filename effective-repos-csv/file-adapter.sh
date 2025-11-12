#!/bin/bash

# File system adapter for effective repos.csv
# Reads and writes effective repos.csv from/to local filesystem

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <action> <location> [local-file]"
    echo "  Actions:"
    echo "    download <file-path> <local-file> - Download effective repos.csv"
    echo "    upload <local-file> <file-path>   - Upload effective repos.csv"
    exit 1
fi

action="$1"
shift

case "$action" in
    download)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 download <file-path> <local-file>"
            exit 1
        fi

        source_path="$1"
        local_file="$2"

        if [ ! -f "$source_path" ]; then
            echo "File not found: $source_path"
            exit 1
        fi

        # Copy file
        cp "$source_path" "$local_file"
        echo "Downloaded $(wc -l < "$local_file") lines from $source_path"
        ;;

    upload)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 upload <local-file> <file-path>"
            exit 1
        fi

        local_file="$1"
        dest_path="$2"

        if [ ! -f "$local_file" ]; then
            echo "Error: Local file not found: $local_file"
            exit 1
        fi

        # Create backup if destination exists
        if [ -f "$dest_path" ]; then
            backup_path="${dest_path}.$(date +%Y%m%d_%H%M%S).bak"
            cp "$dest_path" "$backup_path"
            echo "Created backup: $backup_path"
        fi

        # Ensure directory exists
        dest_dir=$(dirname "$dest_path")
        if [ ! -d "$dest_dir" ]; then
            mkdir -p "$dest_dir"
        fi

        # Copy file
        cp "$local_file" "$dest_path"
        echo "Uploaded $(wc -l < "$local_file") lines to $dest_path"
        ;;

    *)
        echo "Error: Unknown action: $action"
        echo "Valid actions: download, upload"
        exit 1
        ;;
esac