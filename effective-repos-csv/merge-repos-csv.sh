#!/bin/bash

# CSV merge logic
# Merges one or more repos-lock.csv files into an effective repos.csv
# Matches on origin + path + branch, updates changeset and publishUri

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: $0 <effective-repos.csv> <output.csv> <repos-lock1.csv> [repos-lock2.csv ...]"
    echo "  effective-repos.csv: Current effective repos.csv (can be non-existent for new file)"
    echo "  output.csv: Where to write the merged result"
    echo "  repos-lock*.csv: One or more repos-lock.csv files to merge"
    exit 1
fi

effective_csv="$1"
output_csv="$2"
shift 2
# Remaining arguments are repos-lock files

# Create temporary directory for processing
tmp_dir=$(mktemp -d)
trap "rm -rf $tmp_dir" EXIT

# Function to normalize CSV headers (remove quotes, trim spaces)
normalize_header() {
    echo "$1" | sed 's/"//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Function to extract column index by name
get_column_index() {
    local header="$1"
    local column_name="$2"
    echo "$header" | tr ',' '\n' | nl -v 0 | grep -i "^[[:space:]]*[0-9]*[[:space:]]*${column_name}$" | awk '{print $1}' | head -1
}

# If effective repos.csv doesn't exist, create empty one with minimal headers
if [ ! -f "$effective_csv" ]; then
    echo "Note: Effective repos.csv not found, will create new file"
    echo "origin,path,branch,cloneUrl,changeset,publishUri" > "$tmp_dir/effective.csv"
    effective_csv="$tmp_dir/effective.csv"
fi

# Process and combine all repos-lock files into a single updates file
echo "Processing repos-lock files..."
> "$tmp_dir/all_updates.csv"
first_file=true

for repos_lock in "$@"; do
    if [ ! -f "$repos_lock" ]; then
        echo "Warning: repos-lock file not found: $repos_lock"
        continue
    fi

    echo "  Processing: $repos_lock"

    # Skip files that are empty or only have headers
    line_count=$(wc -l < "$repos_lock")
    if [ "$line_count" -le 1 ]; then
        echo "    Skipping empty file"
        continue
    fi

    if $first_file; then
        # Include header from first file (skip comment lines)
        grep -v '^#' "$repos_lock" >> "$tmp_dir/all_updates.csv"
        first_file=false
    else
        # Skip header and comment lines from subsequent files
        grep -v '^#' "$repos_lock" | tail -n +2 >> "$tmp_dir/all_updates.csv"
    fi
done

# If no valid updates were found, just copy the effective CSV
if [ ! -s "$tmp_dir/all_updates.csv" ] || [ "$(wc -l < "$tmp_dir/all_updates.csv")" -le 1 ]; then
    echo "No updates to apply, copying existing effective repos.csv"
    cp "$effective_csv" "$output_csv"
    exit 0
fi

# Now merge using awk
echo "Merging updates into effective repos.csv..."

awk -F',' -v OFS=',' '
BEGIN {
    # Track which rows have been updated
    # Key format: origin|path|branch
}

# Process the updates file (read it first)
NR == FNR {
    # Skip comment lines
    if (/^#/) {
        next
    }

    if (!header_parsed) {
        # Parse header to find column indices
        for (i = 1; i <= NF; i++) {
            gsub(/"/, "", $i)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            update_cols[$i] = i
        }
        header_parsed = 1
        next
    }

    # Extract key fields
    origin = $update_cols["origin"]
    path = $update_cols["path"]
    branch = (update_cols["branch"] ? $update_cols["branch"] : "")
    changeset = (update_cols["changeset"] ? $update_cols["changeset"] : "")
    publishUri = (update_cols["publishUri"] ? $update_cols["publishUri"] : "")

    # Clean up values
    gsub(/"/, "", origin)
    gsub(/"/, "", path)
    gsub(/"/, "", branch)
    gsub(/"/, "", changeset)
    gsub(/"/, "", publishUri)

    # Create key
    key = origin "|" path "|" branch

    # Store ALL entries, not just those with non-empty changeset and publishUri
    # Store the entire row for potential new entries
    updates[key] = $0
    update_changeset[key] = changeset
    update_publishUri[key] = publishUri
    has_changeset[key] = (changeset != "") ? 1 : 0
    has_publishUri[key] = (publishUri != "") ? 1 : 0
    seen[key] = 1
    next
}

# Process the effective repos.csv file
FNR == 1 {
    # Parse header to find column indices
    for (i = 1; i <= NF; i++) {
        gsub(/"/, "", $i)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        effective_cols[$i] = i
    }
    # Print header (might need to add columns if they dont exist)
    print $0
    next
}

{
    # Extract key fields
    origin = $effective_cols["origin"]
    path = $effective_cols["path"]
    branch = (effective_cols["branch"] ? $effective_cols["branch"] : "")

    # Clean up values
    gsub(/"/, "", origin)
    gsub(/"/, "", path)
    gsub(/"/, "", branch)

    # Create key
    key = origin "|" path "|" branch

    # Check if we have an update for this row
    if (key in update_changeset) {
        # Update changeset only if the new value is non-empty
        if (effective_cols["changeset"] && has_changeset[key]) {
            $effective_cols["changeset"] = update_changeset[key]
        }
        # Update publishUri only if the new value is non-empty
        if (effective_cols["publishUri"] && has_publishUri[key]) {
            $effective_cols["publishUri"] = update_publishUri[key]
        }
        processed[key] = 1
    }

    print $0
}

END {
    # Add any new entries that werent in effective repos.csv
    for (key in updates) {
        if (!(key in processed)) {
            # This is a new entry - print the full row from updates
            print updates[key]
        }
    }
}
' "$tmp_dir/all_updates.csv" "$effective_csv" > "$output_csv"

# Report statistics
effective_lines=$(wc -l < "$effective_csv")
output_lines=$(wc -l < "$output_csv")
updates_lines=$(wc -l < "$tmp_dir/all_updates.csv")

echo "Merge completed:"
echo "  Effective repos.csv: $effective_lines lines"
echo "  Updates processed: $updates_lines lines"
echo "  Output file: $output_lines lines"
echo "  Output written to: $output_csv"