#!/bin/bash

# S3 adapter for effective repos.csv
# Reads and writes effective repos.csv from/to S3

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <action> <s3-location> [local-file]"
    echo "  Actions:"
    echo "    download <s3-location> <local-file> - Download effective repos.csv"
    echo "    upload <local-file> <s3-location>   - Upload effective repos.csv"
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
    download)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 download <s3-location> <local-file>"
            exit 1
        fi

        s3_location="$1"
        local_file="$2"

        # Check if file exists in S3
        if ! aws s3 ls "$s3_location" >/dev/null 2>&1; then
            echo "File not found in S3: $s3_location"
            exit 1
        fi

        # Download file
        aws s3 cp "$s3_location" "$local_file" >/dev/null 2>&1
        echo "Downloaded $(wc -l < "$local_file") lines from $s3_location"
        ;;

    upload)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 upload <local-file> <s3-location>"
            exit 1
        fi

        local_file="$1"
        s3_location="$2"

        if [ ! -f "$local_file" ]; then
            echo "Error: Local file not found: $local_file"
            exit 1
        fi

        # Create backup if file exists in S3
        if aws s3 ls "$s3_location" >/dev/null 2>&1; then
            backup_location="${s3_location}.$(date +%Y%m%d_%H%M%S).bak"
            aws s3 cp "$s3_location" "$backup_location" >/dev/null 2>&1
            echo "Created backup: $backup_location"
        fi

        # Upload file
        aws s3 cp "$local_file" "$s3_location" >/dev/null 2>&1

        # Verify upload
        if aws s3 ls "$s3_location" >/dev/null 2>&1; then
            echo "Uploaded $(wc -l < "$local_file") lines to $s3_location"
        else
            echo "Error: Failed to verify upload to $s3_location"
            exit 1
        fi
        ;;

    *)
        echo "Error: Unknown action: $action"
        echo "Valid actions: download, upload"
        exit 1
        ;;
esac