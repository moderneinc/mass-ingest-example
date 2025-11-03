#!/bin/bash

# Show help function
usage() {
    echo "Usage: azure-devops.sh -o <organization> -p <project> [-s]"
    echo ""
    echo "Required:"
    echo "  -o  Azure DevOps Organization"
    echo "  -p  Azure DevOps Project"
    echo "Optional:"
    echo "  -s  Use SSH URLs instead of HTTPS URLs (default: HTTPS)"
}

# Parse command-line arguments
while getopts ":o:p:s" opt; do
  case ${opt} in
    o) ORGANIZATION=$OPTARG;;
    p) PROJECT=$OPTARG;;
    s) USE_SSH=true;;
    *) usage;;
  esac
done
shift $((OPTIND -1))

# Validate required parameters
if [[ -z "$ORGANIZATION" ]]; then
    echo "Error: Organization is required (-o)"
    usage
    exit 1
fi

if [[ -z "$PROJECT" ]]; then
    echo "Error: Project is required (-p)"
    usage
    exit 1
fi

# Output CSV header
echo "cloneUrl,branch,origin,path"

# Fetch repositories using TSV output and process manually
az repos list --organization "https://dev.azure.com/$ORGANIZATION" --project "$PROJECT" --output tsv --query '[].{sshUrl: sshUrl, defaultBranch: defaultBranch, remoteUrl: remoteUrl}' | while IFS=$'\t' read -r ssh_url default_branch remoteUrl; do
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
        clone_url="$remoteUrl"
        # HTTPS URL format: https://dev.azure.com/organization/project/_git/repo
        # Extract origin: dev.azure.com
        origin=$(echo "$clone_url" | sed -E 's|^https://([^/]+)/.*|\1|')
        # Extract path: organization/project/repo (remove /_git/)
        path=$(echo "$clone_url" | sed -E 's|^https://[^/]+/([^/]+/[^/]+)/_git/(.*)|\1/\2|')
    fi

    # Output in CSV format with proper quoting
    echo "\"$clone_url\",\"$branch\",\"$origin\",\"$path\""
done