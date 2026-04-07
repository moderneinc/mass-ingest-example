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
    # URL-encode the group path (replace / with %2F)
    encoded_group=$(echo "$GROUP" | sed 's/\//%2F/g')
    base_request_url="$GITLAB_DOMAIN/api/v4/groups/$encoded_group/projects?include_subgroups=true&simple=true&archived=false"
fi

page=1
per_page=100

echo '"cloneUrl","branch","origin","path"'
while :; do
    # Construct the request URL with pagination parameters
    request_url="${base_request_url}&page=${page}&per_page=${per_page}"

    # Fetch the data with error capture
    temp_err_file=$(mktemp)
    response=$(curl -sS --max-time 10 -w "\n%{http_code}" --header "Authorization: Bearer $AUTH_TOKEN" "$request_url" 2>"$temp_err_file")
    curl_exit=$?
    curl_stderr=$(cat "$temp_err_file")
    rm -f "$temp_err_file"

    # Extract HTTP status code and body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    # Check if curl failed
    if [ $curl_exit -ne 0 ]; then
        echo "Error: Failed to fetch repositories from GitLab API (curl exit code: $curl_exit)" 1>&2
        echo "Show full error details? (y/n)" 1>&2
        read -r show_details
        if [[ "$show_details" =~ ^[Yy] ]]; then
            echo "─────────────────────────────────────────────────────" 1>&2
            echo "Request URL: $request_url" 1>&2
            echo "HTTP Status: $http_code" 1>&2
            echo "Curl stderr: $curl_stderr" 1>&2
            echo "Response body:" 1>&2
            echo "$body" 1>&2
            echo "─────────────────────────────────────────────────────" 1>&2
        fi
        exit 1
    fi

    # Check HTTP status code
    if [ "$http_code" != "200" ]; then
        echo "Error: GitLab API returned HTTP $http_code" 1>&2
        echo "Show full error details? (y/n)" 1>&2
        read -r show_details
        if [[ "$show_details" =~ ^[Yy] ]]; then
            echo "─────────────────────────────────────────────────────" 1>&2
            echo "Request URL: $request_url" 1>&2
            echo "HTTP Status: $http_code" 1>&2
            echo "Response body:" 1>&2
            echo "$body" 1>&2
            echo "─────────────────────────────────────────────────────" 1>&2
        fi
        exit 1
    fi

    # Validate JSON response
    if ! echo "$body" | jq -e '.' >/dev/null 2>&1; then
        echo "Error: Invalid JSON response from GitLab API." 1>&2
        echo "Response saved to: gitlab-fetch-error.html" 1>&2
        echo "$body" > gitlab-fetch-error.html
        echo "Response length: $(echo "$body" | wc -c | tr -d ' ') bytes" 1>&2
        echo "First 200 chars: $(echo "$body" | head -c 200)" 1>&2
        echo "" 1>&2
        echo "To debug, run this command manually:" 1>&2
        echo "curl -v --header 'Authorization: Bearer ***' '$request_url'" 1>&2
        exit 1
    fi

    # Check if response is an error message (not an array)
    if echo "$body" | jq -e 'if type == "array" then false else true end' >/dev/null 2>&1; then
        error_msg=$(echo "$body" | jq -r '.message // "Unknown error"')
        echo "Error: GitLab API error - $error_msg" 1>&2
        exit 1
    fi

    # Check if the response is empty, if so, break the loop
    if [[ $(echo "$body" | jq '. | length') -eq 0 ]]; then
        break
    fi

    # Process and output data
    echo "$body" | jq -r '(.[] |
      .http_url_to_repo as $url |
      ($url | sub("https://"; "") | sub("/.*"; "")) as $origin |
      ($url | sub("https://[^/]+/"; "") | sub("\\.git$"; "")) as $path |
      [$url, .default_branch, $origin, $path]) | @csv'

    # Increment page counter
    ((page++))
done

exit 0
