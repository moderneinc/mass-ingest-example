#!/bin/bash

# Show help function
usage() {
    echo "Usage: azure-devops.sh -o <organization> -p <project> [-s] [-t <token>]"
    echo ""
    echo "Required:"
    echo "  -o  Azure DevOps Organization"
    echo "  -p  Azure DevOps Project"
    echo "Optional:"
    echo "  -s  Use SSH URLs instead of HTTPS URLs (default: HTTPS)"
    echo "  -t  Personal Access Token (PAT) - if not provided, will use az CLI"
}

# Parse command-line arguments
while getopts ":o:p:st:" opt; do
  case ${opt} in
    o) ORGANIZATION=$OPTARG;;
    p) PROJECT=$OPTARG;;
    s) USE_SSH=true;;
    t) PAT=$OPTARG;;
    *) usage;;
  esac
done
shift $((OPTIND -1))

# Validate required parameters
if [[ -z "$ORGANIZATION" ]]; then
    echo "Error: Organization is required (-o)" 1>&2
    usage
    exit 1
fi

if [[ -z "$PROJECT" ]]; then
    echo "Error: Project is required (-p)" 1>&2
    usage
    exit 1
fi

# Output CSV header
echo "cloneUrl,branch,origin,path"

# Function to process repository data
process_repo() {
    local ssh_url=$1
    local default_branch=$2
    local remote_url=$3

    # Handle cases where defaultBranch might be empty or null
    if [[ -z "$default_branch" || "$default_branch" == "null" ]]; then
        branch="main"
    else
        # Remove refs/heads/ prefix if present
        branch="${default_branch#refs/heads/}"
    fi

    # Determine which URL to use
    if [[ "$USE_SSH" == "true" ]]; then
        clone_url="$ssh_url"
        # SSH URL format: ssh://git@ssh.dev.azure.com/v3/organization/project/repo
        # Extract origin: ssh.dev.azure.com
        origin=$(echo "$clone_url" | sed -E 's|^ssh://git@([^/]+)/.*|\1|')
        # Extract path: organization/project/repo (remove /v3/)
        path=$(echo "$clone_url" | sed -E 's|^ssh://git@[^/]+/v3/(.*)|\1|')
    else
        clone_url="$remote_url"
        # HTTPS URL format: https://dev.azure.com/organization/project/_git/repo
        # Extract origin: dev.azure.com
        origin=$(echo "$clone_url" | sed -E 's|^https://([^/]+)/.*|\1|')
        # Extract path: organization/project/repo (remove /_git/)
        path=$(echo "$clone_url" | sed -E 's|^https://[^/]+/([^/]+/[^/]+)/_git/(.*)|\1/\2|')
    fi

    # Output in CSV format with proper quoting
    echo "\"$clone_url\",\"$branch\",\"$origin\",\"$path\""
}

# Use API mode if PAT is provided, otherwise use az CLI
if [ -n "$PAT" ]; then
    # API mode with PAT
    api_url="https://dev.azure.com/$ORGANIZATION/$PROJECT/_apis/git/repositories?api-version=7.0"

    response=$(curl --silent --max-time 10 --user ":$PAT" "$api_url")

    # Check if curl failed
    if [ $? -ne 0 ]; then
        echo "Error: Failed to fetch repositories from Azure DevOps API." 1>&2
        exit 1
    fi

    # Validate JSON response
    if ! echo "$response" | jq -e '.' >/dev/null 2>&1; then
        echo "Error: Invalid JSON response from Azure DevOps API." 1>&2
        echo "Response saved to: azure-fetch-error.html" 1>&2
        echo "$response" > azure-fetch-error.html
        exit 1
    fi

    # Check if response contains an error
    if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        error_msg=$(echo "$response" | jq -r '.message // "Unknown error"')
        echo "Error: Azure DevOps API error - $error_msg" 1>&2
        exit 1
    fi

    # Process repositories
    echo "$response" | jq -r '.value[] |
        .sshUrl as $ssh_url |
        .defaultBranch as $default_branch |
        .webUrl as $web_url |
        ($web_url | sub("/_git/.*"; "/_git/") + .name) as $remote_url |
        "\($ssh_url)\t\($default_branch)\t\($remote_url)"' | while IFS=$'\t' read -r ssh_url default_branch remote_url; do
        process_repo "$ssh_url" "$default_branch" "$remote_url"
    done
else
    # CLI mode - check if az is available
    if ! command -v az &> /dev/null; then
        echo "Error: Azure CLI (az) is not installed and no PAT was provided." 1>&2
        echo "Either install az CLI or provide a Personal Access Token with -t flag." 1>&2
        exit 1
    fi

    # Fetch repositories using az CLI
    az repos list --organization "https://dev.azure.com/$ORGANIZATION" --project "$PROJECT" --output tsv --query '[].{sshUrl: sshUrl, defaultBranch: defaultBranch, remoteUrl: remoteUrl}' | while IFS=$'\t' read -r ssh_url default_branch remoteUrl; do
        process_repo "$ssh_url" "$default_branch" "$remoteUrl"
    done
fi
exit 0
