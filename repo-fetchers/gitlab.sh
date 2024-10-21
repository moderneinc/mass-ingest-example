#!/bin/bash

while getopts ":g:h:" opt; do
    case ${opt} in
        g )
            GROUP=$OPTARG
            ;;
        h )
            GITLAB_DOMAIN=$OPTARG
            ;;
        \? )
            echo "Usage: gitlab.sh [-g <group>] [-h <gitlab_domain>]"
            exit 1
            ;;
    esac
done


if [[ -z $AUTH_TOKEN ]]; then
    echo "Please set the AUTH_TOKEN environment variable."
    exit 1
fi

# default GITLAB_DOMAIN to gitlab.com
GITLAB_DOMAIN=${GITLAB_DOMAIN:-https://gitlab.com}

if [[ -z $GROUP ]]; then
    request_url="$GITLAB_DOMAIN/api/v4/projects?membership=true&simple=true"
else
    request_url="$GITLAB_DOMAIN/api/v4/groups/$GROUP/projects?include_subgroups=true&simple=true"
fi

pages=$(curl -s -D - -o /dev/null --header "Authorization: Bearer $AUTH_TOKEN" "$request_url" | grep X-Total-Pages | cut -d " " -f2)

jq_header='["cloneUrl","branch"],'
for i in $(eval echo "{1..$pages}")
do
    if [ $i -eq 2 ]; then
            jq_header=''
    fi
    curl --silent \
        --header "Authorization: Bearer $AUTH_TOKEN" \
        "$request_url&page=$i" \
        | jq -r "$jq_header(.[] | [.http_url_to_repo, .default_branch]) | @csv"
done

echo $result
