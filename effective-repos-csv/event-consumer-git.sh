#!/bin/bash

# Git event consumer
# Lists, downloads, and archives repos-lock.csv events from Git repository

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <action> [arguments]"
    echo "  Actions:"
    echo "    list <git-location>   - List pending events"
    echo "    download <file-path> <dest-dir> - Download an event"
    echo "    archive <file-path>   - Move event to processed folder"
    exit 1
fi

action="$1"
shift

# Check if git is available
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed or not in PATH"
    exit 1
fi

# Parse Git location format: git@github.com:org/repo.git:path
parse_git_location() {
    local location="$1"
    if [[ "$location" =~ ^([^:]+:[^:]+\.git):(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$location" =~ ^([^:]+:[^:]+):(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}.git" "${BASH_REMATCH[2]}"
    else
        echo "Error: Invalid Git location format: $location" >&2
        return 1
    fi
}

case "$action" in
    list)
        if [ $# -ne 1 ]; then
            echo "Usage: $0 list <git-location>"
            exit 1
        fi

        location="$1"
        read -r repo path <<< "$(parse_git_location "$location")"

        # Add pending/ if not in path
        if [[ ! "$path" =~ pending/?$ ]] && [[ ! "$path" =~ pending/ ]]; then
            if [[ "$path" =~ /$ ]]; then
                path="${path}pending/"
            else
                path="${path}/pending/"
            fi
        fi

        # Create temp directory for git operations
        tmp_dir=$(mktemp -d)
        trap "rm -rf $tmp_dir" EXIT

        # Clone repository (shallow)
        git clone --quiet --depth 1 "$repo" "$tmp_dir/repo" 2>/dev/null || \
            git clone --quiet "$repo" "$tmp_dir/repo"

        # List files in pending directory
        if [ -d "$tmp_dir/repo/$path" ]; then
            find "$tmp_dir/repo/$path" -maxdepth 1 -name "repos-lock-*.csv" -type f | \
                while read -r file; do
                    # Return as git location format
                    basename_file=$(basename "$file")
                    echo "${repo}:${path}${basename_file}"
                done
        fi
        ;;

    download)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 download <git-file-path> <dest-dir>"
            exit 1
        fi

        file_location="$1"
        dest_dir="$2"
        read -r repo file_path <<< "$(parse_git_location "$file_location")"

        if [ ! -d "$dest_dir" ]; then
            mkdir -p "$dest_dir"
        fi

        # Create temp directory for git operations
        tmp_dir=$(mktemp -d)
        trap "rm -rf $tmp_dir" EXIT

        # Clone repository
        git clone --quiet --depth 1 "$repo" "$tmp_dir/repo" 2>/dev/null || \
            git clone --quiet "$repo" "$tmp_dir/repo"

        # Check if file exists
        if [ ! -f "$tmp_dir/repo/$file_path" ]; then
            echo "Error: File not found in repository: $file_path"
            exit 1
        fi

        # Copy file to destination
        filename=$(basename "$file_path")
        cp "$tmp_dir/repo/$file_path" "$dest_dir/$filename"

        echo "$filename"
        ;;

    archive)
        if [ $# -ne 1 ]; then
            echo "Usage: $0 archive <git-file-path>"
            exit 1
        fi

        file_location="$1"
        read -r repo file_path <<< "$(parse_git_location "$file_location")"

        # Create temp directory for git operations
        tmp_dir=$(mktemp -d)
        trap "rm -rf $tmp_dir" EXIT

        # Clone repository (not shallow, need history for commits)
        echo "Cloning repository for archiving..."
        git clone --quiet "$repo" "$tmp_dir/repo"
        cd "$tmp_dir/repo"

        # Configure git user if needed
        if ! git config user.email > /dev/null 2>&1; then
            git config user.email "mass-ingest@moderne.io"
        fi
        if ! git config user.name > /dev/null 2>&1; then
            git config user.name "Mass Ingest Consumer"
        fi

        # Check if file exists
        if [ ! -f "$file_path" ]; then
            echo "Warning: File already moved or deleted: $file_path"
            exit 0
        fi

        # Determine archive path
        date_dir=$(date +%Y-%m-%d)
        dir_path=$(dirname "$file_path")
        filename=$(basename "$file_path")

        # Convert pending/ to processed/
        if [[ "$dir_path" =~ pending/?$ ]]; then
            archive_dir=$(echo "$dir_path" | sed "s|pending/*$|processed/${date_dir}|")
        elif [[ "$dir_path" =~ /pending/ ]]; then
            archive_dir=$(echo "$dir_path" | sed "s|/pending/|/processed/${date_dir}/|")
        else
            archive_dir="${dir_path}/processed/${date_dir}"
        fi

        # Create archive directory and move file
        mkdir -p "$archive_dir"
        git mv "$file_path" "$archive_dir/$filename"

        # Commit and push
        commit_message="Archive processed event: $filename

Moved from: $file_path
Archived to: $archive_dir/$filename
Processed at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"

        git add -A
        git commit -m "$commit_message"

        if git push origin HEAD; then
            echo "Archived to: ${repo}:${archive_dir}/$filename"
        else
            echo "Error: Failed to push archive changes"
            exit 1
        fi
        ;;

    *)
        echo "Error: Unknown action: $action"
        echo "Valid actions: list, download, archive"
        exit 1
        ;;
esac