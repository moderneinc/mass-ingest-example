#!/bin/bash

# Usage: github.sh <org> [token] [api_url]
# If token is provided, use API mode. Otherwise use gh CLI.

if [ -z "$1" ]; then
  echo "Usage: $0 <org> [token] [api_url]"
  echo "Example: $0 openrewrite"
  echo "Example with token: $0 openrewrite ghp_xxxxx"
  echo "Example with GHE: $0 openrewrite ghp_xxxxx https://github.example.com/api/v3"
  exit 1
fi

organization=$1
token=$2
api_url=${3:-"https://api.github.com"}

echo "\"cloneUrl\",\"branch\",\"origin\",\"path\""

# Use API mode if token is provided, otherwise use gh CLI
if [ -n "$token" ]; then
    # API mode with token
    page=1
    per_page=100

    while :; do
        request_url="${api_url}/orgs/${organization}/repos?page=${page}&per_page=${per_page}&type=all"

        response=$(curl --silent --max-time 30 --header "Authorization: Bearer $token" "$request_url")

        # Check if curl failed
        if [ $? -ne 0 ]; then
            echo "Error: Failed to fetch repositories from GitHub API." 1>&2
            exit 1
        fi

        # Validate JSON response
        if ! echo "$response" | jq -e '.' >/dev/null 2>&1; then
            echo "Error: Invalid JSON response from GitHub API." 1>&2
            echo "Response saved to: github-fetch-error.html" 1>&2
            echo "$response" > github-fetch-error.html
            exit 1
        fi

        # Check if response is an error message (not an array)
        if echo "$response" | jq -e 'if type == "array" then false else true end' >/dev/null 2>&1; then
            error_msg=$(echo "$response" | jq -r '.message // "Unknown error"')
            echo "Error: GitHub API error - $error_msg" 1>&2
            exit 1
        fi

        # Check if the response is empty, if so, break the loop
        if [[ $(echo "$response" | jq '. | length') -eq 0 ]]; then
            break
        fi

        # Process and output data (exclude archived repos)
        echo "$response" | jq -r '.[] | select(.archived == false) |
          .clone_url as $url |
          ($url | sub("https://"; "") | sub("/"; " ") | split(" ")[0]) as $origin |
          ($url | sub("https://[^/]+/"; "") | sub("\\.git$"; "")) as $path |
          [$url, .default_branch, $origin, $path] | @csv'

        # Increment page counter
        ((page++))
    done
else
    # CLI mode - check if gh is available
    if ! command -v gh &> /dev/null; then
        echo "Error: GitHub CLI (gh) is not installed and no token was provided." 1>&2
        echo "Either install gh CLI or provide a personal access token." 1>&2
        exit 1
    fi

    # Use gh CLI
    gh api --paginate "orgs/$organization/repos" --jq '.[] | select(.archived == false) |
      .clone_url as $url |
      ($url | sub("https://"; "") | sub("/"; " ") | split(" ")[0]) as $origin |
      ($url | sub("https://[^/]+/"; "") | sub("\\.git$"; "")) as $path |
      [$url, .default_branch, $origin, $path] | @csv' | sort
fi

exit 0
