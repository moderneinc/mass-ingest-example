#!/bin/bash

# Artifactory adapter for effective repos.csv
# Reads and writes effective repos.csv from/to Artifactory

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <action> <artifactory-url> [local-file]"
    echo "  Actions:"
    echo "    download <artifactory-url> <local-file> - Download effective repos.csv"
    echo "    upload <local-file> <artifactory-url>   - Upload effective repos.csv"
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
    download)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 download <artifactory-url> <local-file>"
            exit 1
        fi

        artifactory_url="$1"
        local_file="$2"

        # Download file
        http_code=$(curl -s -o "$local_file" -w "%{http_code}" \
            -H "$auth_header" \
            "$artifactory_url")

        if [ "$http_code" -eq 200 ]; then
            echo "Downloaded $(wc -l < "$local_file") lines from $artifactory_url"
        elif [ "$http_code" -eq 404 ]; then
            echo "File not found: $artifactory_url"
            rm -f "$local_file"
            exit 1
        else
            echo "Error: Failed to download from Artifactory (HTTP $http_code)"
            rm -f "$local_file"
            exit 1
        fi
        ;;

    upload)
        if [ $# -ne 2 ]; then
            echo "Usage: $0 upload <local-file> <artifactory-url>"
            exit 1
        fi

        local_file="$1"
        artifactory_url="$2"

        if [ ! -f "$local_file" ]; then
            echo "Error: Local file not found: $local_file"
            exit 1
        fi

        # Check if file exists and create backup
        check_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "$auth_header" \
            --head "$artifactory_url")

        if [ "$check_code" -eq 200 ]; then
            # File exists, create backup
            backup_url="${artifactory_url}.$(date +%Y%m%d_%H%M%S).bak"
            echo "Creating backup at: $backup_url"

            # Download existing file
            tmp_backup=$(mktemp)
            curl -s -H "$auth_header" "$artifactory_url" -o "$tmp_backup"

            # Upload as backup
            curl -s -H "$auth_header" -T "$tmp_backup" "$backup_url"
            rm -f "$tmp_backup"
        fi

        # Upload file
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "$auth_header" \
            -T "$local_file" \
            "$artifactory_url")

        if [ "$http_code" -eq 201 ] || [ "$http_code" -eq 200 ]; then
            echo "Uploaded $(wc -l < "$local_file") lines to $artifactory_url"
        else
            echo "Error: Failed to upload to Artifactory (HTTP $http_code)"
            exit 1
        fi
        ;;

    *)
        echo "Error: Unknown action: $action"
        echo "Valid actions: download, upload"
        exit 1
        ;;
esac