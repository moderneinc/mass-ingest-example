#!/bin/bash

# Artifactory event publisher
# Uploads repos-lock.csv to Artifactory

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <source-file> <artifactory-url>"
    echo "  Example: $0 repos-lock.csv https://artifactory.example.com/artifactory/generic/events/repos-lock-123.csv"
    exit 1
fi

source_file="$1"
artifactory_url="$2"

# Check for required environment variables
if [ -z "${PUBLISH_USER:-}" ] && [ -z "${PUBLISH_TOKEN:-}" ]; then
    echo "Error: Either PUBLISH_USER (with PUBLISH_PASSWORD) or PUBLISH_TOKEN must be set"
    echo "  For basic auth: export PUBLISH_USER=username PUBLISH_PASSWORD=password"
    echo "  For token auth: export PUBLISH_TOKEN=your-token"
    exit 1
fi

# Add pending/ to URL if not already present
if [[ ! "$artifactory_url" =~ /pending/ ]] && [[ ! "$artifactory_url" =~ /processed/ ]]; then
    # Insert pending/ before the filename
    url_without_file="${artifactory_url%/*}"
    filename="${artifactory_url##*/}"
    artifactory_url="${url_without_file}/pending/${filename}"
fi

# Prepare authentication
if [ -n "${PUBLISH_TOKEN:-}" ]; then
    # Use token authentication
    auth_header="Authorization: Bearer ${PUBLISH_TOKEN}"
    echo "Using token authentication"
elif [ -n "${PUBLISH_USER:-}" ]; then
    # Use basic authentication
    if [ -z "${PUBLISH_PASSWORD:-}" ]; then
        echo "Error: PUBLISH_PASSWORD must be set when using PUBLISH_USER"
        exit 1
    fi
    auth_header="Authorization: Basic $(echo -n "${PUBLISH_USER}:${PUBLISH_PASSWORD}" | base64)"
    echo "Using basic authentication for user: ${PUBLISH_USER}"
else
    echo "Error: No authentication method configured"
    exit 1
fi

# Upload the file
echo "Uploading $source_file to $artifactory_url"

# Use curl to upload
http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$auth_header" \
    -T "$source_file" \
    "$artifactory_url")

if [ "$http_code" -eq 201 ] || [ "$http_code" -eq 200 ]; then
    echo "File successfully uploaded to: $artifactory_url"
    echo "  HTTP status: $http_code"

    # Try to get file info (optional verification)
    if info=$(curl -s -H "$auth_header" -X GET "$artifactory_url" -I 2>/dev/null); then
        size=$(echo "$info" | grep -i "content-length" | awk '{print $2}' | tr -d '\r')
        if [ -n "$size" ]; then
            echo "  Verified upload - Size: $size bytes"
        fi
    fi
else
    echo "Error: Failed to upload file to Artifactory"
    echo "  HTTP status code: $http_code"
    echo "  URL: $artifactory_url"

    # Try to get more error details
    error_response=$(curl -s -H "$auth_header" -T "$source_file" "$artifactory_url" 2>&1)
    if [ -n "$error_response" ]; then
        echo "  Response: $error_response"
    fi

    exit 1
fi