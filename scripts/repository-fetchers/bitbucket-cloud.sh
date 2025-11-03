#!/bin/bash

usage() {
  echo "Usage: $0 -u <username> -p <api_token> [-c <clone_protocol>] <workspace>"
  echo "  -u: Bitbucket username"
  echo "  -p: Bitbucket API token"
  echo "  -c: Clone protocol (ssh or https, default: https)"
  exit 1
}

# Parse command-line arguments
clone_protocol="https"
while getopts ":u:p:c:" opt; do
  case ${opt} in
    u) username=$OPTARG;;
    p) api_token=$OPTARG;;
    c) clone_protocol=$OPTARG;;
    *) usage;;
  esac
done
shift $((OPTIND -1))

# Set workspace from positional argument
workspace=$1

if [ -z "$username" -o -z "$api_token" -o -z "$workspace" ]; then
    echo "Error: Please provide username, API token, and workspace." >&2
    usage
fi

if [ "$clone_protocol" != "ssh" ] && [ "$clone_protocol" != "https" ]; then
    echo "Error: clone_protocol must be either 'ssh' or 'https'" >&2
    exit 1
fi

echo "cloneUrl,branch,origin,path"

next_page="https://api.bitbucket.org/2.0/repositories/$workspace"

while [ "$next_page" ]; do
  response=$(curl -s --max-time 30 -u "$username:$api_token" "$next_page")

  # Check if curl failed
  if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch repositories from Bitbucket Cloud API." 1>&2
    exit 1
  fi

  # Validate JSON response
  if ! echo "$response" | jq -e '.' >/dev/null 2>&1; then
    echo "Error: Invalid JSON response from Bitbucket Cloud API." 1>&2
    echo "Response saved to: bitbucket-cloud-fetch-error.html" 1>&2
    echo "$response" > bitbucket-cloud-fetch-error.html
    exit 1
  fi

  # Extract repository data and append to CSV file
  echo $response | jq --arg CLONE_PROTOCOL $clone_protocol -r '
    .values[] |
    (.links.clone[] | select(.name == $CLONE_PROTOCOL) | .href) as $cloneUrl |
    .mainbranch.name as $branchName |
    ($cloneUrl | sub("https://"; "") | sub("@"; "") | sub("/"; " ") | split(" ")[0]) as $origin |
    ($cloneUrl | sub("https://[^/]+/"; "") | sub("\\.git$"; "")) as $path |
    "\($cloneUrl),\($branchName),\($origin),\($path)"' |
  while IFS=, read -r cloneUrl branchName origin path; do
    cleanUrl=$(echo "$cloneUrl" | sed -E 's|https://[^@]+@|https://|')
    echo "$cleanUrl,$branchName,$origin,$path"
  done

  next_page=$(echo $response | sed -e "s:${username}@::g" | jq -r '.next // empty')
done

exit 0
