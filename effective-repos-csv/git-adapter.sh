#!/bin/bash

# Git adapter for effective repos.csv
# Reads and writes effective repos.csv from/to Git repository

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <action> <git-location> [local-file]"
    echo "  Format: git@github.com:org/repo.git:path/to/effective-repos.csv"
    echo "  Actions:"
    echo "    download <git-location> <local-file> - Download effective repos.csv"
    echo "    upload <local-file> <git-location>   - Upload effective repos.csv"
    exit 1
fi

action="$1"
shift

# Check if git is available
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed or not in PATH"
    exit 1
fi

# Configure Git credentials if provided
if [ -n "${GIT_CREDENTIALS:-}" ]; then
    # First, clear any existing credential helpers to avoid conflicts
    git config --global --unset-all credential.helper 2>/dev/null || true

    # Set up credential helper to use store
    git config --global credential.helper store

    # Ensure .git-credentials exists with proper permissions
    touch ~/.git-credentials
    chmod 600 ~/.git-credentials

    # Extract host from credentials to check if it already exists
    if [[ "$GIT_CREDENTIALS" =~ ^https?://[^@]+@([^/]+) ]]; then
        host="${BASH_REMATCH[1]}"
        # Only add if this host isn't already in the file
        if ! grep -q "$host" ~/.git-credentials 2>/dev/null; then
            echo "$GIT_CREDENTIALS" >> ~/.git-credentials
        fi
    else
        # Just add it if we can't parse the host
        if ! grep -q "$GIT_CREDENTIALS" ~/.git-credentials 2>/dev/null; then
            echo "$GIT_CREDENTIALS" >> ~/.git-credentials
        fi
    fi

    # Disable interactive prompts
    export GIT_ASKPASS=/bin/echo
    export GIT_TERMINAL_PROMPT=0
fi

# Parse Git location format
parse_git_location() {
    local location="$1"
    if [[ "$location" =~ ^([^:]+:[^:]+\.git):(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$location" =~ ^([^:]+:[^:]+):(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}.git" "${BASH_REMATCH[2]}"
    else
        echo "Error: Invalid Git location format: $location" >&2
        echo "Expected: git@host:org/repo.git:path/to/file.csv" >&2
        return 1
    fi
}

case "$action" in
    download)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 download <git-location> <local-file>"
            exit 1
        fi

        git_location="$1"
        local_file="$2"
        read -r repo file_path <<< "$(parse_git_location "$git_location")"

        # Create temp directory for git operations
        tmp_dir=$(mktemp -d)
        trap "rm -rf $tmp_dir" EXIT

        # Clone repository (shallow for speed)
        echo "Cloning repository..."
        if ! git clone --quiet --depth 1 "$repo" "$tmp_dir/repo" 2>/dev/null; then
            git clone --quiet "$repo" "$tmp_dir/repo"
        fi

        # Check if file exists
        if [ ! -f "$tmp_dir/repo/$file_path" ]; then
            echo "File not found in repository: $file_path"
            exit 1
        fi

        # Copy file to local location
        cp "$tmp_dir/repo/$file_path" "$local_file"
        echo "Downloaded $(wc -l < "$local_file") lines from $git_location"
        ;;

    upload)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 upload <local-file> <git-location>"
            exit 1
        fi

        local_file="$1"
        git_location="$2"
        read -r repo file_path <<< "$(parse_git_location "$git_location")"

        if [ ! -f "$local_file" ]; then
            echo "Error: Local file not found: $local_file"
            exit 1
        fi

        # Create temp directory for git operations
        tmp_dir=$(mktemp -d)
        trap "rm -rf $tmp_dir" EXIT

        # Clone repository (not shallow, need history for commits)
        echo "Cloning repository for update..."
        git clone --quiet "$repo" "$tmp_dir/repo"
        cd "$tmp_dir/repo"

        # Configure git user if needed
        if ! git config user.email > /dev/null 2>&1; then
            git config user.email "mass-ingest@moderne.io"
        fi
        if ! git config user.name > /dev/null 2>&1; then
            git config user.name "Mass Ingest Updater"
        fi

        # Create backup if file exists
        if [ -f "$file_path" ]; then
            backup_path="${file_path}.$(date +%Y%m%d_%H%M%S).bak"
            cp "$file_path" "$backup_path"
            git add "$backup_path"
            echo "Created backup: $backup_path"
        fi

        # Ensure directory exists
        file_dir=$(dirname "$file_path")
        if [ "$file_dir" != "." ] && [ ! -d "$file_dir" ]; then
            mkdir -p "$file_dir"
        fi

        # Copy new file
        cp "$local_file" "$file_path"
        git add "$file_path"

        # Check if there are changes
        if git diff --cached --quiet; then
            echo "No changes detected in effective repos.csv"
        else
            # Get statistics for commit message
            lines=$(wc -l < "$local_file")

            # Commit with descriptive message
            commit_message="Update effective repos.csv

Updated by mass-ingest batch consumer
Lines: $lines
Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Hostname: $(hostname -s 2>/dev/null || echo "unknown")"

            git commit -m "$commit_message"

            # Push to remote
            echo "Pushing to remote repository..."
            if git push origin HEAD; then
                echo "Uploaded $(wc -l < "$local_file") lines to $git_location"
                commit_hash=$(git rev-parse HEAD)
                echo "Commit: $commit_hash"
            else
                echo "Error: Failed to push to remote repository"
                exit 1
            fi
        fi
        ;;

    *)
        echo "Error: Unknown action: $action"
        echo "Valid actions: download, upload"
        exit 1
        ;;
esac