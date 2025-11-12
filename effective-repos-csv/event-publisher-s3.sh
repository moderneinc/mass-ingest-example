#!/bin/bash

# S3 event publisher
# Uploads repos-lock.csv to S3

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <source-file> <s3-destination>"
    echo "  Example: $0 repos-lock.csv s3://bucket/events/repos-lock-123.csv"
    exit 1
fi

source_file="$1"
s3_destination="$2"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed or not in PATH"
    echo "Please install AWS CLI: https://aws.amazon.com/cli/"
    exit 1
fi

# Check AWS credentials are configured
if ! aws sts get-caller-identity &> /dev/null; then
    echo "Error: AWS credentials not configured or expired"
    echo "Please configure AWS credentials using 'aws configure' or environment variables"
    exit 1
fi

# Extract bucket and path for validation
if [[ "$s3_destination" =~ ^s3://([^/]+)/(.*)$ ]]; then
    bucket="${BASH_REMATCH[1]}"
    s3_path="${BASH_REMATCH[2]}"

    # Add pending/ to path if not already present
    if [[ ! "$s3_path" =~ pending/ ]] && [[ ! "$s3_path" =~ processed/ ]]; then
        # Insert pending/ before the filename
        s3_dir=$(dirname "$s3_path")
        s3_file=$(basename "$s3_path")
        if [ "$s3_dir" = "." ]; then
            s3_path="pending/$s3_file"
        else
            s3_path="$s3_dir/pending/$s3_file"
        fi
        s3_destination="s3://$bucket/$s3_path"
    fi
else
    echo "Error: Invalid S3 destination format: $s3_destination"
    echo "Expected format: s3://bucket/path/to/file.csv"
    exit 1
fi

# Upload the file
echo "Uploading $source_file to $s3_destination"
if aws s3 cp "$source_file" "$s3_destination"; then
    echo "File successfully uploaded to: $s3_destination"

    # Verify upload by checking if file exists
    if aws s3 ls "$s3_destination" &> /dev/null; then
        # Get file size
        size=$(aws s3 ls "$s3_destination" | awk '{print $3}')
        echo "  Verified upload - Size: $size bytes"
    else
        echo "Warning: Upload reported success but file not found in S3"
    fi
else
    echo "Error: Failed to upload file to S3"
    exit 1
fi