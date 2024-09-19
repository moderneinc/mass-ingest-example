#!/bin/bash

set -o errexit   # abort on nonzero exitstatus
set -o nounset   # abort on unbound variable
set -o pipefail  # don't hide errors within pipes

# if no argument is provided, print an error message and exit
if [ $# -eq 0 ]
  then
    echo "No repository file supplied. Please provide the path to the csv file."
    exit 1
fi

# Clean any existing files in the data directory
if [ -d "$DATA_DIR" ]; then
  rm -rf "${DATA_DIR:?}"/*
fi

# Create the data directory and partition directory
PARTITION_DIR="$DATA_DIR/partitions"
mkdir -p "$PARTITION_DIR"


CSV_FILE="$DATA_DIR/$1"
cp "$1" "$DATA_DIR"

# split csv file into 10 line chunks.
# the chunks should be named `repos-{chunk}`
# the csv file will contain two columns: url and branch
# capture the first row as the header and save to var
header=$(head -n 1 "$CSV_FILE")
cd "$PARTITION_DIR" || exit
split -l 10 "$CSV_FILE" repos-

# ensure each chunk has the header row
for file in repos-*
  do
    if [ "$(head -n 1 "$file")" != "$header" ]; then
      echo "$header" | cat - "$file" > temp && mv temp "$file"
    fi
done

# counter init to 0
index=0

function build_and_upload_repos() {
  # for each chunk, read the contents of the csv file
  for file in repos-*
  do
    if [ "$(head -n 1 "$file")" != "$header" ]; then
      # prepend header to the file
      echo "$header" | cat - "$file" > temp && mv temp "$file"
    fi

    # extract just the partition name from the file name
    partition_name=$(echo "$file" | cut -d'-' -f2)

    # if cloning failed, skip the rest of the loop
    if ! mod git clone csv "$partition_name" "$file" --filter=tree:0; then
      printf "[%d][%s] Cloning failed, skipping partition\n" $index "$partition_name"
      continue
    fi

    mod build "./$partition_name" --no-download

    mod publish "./$partition_name"

    mod log builds add "./$partition_name" log.zip --last-build

    # if directory exists, remove it
    if [ -d "./$partition_name" ]; then
      rm -rf "./$partition_name"
    fi
  done

  # if PUBLISH_USER, PUBLISH_PASSWORD, and PUBLISH_URL are set, publish logs
  if [ -z "$PUBLISH_USER" ] || [ -z "$PUBLISH_PASSWORD" ] || [ -z "$PUBLISH_URL" ]; then
    printf "[%d] No log publishing credentials or URL provided\n" $index
  else
    log_version=$(date '+%Y%m%d%H%M%S')
    curl --insecure -u "$PUBLISH_USER":"$PUBLISH_PASSWORD" -X PUT \
      "$PUBLISH_URL/$log_version/ingest-log-$log_version.zip" \
      -T log.zip
  fi

  # increment index
  index=$((index+1))
}

# Continuously build and upload repositories in a loop
# If you'd like to run this script once, or on a schedule, remove the while loop
while true; do
  build_and_upload_repos
done

