#!/bin/bash

# Artifactory event consumer
# Lists, downloads, and archives repos-lock.csv events from Artifactory

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <action> [arguments]"
    echo "  Actions:"
    echo "    list <artifactory-url>   - List pending events"
    echo "    download <file-url> <dest-dir> - Download an event"
    echo "    archive <file-url>        - Move event to processed folder"
    exit 1
fi

action="$1"
shift

# Check for authentication
if [ -z "${PUBLISH_USER:-}" ] && [ -z "${PUBLISH_TOKEN:-}" ]; then
    echo "Error: Either PUBLISH_USER or PUBLISH_TOKEN must be set"
    exit 1
fi

# Prepare authentication
if [ -n "${PUBLISH_TOKEN:-}" ]; then
    auth_header="Authorization: Bearer ${PUBLISH_TOKEN}"
elif [ -n "${PUBLISH_USER:-}" ]; then
    if [ -z "${PUBLISH_PASSWORD:-}" ]; then
        echo "Error: PUBLISH_PASSWORD must be set when using PUBLISH_USER"
        exit 1
    fi
    auth_header="Authorization: Basic $(echo -n "${PUBLISH_USER}:${PUBLISH_PASSWORD}" | base64)"
fi

case "$action" in
    list)
        if [ $# -ne 1 ]; then
            echo "Usage: $0 list <artifactory-url>"
            exit 1
        fi

        base_url="$1"

        # Add pending/ if not present
        if [[ ! "$base_url" =~ /pending/?$ ]]; then
            if [[ "$base_url" =~ /$ ]]; then
                base_url="${base_url}pending/"
            else
                base_url="${base_url}/pending/"
            fi
        fi

        # Use Artifactory API to list files
        # Try to get directory listing
        response=$(curl -s -H "$auth_header" "${base_url}")

        # Parse response - Artifactory returns HTML or JSON depending on configuration
        # Try JSON first
        if echo "$response" | grep -q '"uri"'; then
            # JSON response from API
            echo "$response" | \
                grep -oE '"uri"[[:space:]]*:[[:space:]]*"[^"]*repos-lock-[^"]*\.csv"' | \
                sed 's/.*"\(repos-lock-.*\.csv\)".*/\1/' | \
                while read -r file; do
                    echo "${base_url}${file}"
                done
        else
            # HTML response - parse links
            echo "$response" | \
                grep -oE 'href="[^"]*repos-lock-[^"]*\.csv"' | \
                sed 's/href="\(.*\)"/\1/' | \
                while read -r file; do
                    # Handle relative vs absolute URLs
                    if [[ "$file" =~ ^https?:// ]]; then
                        echo "$file"
                    else
                        echo "${base_url}${file}"
                    fi
                done
        fi
        ;;

    download)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 download <file-url> <dest-dir>"
            exit 1
        fi

        file_url="$1"
        dest_dir="$2"

        if [ ! -d "$dest_dir" ]; then
            mkdir -p "$dest_dir"
        fi

        # Download the file
        filename=$(basename "$file_url")
        if curl -s -f -H "$auth_header" "$file_url" -o "$dest_dir/$filename"; then
            echo "$filename"
        else
            echo "Error: Failed to download $file_url"
            exit 1
        fi
        ;;

    archive)
        if [ $# -ne 1 ]; then
            echo "Usage: $0 archive <file-url>"
            exit 1
        fi

        file_url="$1"

        # Check if file exists
        if ! curl -s -f -H "$auth_header" --head "$file_url" >/dev/null 2>&1; then
            echo "Warning: File already moved or deleted: $file_url"
            exit 0
        fi

        # Determine archive URL
        # Convert pending/ to processed/YYYY-MM-DD/
        date_dir=$(date +%Y-%m-%d)
        archive_url=$(echo "$file_url" | sed "s|/pending/|/processed/${date_dir}/|")

        # If no /pending/ in path, append /processed/
        if [ "$archive_url" = "$file_url" ]; then
            dir_url="${file_url%/*}"
            filename="${file_url##*/}"
            archive_url="${dir_url}/processed/${date_dir}/${filename}"
        fi

        # Download the file to temp location
        tmp_file=$(mktemp)
        if ! curl -s -f -H "$auth_header" "$file_url" -o "$tmp_file"; then
            echo "Error: Failed to download file for archiving"
            rm -f "$tmp_file"
            exit 1
        fi

        # Upload to archive location
        if curl -s -f -H "$auth_header" -T "$tmp_file" "$archive_url"; then
            # Delete original
            curl -s -H "$auth_header" -X DELETE "$file_url"
            echo "Archived to: $archive_url"
            rm -f "$tmp_file"
        else
            echo "Error: Failed to archive to $archive_url"
            rm -f "$tmp_file"
            exit 1
        fi
        ;;

    *)
        echo "Error: Unknown action: $action"
        echo "Valid actions: list, download, archive"
        exit 1
        ;;
esac