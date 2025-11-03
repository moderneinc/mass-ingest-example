#!/bin/bash

while getopts ":g:h:t:" opt; do
    case ${opt} in
        g )
            GROUP=$OPTARG
            ;;
        h )
            GITLAB_DOMAIN=$OPTARG
            ;;
        t )
            AUTH_TOKEN=$OPTARG
            ;;
        \? )
            echo "Usage: gitlab.sh -t <token> [-g <group>] [-h <gitlab_domain>]"
            exit 1
            ;;
    esac
done


if [[ -z $AUTH_TOKEN ]]; then
    echo "Error: Token is required. Use -t <token>"
    exit 1
fi

# default GITLAB_DOMAIN to gitlab.com
GITLAB_DOMAIN=${GITLAB_DOMAIN:-https://gitlab.com}

if [[ -z $GROUP ]]; then
    base_request_url="$GITLAB_DOMAIN/api/v4/projects?membership=true&simple=true&archived=false"
else
    base_request_url="$GITLAB_DOMAIN/api/v4/groups/$GROUP/projects?include_subgroups=true&simple=true&archived=false"
fi

page=1
per_page=100

echo '"cloneUrl","branch","origin","path"'
while :; do
    # Construct the request URL with pagination parameters
    request_url="${base_request_url}&page=${page}&per_page=${per_page}"

    # Fetch the data (with 30 second timeout per request)
    response=$(curl --silent --max-time 30 --header "Authorization: Bearer $AUTH_TOKEN" "$request_url")

    # Check if curl failed
    if [ $? -ne 0 ]; then
        echo "Error: Failed to fetch repositories from GitLab API." 1>&2
        exit 1
    fi

    # Validate JSON response
    if ! echo "$response" | jq -e '.' >/dev/null 2>&1; then
        echo "Error: Invalid JSON response from GitLab API." 1>&2
        echo "Response saved to: gitlab-fetch-error.html" 1>&2
        echo "$response" > gitlab-fetch-error.html
        exit 1
    fi

    # Check if the response is empty, if so, break the loop
    if [[ $(echo "$response" | jq '. | length') -eq 0 ]]; then
        break
    fi

    # Process and output data
    echo "$response" | jq -r '(.[] |
      .http_url_to_repo as $url |
      ($url | sub("https://"; "") | sub("/.*"; "")) as $origin |
      ($url | sub("https://[^/]+/"; "") | sub("\\.git$"; "")) as $path |
      [$url, .default_branch, $origin, $path]) | @csv'

    # Increment page counter
    ((page++))
done
