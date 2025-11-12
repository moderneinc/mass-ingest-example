#!/bin/bash

# S3 event consumer
# Lists, downloads, and archives repos-lock.csv events from S3

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <action> [arguments]"
    echo "  Actions:"
    echo "    list <s3-location>   - List pending events"
    echo "    download <s3-file> <dest-dir> - Download an event"
    echo "    archive <s3-file>    - Move event to processed folder"
    exit 1
fi

action="$1"
shift

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed or not in PATH"
    exit 1
fi

case "$action" in
    list)
        if [ $# -ne 1 ]; then
            echo "Usage: $0 list <s3-location>"
            exit 1
        fi

        s3_location="$1"

        # Add pending/ if not present
        if [[ ! "$s3_location" =~ /pending/?$ ]]; then
            if [[ "$s3_location" =~ /$ ]]; then
                s3_location="${s3_location}pending/"
            else
                s3_location="${s3_location}/pending/"
            fi
        fi

        # List all repos-lock-*.csv files in the pending directory
        aws s3 ls "$s3_location" 2>/dev/null | \
            grep -E "repos-lock-.*\.csv$" | \
            awk -v prefix="$s3_location" '{print prefix $NF}'
        ;;

    download)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 download <s3-file> <dest-dir>"
            exit 1
        fi

        s3_file="$1"
        dest_dir="$2"

        if [ ! -d "$dest_dir" ]; then
            mkdir -p "$dest_dir"
        fi

        # Download the file
        filename=$(basename "$s3_file")
        aws s3 cp "$s3_file" "$dest_dir/$filename" >/dev/null 2>&1

        # Return the filename
        echo "$filename"
        ;;

    archive)
        if [ $# -ne 1 ]; then
            echo "Usage: $0 archive <s3-file>"
            exit 1
        fi

        s3_file="$1"

        # Check if file exists
        if ! aws s3 ls "$s3_file" >/dev/null 2>&1; then
            echo "Warning: File already moved or deleted: $s3_file"
            exit 0
        fi

        # Parse S3 location to determine archive path
        # Convert pending/ to processed/YYYY-MM-DD/
        date_dir=$(date +%Y-%m-%d)
        archive_path=$(echo "$s3_file" | sed "s|/pending/|/processed/${date_dir}/|")

        # If no /pending/ in path, append /processed/
        if [ "$archive_path" = "$s3_file" ]; then
            dir_path=$(dirname "$s3_file")
            filename=$(basename "$s3_file")
            archive_path="${dir_path}/processed/${date_dir}/${filename}"
        fi

        # Move the file (copy then delete)
        if aws s3 cp "$s3_file" "$archive_path" >/dev/null 2>&1; then
            aws s3 rm "$s3_file" >/dev/null 2>&1
            echo "Archived to: $archive_path"
        else
            echo "Error: Failed to archive $s3_file"
            exit 1
        fi
        ;;

    *)
        echo "Error: Unknown action: $action"
        echo "Valid actions: list, download, archive"
        exit 1
        ;;
esac