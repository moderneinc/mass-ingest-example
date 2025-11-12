#!/bin/bash

# File system event consumer
# Lists, downloads, and archives repos-lock.csv events from local filesystem

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <action> [arguments]"
    echo "  Actions:"
    echo "    list <directory>     - List pending events"
    echo "    download <file> <dest-dir> - Download (copy) an event"
    echo "    archive <file>       - Move event to processed folder"
    exit 1
fi

action="$1"
shift

case "$action" in
    list)
        if [ $# -ne 1 ]; then
            echo "Usage: $0 list <directory>"
            exit 1
        fi

        dir="$1"

        # Check for pending subdirectory
        if [ -d "$dir/pending" ]; then
            pending_dir="$dir/pending"
        elif [ -d "$dir" ]; then
            # If no pending subdirectory, look in the directory itself
            pending_dir="$dir"
        else
            # No events found
            exit 0
        fi

        # List all CSV files in pending directory
        if [ -d "$pending_dir" ]; then
            find "$pending_dir" -maxdepth 1 -name "repos-lock-*.csv" -type f 2>/dev/null | sort
        fi
        ;;

    download)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 download <file> <dest-dir>"
            exit 1
        fi

        source_file="$1"
        dest_dir="$2"

        if [ ! -f "$source_file" ]; then
            echo "Error: Source file not found: $source_file"
            exit 1
        fi

        if [ ! -d "$dest_dir" ]; then
            mkdir -p "$dest_dir"
        fi

        # Copy the file to destination
        cp "$source_file" "$dest_dir/"

        # Return the path of the downloaded file
        basename "$source_file"
        ;;

    archive)
        if [ $# -ne 1 ]; then
            echo "Usage: $0 archive <file>"
            exit 1
        fi

        source_file="$1"

        if [ ! -f "$source_file" ]; then
            echo "Warning: File already moved or deleted: $source_file"
            exit 0
        fi

        # Determine archive directory
        dir=$(dirname "$source_file")
        parent_dir=$(dirname "$dir")
        filename=$(basename "$source_file")

        # Create processed directory with date
        date_dir=$(date +%Y-%m-%d)

        # Handle different directory structures
        if [[ "$dir" =~ /pending$ ]]; then
            # If file is in pending/, move to sibling processed/ directory
            archive_dir="${parent_dir}/processed/${date_dir}"
        else
            # Otherwise create processed subdirectory
            archive_dir="${dir}/processed/${date_dir}"
        fi

        # Create archive directory
        mkdir -p "$archive_dir"

        # Move the file
        mv "$source_file" "$archive_dir/$filename"

        echo "Archived to: $archive_dir/$filename"
        ;;

    *)
        echo "Error: Unknown action: $action"
        echo "Valid actions: list, download, archive"
        exit 1
        ;;
esac