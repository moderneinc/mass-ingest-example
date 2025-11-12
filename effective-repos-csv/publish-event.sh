#!/bin/bash

# Main event publisher script
# Publishes a repos-lock.csv file to the configured event storage location

set -euo pipefail

# Check arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <repos-lock-file> <event-location>"
    echo "  repos-lock-file: Path to the repos-lock.csv file to publish"
    echo "  event-location: Where to publish the event (S3, Artifactory, Git, or file path)"
    exit 1
fi

repos_lock_file="$1"
location="$2"

# Verify repos-lock file exists
if [ ! -f "$repos_lock_file" ]; then
    echo "Error: repos-lock.csv file not found: $repos_lock_file"
    exit 1
fi

# Generate unique event name
hostname=$(hostname -s 2>/dev/null || echo "unknown")
timestamp=$(date +%s)
event_name="repos-lock-${hostname}-${timestamp}-$$.csv"

# Get the directory of this script
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Publishing event: $event_name to $location"

# Determine which publisher to use based on URL format
if [[ "$location" =~ ^s3:// ]]; then
    echo "Using S3 publisher"
    "$script_dir/event-publisher-s3.sh" "$repos_lock_file" "$location/$event_name"
elif [[ "$location" =~ ^git@ ]] || [[ "$location" =~ ^https://github.com/ ]] || [[ "$location" =~ \.git: ]]; then
    echo "Using Git publisher"
    "$script_dir/event-publisher-git.sh" "$repos_lock_file" "$location/$event_name"
elif [[ "$location" =~ ^https?:// ]]; then
    echo "Using Artifactory publisher"
    "$script_dir/event-publisher-artifactory.sh" "$repos_lock_file" "$location/$event_name"
elif [[ "$location" =~ ^/ ]] || [[ "$location" =~ ^\./ ]]; then
    echo "Using file system publisher"
    "$script_dir/event-publisher-file.sh" "$repos_lock_file" "$location/$event_name"
else
    echo "Error: Unknown storage location format: $location"
    echo "Supported formats:"
    echo "  S3: s3://bucket/path/"
    echo "  Artifactory: https://artifactory.example.com/path/"
    echo "  Git: git@github.com:org/repo.git:path/"
    echo "  File: /absolute/path/ or ./relative/path/"
    exit 1
fi

echo "Event published successfully: $event_name"