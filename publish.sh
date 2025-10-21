#!/bin/bash

#set -o errexit   # abort on nonzero exitstatus
set -o nounset   # abort on unbound variable
set -o pipefail  # don't hide errors within pipes

# if no argument is provided, print an error message and exit
if [ $# -eq 0 ]
  then
    echo "No repository file supplied. Please provide the path to the csv file."
    exit 1
fi

info() {
  printf "[%s][%d-%d] %s\n" "$INSTANCE_ID" "$START_INDEX" "$END_INDEX" "$1"
}

die() {
  printf "[%s][%d-%d] %s\n" "$INSTANCE_ID" "$START_INDEX" "$END_INDEX" "$1" >&2
  exit 1
}

main() {
  setup

  # read the first positional argument as the source csv file
  SOURCE_CSV=$1
  # shift the arguments to read the next positional argument as the index
  shift
  # all other arguments should be read as flags with getopts
  while [[ $# -ne 0 ]]; do
    arg="$1"
    case "$arg" in
      --end)
        END_INDEX="$2"
        ;;
      -o|--organization)
        ORGANIZATION="$2"
        ;;
      --start)
        START_INDEX="$2"
        ;;
      *)
        die "Invalid option: $arg"
        ;;
    esac
    shift 2
  done

  # build/ingest all repos
  ingest_repos
}

ingest_repos() {
  prepare_environment
  start_monitoring
  if [ -n "$ORGANIZATION" ]; then
    local clone_dir="$DATA_DIR/$ORGANIZATION"
    printf "Organization: %s\n" "$ORGANIZATION"
    mkdir -p "$clone_dir"
    mod git sync csv "$clone_dir" "$SOURCE_CSV" --organization "$ORGANIZATION" --with-sources
    mod git pull "$clone_dir"
    mod build "$clone_dir" --no-download
    mod publish "$clone_dir"
    mod log builds add "$clone_dir" "$DATA_DIR/log.zip" --last-build
    send_logs "org-$ORGANIZATION"
  else
    select_repositories "$SOURCE_CSV"

    # create a partition name based on the current partition and the current date YYYY-MM-DD-HH-MM
    partition_name=$(date +"%Y-%m-%d-%H-%M")

    if ! build_and_upload_repos "$partition_name" "$DATA_DIR/selected-repos.csv"; then
      info "Error building and uploading repositories"
    else
      info "Successfully built and uploaded repositories"
    fi

    # Upload results
    send_logs "$START_INDEX-$END_INDEX"
  fi
  stop_monitoring
}

setup() {
  TOKEN=$(curl --connect-timeout 2 -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  export INSTANCE_ID=$(curl --connect-timeout 2 -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id || echo "localhost")
}

# Clean any existing files
prepare_environment() {
  info "Preparing environment"
  mkdir -p "$DATA_DIR"
  rm -rf "${DATA_DIR:?}"/*
  mkdir -p "$HOME/.moderne/cli/metrics/"
  rm -rf "$HOME/.moderne/cli/metrics"/*
}

start_monitoring() {
  info "Starting monitoring"
  nohup mod monitor --port 8080 > /dev/null 2>&1 &
  echo $! > "$DATA_DIR/$MONITOR_PID"
}

stop_monitoring() {
  info "Cleaning up monitoring"
  if [ -f "$DATA_DIR/$MONITOR_PID" ]; then
    kill -9 $(cat "$DATA_DIR/$MONITOR_PID")
    rm "$DATA_DIR/$MONITOR_PID"
  fi
}

select_repositories() {
  local csv_file=$1

  if [ ! -f "$csv_file" ]; then
    die "File $csv_file does not exist"
  fi

  if [[ -n "$START_INDEX" && -n "$END_INDEX" ]]; then
    info "Selecting repositories from $csv_file starting at $START_INDEX and ending at $END_INDEX"

    header=$(head -n 1 "$csv_file")

    # select the lines from start_line to end_line from $csv_file
    selected_lines=$(tail -n +2 "$csv_file" | sed -n "${START_INDEX},${END_INDEX}p")

    ( echo "$header"; echo "$selected_lines" ) > "$DATA_DIR/selected-repos.csv"
  else
    info "Selected all repositories from $csv_file"

    cp "$csv_file" "$DATA_DIR/selected-repos.csv"
  fi
}

build_and_upload_repos() {
  local clone_dir="$DATA_DIR/$1"
  local partition_file=$2
  info "Building and uploading repositories into $clone_dir from $partition_file"

  # turn off color output and cursor movement in the CLI
  export NO_COLOR=true
  export TERM=dumb

  mod git sync csv "$clone_dir" "$partition_file" --with-sources

  # kill a build if it takes over 45 minutes assuming it's hung indefinitely
  timeout 2700 mod build "$clone_dir" --no-download
  ret=$?
  if [ $ret -eq 124 ]; then
    printf "\n* Build timed out after 45 minutes\n\n"
  fi

  mod publish "$clone_dir"
  mod log builds add "$clone_dir" "$DATA_DIR/log.zip" --last-build
  return $ret
}

send_logs() {
  local index=$1
  local timestamp=$(date +"%Y%m%d%H%M")

  # if PUBLISH_USER and PUBLISH_PASSWORD are set, publish logs
  if [[ -n "$PUBLISH_USER" && -n "$PUBLISH_PASSWORD" ]]; then
    logs_url=$PUBLISH_URL/io/moderne/ingest-log/$index/$timestamp/ingest-log-cli-$timestamp-$index.zip
    info "Uploading logs to $logs_url"
    if ! curl -s -S --insecure -u "$PUBLISH_USER":"$PUBLISH_PASSWORD" -X PUT "$logs_url" -T "$DATA_DIR/log.zip"; then
        info "Failed to publish logs"
    fi
  elif [[ -n "$PUBLISH_TOKEN" ]]; then
    logs_url=$PUBLISH_URL/io/moderne/ingest-log/$index/$timestamp/ingest-log-cli-$timestamp-$index.zip
    info "Uploading logs to $logs_url"
    if ! curl -s -S --insecure -H "Authorization: Bearer $PUBLISH_TOKEN" -X PUT "$logs_url" -T "$DATA_DIR/log.zip"; then
        info "Failed to publish logs"
    fi
  else
    info "No log publishing credentials provided"
  fi
}

main "$@"
