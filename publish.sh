#!/bin/bash

# if `mod` already exists in the path, use it, otherwise use the local version
mod_command=$(command -v mod)
if [ -z "$mod_command" ]; then
  mod_command="java -jar mod.jar"
fi

# if no argument is provided, print an error message and exit
if [ $# -eq 0 ]
  then
    echo "No repository file supplied. Please provide the path to the csv file."
    exit 1
fi
csv_file=$1
log_publish_user=$2
log_publish_password=$3

# split csv file into 10 line chunks.
# the chunks should be named `repos-{chunk}`
# the csv file will contain two columns: url and branch
# capture the first row as the header and save to var
header=$(head -n 1 "$csv_file")
split -l 10 "$csv_file" repos-

# ensure each chunk has the header row
for file in repos-*
  do
    if [ "$(head -n 1 "$file")" != "$header" ]; then
      echo "$header" | cat - "$file" > temp && mv temp "$file"
    fi
done

# counter init to 0
index=0

while true; do
  # for each chunk, read the contents of hte csv file
  for file in repos-*
  do
    if [ "$(head -n 1 "$file")" != "$header" ]; then
      # prepend header to the file
      echo $header | cat - "$file" > temp && mv temp "$file"
    fi

    # extract just the partition name from the file name
    partition_name=$(echo "$file" | cut -d'-' -f2)
    printf "[%d][%s] Processing partition\n" $index "$partition_name"

    printf "[%d][%s] Cloning repositories\n" $index "$partition_name"
    $mod_command git clone csv "$partition_name" "$file" --filter=tree:0

    # if cloning failed, skip the rest of the loop
    if [ $? -ne 0 ]; then
      printf "[%d][%s] Cloning failed, skipping partition\n" $index "$partition_name"
      continue
    fi

    printf "[%d][%s] Building LSTs\n" $index "$partition_name"
    $mod_command build "./$partition_name" --no-download # `-name` doesn't exist: -name "$index"

    printf "[%d][%s] Publishing LSTs\n" $index "$partition_name"
    $mod_command publish "./$partition_name"

    printf "[%d][%s] Gathering logs\n" $index "$partition_name"
    $mod_command log builds add "./$partition_name" log.zip --last-build

    printf "[%d][%s] Cleaning up partition\n" $index "$partition_name"
    # if directory exists, remove it
    if [ -d "./$partition_name" ]; then
      rm -rf "./$partition_name"
    fi
  done

  # if log_publish_user and log_publish_password are set, publish logs
  if [ -z "$log_publish_user" ] || [ -z "$log_publish_password" ]; then
    printf "[%d] No log publishing credentials provided\n" $index
    break
  fi
  log_version=$(date '+%Y%m%d%H%M%S')
  curl --insecure -u "$log_publish_user":"$log_publish_password" -X PUT \
    "https://artifactory.moderne.ninja/artifactory/moderne-ingest/io/moderne/ingest-log/$log_version/ingest-log-$log_version.zip" \
    -T log.zip

  # increment index
  index=$((index+1))
done
