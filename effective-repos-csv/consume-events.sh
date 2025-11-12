#!/bin/bash

# Batch consumer for repos-lock.csv events
# Downloads all pending events, merges them into effective repos.csv, and archives processed events

set -euo pipefail

# Check environment variables
if [ -z "${EVENT_LOCATION:-}" ]; then
    echo "Error: EVENT_LOCATION environment variable must be set"
    echo "  Example: EVENT_LOCATION=s3://bucket/events/"
    exit 1
fi

if [ -z "${EFFECTIVE_REPOS_LOCATION:-}" ]; then
    echo "Error: EFFECTIVE_REPOS_LOCATION environment variable must be set"
    echo "  Example: EFFECTIVE_REPOS_LOCATION=s3://bucket/config/effective-repos.csv"
    exit 1
fi

# Get the directory of this script
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create temporary working directory
work_dir=$(mktemp -d)
trap "rm -rf $work_dir" EXIT

echo "========================================="
echo "Batch Event Consumer"
echo "========================================="
echo "Event location: $EVENT_LOCATION"
echo "Effective repos location: $EFFECTIVE_REPOS_LOCATION"
echo "Working directory: $work_dir"
echo ""

# Determine which consumer to use based on EVENT_LOCATION format
if [[ "$EVENT_LOCATION" =~ ^s3:// ]]; then
    consumer="$script_dir/event-consumer-s3.sh"
    echo "Using S3 event consumer"
elif [[ "$EVENT_LOCATION" =~ ^git@ ]] || [[ "$EVENT_LOCATION" =~ \.git: ]]; then
    consumer="$script_dir/event-consumer-git.sh"
    echo "Using Git event consumer"
elif [[ "$EVENT_LOCATION" =~ ^https?:// ]]; then
    consumer="$script_dir/event-consumer-artifactory.sh"
    echo "Using Artifactory event consumer"
elif [[ "$EVENT_LOCATION" =~ ^/ ]] || [[ "$EVENT_LOCATION" =~ ^\./ ]]; then
    consumer="$script_dir/event-consumer-file.sh"
    echo "Using file system event consumer"
else
    echo "Error: Unknown event location format: $EVENT_LOCATION"
    exit 1
fi

# Determine which adapter to use for effective repos.csv
if [[ "$EFFECTIVE_REPOS_LOCATION" =~ ^s3:// ]]; then
    adapter="$script_dir/s3-adapter.sh"
    echo "Using S3 adapter for effective repos.csv"
elif [[ "$EFFECTIVE_REPOS_LOCATION" =~ ^git@ ]] || [[ "$EFFECTIVE_REPOS_LOCATION" =~ \.git: ]] || [[ "$EFFECTIVE_REPOS_LOCATION" =~ :.*\.csv$ ]]; then
    # Git URLs can be git@, have .git:, or use : as path separator for CSV files
    adapter="$script_dir/git-adapter.sh"
    echo "Using Git adapter for effective repos.csv"
elif [[ "$EFFECTIVE_REPOS_LOCATION" =~ ^https?:// ]]; then
    adapter="$script_dir/artifactory-adapter.sh"
    echo "Using Artifactory adapter for effective repos.csv"
elif [[ "$EFFECTIVE_REPOS_LOCATION" =~ ^/ ]] || [[ "$EFFECTIVE_REPOS_LOCATION" =~ ^\./ ]]; then
    adapter="$script_dir/file-adapter.sh"
    echo "Using file adapter for effective repos.csv"
else
    echo "Error: Unknown effective repos location format: $EFFECTIVE_REPOS_LOCATION"
    exit 1
fi

echo ""
echo "Step 1: Listing pending events..."
echo "-----------------------------------------"

# List all pending events
events=$("$consumer" list "$EVENT_LOCATION")

if [ -z "$events" ]; then
    echo "No pending events found. Nothing to process."
    exit 0
fi

# Count events
event_count=$(echo "$events" | wc -l)
echo "Found $event_count pending events"

echo ""
echo "Step 2: Downloading events..."
echo "-----------------------------------------"

# Download all events
mkdir -p "$work_dir/events"
for event in $events; do
    echo "  Downloading: $(basename "$event")"
    "$consumer" download "$event" "$work_dir/events/"
done

# List downloaded files
downloaded_files=$(ls -1 "$work_dir/events/"*.csv 2>/dev/null || true)
if [ -z "$downloaded_files" ]; then
    echo "Error: No CSV files downloaded"
    exit 1
fi

downloaded_count=$(echo "$downloaded_files" | wc -l)
echo "Downloaded $downloaded_count CSV files"

echo ""
echo "Step 3: Downloading current effective repos.csv..."
echo "-----------------------------------------"

# Download current effective repos.csv
if "$adapter" download "$EFFECTIVE_REPOS_LOCATION" "$work_dir/effective-repos.csv"; then
    echo "Downloaded current effective repos.csv"
    current_lines=$(wc -l < "$work_dir/effective-repos.csv")
    echo "  Current file has $current_lines lines"
else
    echo "No existing effective repos.csv found, will create new one"
    # Create empty file with headers
    echo "origin,path,branch,cloneUrl,changeset,publishUri" > "$work_dir/effective-repos.csv"
fi

# Backup the original
cp "$work_dir/effective-repos.csv" "$work_dir/effective-repos.backup.csv"

echo ""
echo "Step 4: Merging events into effective repos.csv..."
echo "-----------------------------------------"

# Merge all events
"$script_dir/merge-repos-csv.sh" \
    "$work_dir/effective-repos.csv" \
    "$work_dir/effective-repos-merged.csv" \
    $downloaded_files

# Check if merge produced output
if [ ! -f "$work_dir/effective-repos-merged.csv" ]; then
    echo "Error: Merge did not produce output file"
    exit 1
fi

merged_lines=$(wc -l < "$work_dir/effective-repos-merged.csv")
echo "Merged file has $merged_lines lines"

# Check if there are actual changes
if diff -q "$work_dir/effective-repos.csv" "$work_dir/effective-repos-merged.csv" > /dev/null; then
    echo "No changes detected after merge"
else
    echo "Changes detected, proceeding with update"
fi

echo ""
echo "Step 5: Uploading updated effective repos.csv..."
echo "-----------------------------------------"

# Upload the merged result
if "$adapter" upload "$work_dir/effective-repos-merged.csv" "$EFFECTIVE_REPOS_LOCATION"; then
    echo "Successfully uploaded updated effective repos.csv"
else
    echo "Error: Failed to upload updated effective repos.csv"
    exit 1
fi

echo ""
echo "Step 6: Archiving processed events..."
echo "-----------------------------------------"

# Archive processed events
archived_count=0
failed_count=0

for event in $events; do
    echo -n "  Archiving: $(basename "$event")..."
    if "$consumer" archive "$event"; then
        echo " done"
        ((archived_count++))
    else
        echo " failed"
        ((failed_count++))
    fi
done

echo ""
echo "========================================="
echo "Batch processing completed successfully"
echo "========================================="
echo "Events processed: $event_count"
echo "Events archived: $archived_count"
if [ "$failed_count" -gt 0 ]; then
    echo "Events failed to archive: $failed_count (will be reprocessed next run)"
fi
echo "Effective repos.csv updated: $merged_lines lines"
echo ""