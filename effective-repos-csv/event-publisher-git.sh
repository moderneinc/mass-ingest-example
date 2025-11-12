#!/bin/bash

# Git event publisher
# Commits and pushes repos-lock.csv to a Git repository

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <source-file> <git-destination>"
    echo "  Format: git@github.com:org/repo.git:path/to/file.csv"
    echo "  Example: $0 repos-lock.csv git@github.com:myorg/events.git:pending/repos-lock-123.csv"
    exit 1
fi

source_file="$1"
destination="$2"

# Parse the destination format
# Expected: git@github.com:org/repo.git:path/to/file.csv
if [[ "$destination" =~ ^([^:]+:[^:]+\.git):(.+)$ ]]; then
    repo="${BASH_REMATCH[1]}"
    file_path="${BASH_REMATCH[2]}"
elif [[ "$destination" =~ ^([^:]+:[^:]+):(.+)$ ]]; then
    # Also support without .git extension
    repo="${BASH_REMATCH[1]}.git"
    file_path="${BASH_REMATCH[2]}"
else
    echo "Error: Invalid Git destination format: $destination"
    echo "Expected format: git@github.com:org/repo.git:path/to/file.csv"
    exit 1
fi

# Add pending/ to path if not already present
if [[ ! "$file_path" =~ pending/ ]] && [[ ! "$file_path" =~ processed/ ]]; then
    dir_path=$(dirname "$file_path")
    filename=$(basename "$file_path")
    if [ "$dir_path" = "." ]; then
        file_path="pending/$filename"
    else
        file_path="$dir_path/pending/$filename"
    fi
fi

# Check if git is available
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed or not in PATH"
    exit 1
fi

# Create temporary directory for git operations
tmp_dir=$(mktemp -d)
trap "rm -rf $tmp_dir" EXIT

echo "Cloning repository: $repo"
echo "Target file path: $file_path"

# Configure git credentials if provided
if [ -n "${GIT_CREDENTIALS:-}" ]; then
    echo "Configuring git credentials"
    git config --global credential.helper store
    echo "$GIT_CREDENTIALS" > ~/.git-credentials
fi

# Try to clone the repository (shallow clone for speed)
if ! git clone --depth 1 "$repo" "$tmp_dir/repo" 2>/dev/null; then
    echo "Shallow clone failed, trying full clone..."
    if ! git clone "$repo" "$tmp_dir/repo"; then
        echo "Error: Failed to clone repository: $repo"
        echo "Please ensure:"
        echo "  - The repository exists and is accessible"
        echo "  - You have proper SSH keys or credentials configured"
        exit 1
    fi
fi

cd "$tmp_dir/repo"

# Create directory structure if needed
file_dir=$(dirname "$file_path")
if [ "$file_dir" != "." ]; then
    mkdir -p "$file_dir"
fi

# Copy the file
cp "$source_file" "$file_path"

# Configure git user if not already configured
if ! git config user.email > /dev/null 2>&1; then
    git config user.email "mass-ingest@moderne.io"
fi
if ! git config user.name > /dev/null 2>&1; then
    git config user.name "Mass Ingest"
fi

# Add and commit the file
git add "$file_path"

# Check if there are changes to commit
if git diff --cached --quiet; then
    echo "Warning: No changes detected, file may already exist with same content"
    echo "File path: $file_path"
else
    # Commit with descriptive message
    commit_message="Add repos-lock event: $(basename "$file_path")

    Added by mass-ingest event publisher
    Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
    Hostname: $(hostname -s 2>/dev/null || echo "unknown")"

    git commit -m "$commit_message"

    # Push to remote
    echo "Pushing to remote repository..."
    if git push origin HEAD; then
        echo "Successfully pushed event to: $repo"
        echo "  File: $file_path"

        # Show commit hash for reference
        commit_hash=$(git rev-parse HEAD)
        echo "  Commit: $commit_hash"
    else
        echo "Error: Failed to push to remote repository"
        echo "Please check your permissions and network connectivity"
        exit 1
    fi
fi