#!/bin/bash

csv_file="repos.csv"

function split_and_verify_csv() {
  rm -f repos-*

  partition_size=10
  header=$(head -n 1 "$csv_file")

  split -l "$partition_size" "$csv_file" repos-

  for file in repos-*
  do
    if [ "$(head -n 1 "$file")" != "$header" ]; then
      echo "$header" | cat - "$file" > temp && mv temp "$file"
    fi
  done
}

function start_supervisord() {
  /usr/bin/supervisord --loglevel=error --directory=/tmp --configuration=/etc/supervisord.conf > /dev/null 2>&1 &
}

function cleanup() {
  if [ -d "./$1" ]; then
    rm -rf "./$1"
  fi
}


function publish_log() {
  if [ -z "$PUBLISH_USER" ] || [ -z "$PUBLISH_PASSWORD" ] || [ -z "$PUBLISH_URL" ]; then
    echo "No log publishing credentials provided"
  else
    log_version=$(date '+%Y%m%d%H%M%S')
    curl --insecure -u "$PUBLISH_USER":"$PUBLISH_PASSWORD" -X PUT \
      "$PUBLISH_URL/io/moderne/ingest-log/$log_version/ingest-log-$log_version.zip" \
      -T log.zip
  fi
}


# counter init to 0
index=0

function build_and_upload_repos() {
  split_and_verify_csv
  for file in repos-*
  do
    if [ "$(head -n 1 "$file")" != "$header" ]; then
      # prepend header to the file
      echo $header | cat - "$file" > temp && mv temp "$file"
    fi

    partition_name=$(echo "$file" | cut -d'-' -f2)

    # if cloning failed, skip the rest of the loop
    if ! mod git clone csv "$partition_name" "$file" --filter=tree:0; then
      echo "Cloning failed, skipping partition $index $partition_name"
      continue
    fi

    mod build "./$partition_name" --no-download

    mod publish "./$partition_name"

    mod log builds add "./$partition_name" log.zip --last-build

    cleanup "$partition_name"
  done


  publish_log

  # increment index
  index=$((index+1))
}

start_supervisord
# Continuously build and upload repositories in a loop
# If you'd like to run this script once, or on a schedule, remove the while loop
while true; do
  build_and_upload_repos
done

