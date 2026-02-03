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
  local range="${START_INDEX:-}-${END_INDEX:-}"
  if [[ -z "${END_INDEX:-}" || -z "${START_INDEX:-}" ]]; then
    range="all"
  fi
  printf "[%s][%s] %s\n" "$INSTANCE_ID" "$range" "$1"
}

die() {
  local range="${START_INDEX:-}-${END_INDEX:-}"
  if [[ -z "${END_INDEX:-}" || -z "${START_INDEX:-}" ]]; then
    range="all"
  fi
  printf "[%s][%s] %s\n" "$INSTANCE_ID" "$range" "$1" >&2
  exit 1
}

main() {
  initialize_instance_metadata

  # read the first positional argument as the source csv file
  csv_file=$1
  if [[ "$csv_file" == "s3://"* ]]; then
    aws s3 cp "$csv_file" "repos.csv"
    local_csv_file="repos.csv"
  elif [[ "$csv_file" == "http://"* || "$csv_file" == "https://"* ]]; then
    curl "$csv_file" -o "repos.csv"
    local_csv_file="repos.csv"
  elif [[ -f "$csv_file" ]]; then
    local_csv_file="$csv_file"
  else
    die "File '$csv_file' does not exist"
  fi

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
      --timeout)
        BUILD_TIMEOUT="$2"
        ;;
      *)
        die "Invalid option: $arg"
        ;;
    esac
    shift 2
  done

  # build/ingest all repos
  ingest_repos "$local_csv_file"
}

ingest_repos() {
  csv_file="$1"

  configure_credentials
  prepare_environment
  start_monitoring
  if [ -n "${ORGANIZATION:-}" ]; then
    local clone_dir="$DATA_DIR/$ORGANIZATION"
    printf "Organization: %s\n" "$ORGANIZATION"
    mkdir -p "$clone_dir"
    mod git sync csv "$clone_dir" "$csv_file" --organization "$ORGANIZATION" --with-sources
    mod git pull "$clone_dir"
    mod build "$clone_dir" --no-download
    mod publish "$clone_dir"
    mod log builds add "$clone_dir" "$DATA_DIR/log.zip" --last-build
    send_logs "org-$ORGANIZATION"
  else
    select_repositories "$csv_file"

    # create a partition name based on the current partition and the current date YYYY-MM-DD-HH-MM
    partition_name=$(date +"%Y-%m-%d-%H-%M")

    if ! build_and_upload_repos "$partition_name" "$DATA_DIR/selected-repos.csv"; then
      info "Error building and uploading repositories"
    else
      info "Successfully built and uploaded repositories"
    fi

    # Upload results
    if [[ -z "${END_INDEX:-}" || -z "${START_INDEX:-}" ]]; then
      send_logs "all"
    else
      send_logs "$START_INDEX-$END_INDEX"
    fi
  fi
  stop_monitoring
}

# Initialize instance if running on AWS EC2 (batch mode)
initialize_instance_metadata() {
  TOKEN=$(curl --connect-timeout 2 -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  export INSTANCE_ID=$(curl --connect-timeout 2 -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id || echo "localhost")
}

# Configure credentials at runtime (passed via environment variables)
configure_credentials() {
  info "Configuring credentials"

  # Configure Moderne tenant if token provided
  if [ -n "${MODERNE_TOKEN:-}" ] && [ -n "${MODERNE_TENANT:-}" ]; then
    info "Configuring Moderne tenant: ${MODERNE_TENANT}"
    mod config moderne edit --token="${MODERNE_TOKEN}" "${MODERNE_TENANT}"
  fi

  if [ -n "${GIT_CREDENTIALS:-}" ]; then
    echo -e "${GIT_CREDENTIALS}" > /root/.git-credentials
  fi

  if [ -n "${GIT_SSH_CREDENTIALS:-}" ]; then
    mkdir -p /root/.ssh
    echo -e "${GIT_SSH_CREDENTIALS}" > /root/.ssh/private-key
    chmod 600 /root/.ssh/private-key
  fi

  # Configure artifact repository
  # S3 configuration (S3 bucket URL should start with s3://)
  if [[ "${PUBLISH_URL:-}" == "s3://"* ]]; then
    info "Configuring S3 artifact repository: ${PUBLISH_URL}"

    # Build the command with proper quoting
    S3_CONFIG_CMD=(mod config lsts artifacts s3 edit "${PUBLISH_URL}")

    # Add endpoint if provided (for S3-compatible services)
    if [ -n "${S3_ENDPOINT:-}" ]; then
      S3_CONFIG_CMD+=(--endpoint "${S3_ENDPOINT}")
    fi

    # Add AWS profile if provided
    if [ -n "${S3_PROFILE:-}" ]; then
      S3_CONFIG_CMD+=(--profile "${S3_PROFILE}")
    fi

    # Add region if provided (for cross-region access)
    if [ -n "${S3_REGION:-}" ]; then
      S3_CONFIG_CMD+=(--region "${S3_REGION}")
    fi

    # Execute the command
    info "Running: ${S3_CONFIG_CMD[*]}"
    "${S3_CONFIG_CMD[@]}"
  # Maven repository configuration
  elif [ -n "${PUBLISH_URL:-}" ] && [ -n "${PUBLISH_USER:-}" ] && [ -n "${PUBLISH_PASSWORD:-}" ]; then
    info "Configuring Maven artifact repository with username/password"
    mod config lsts artifacts maven edit "${PUBLISH_URL}" --user "${PUBLISH_USER}" --password "${PUBLISH_PASSWORD}"
  # Artifactory configuration
  elif [ -n "${PUBLISH_URL:-}" ] && [ -n "${PUBLISH_TOKEN:-}" ]; then
    info "Configuring Artifactory artifact repository with API token"
    mod config lsts artifacts artifactory edit "${PUBLISH_URL}" --jfrog-api-token "${PUBLISH_TOKEN}"
  else
    die "PUBLISH_URL must be supplied via environment variable. For S3, use s3:// URL format. For Maven/Artifactory, also provide PUBLISH_USER/PUBLISH_PASSWORD or PUBLISH_TOKEN"
  fi
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
  echo $! > "$DATA_DIR/monitor.pid"
}

stop_monitoring() {
  info "Cleaning up monitoring"
  if [ -f "$DATA_DIR/monitor.pid" ]; then
    kill -9 $(cat "$DATA_DIR/monitor.pid")
    rm "$DATA_DIR/monitor.pid"
  fi
}

select_repositories() {
  local csv_file=$1

  if [ ! -f "$csv_file" ]; then
    die "File $csv_file does not exist"
  fi

  if [[ -n "${START_INDEX:-}" && -n "${END_INDEX:-}" ]]; then
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

  # kill a build if it takes too long assuming it's hung indefinitely
  # defaults to 2700 seconds (45 minutes)
  local build_timeout="${BUILD_TIMEOUT:-2700}"
  timeout "$build_timeout" mod build "$clone_dir" --no-download
  ret=$?
  if [ $ret -eq 124 ]; then
    printf "\n* Build timed out after %s seconds\n\n" "$build_timeout"
  fi

  mod publish "$clone_dir"
  mod log builds add "$clone_dir" "$DATA_DIR/log.zip" --last-build
  return $ret
}

send_logs() {
  local index=$1
  local timestamp=$(date +"%Y%m%d%H%M")

  # Upload logs to S3
  if [[ "${PUBLISH_URL:-}" == "s3://"* ]]; then
    # Construct S3 path for logs
    logs_path="${PUBLISH_URL}/.logs/$index/$timestamp/ingest-log-cli-$timestamp-$index.zip"
    info "Uploading logs to $logs_path"

    # Build AWS S3 command with optional parameters
    S3_CMD=(aws s3 cp "$DATA_DIR/log.zip" "$logs_path")

    # Add profile if specified
    if [ -n "${S3_PROFILE:-}" ]; then
      S3_CMD+=(--profile "${S3_PROFILE}")
    fi

    # Add region if specified
    if [ -n "${S3_REGION:-}" ]; then
      S3_CMD+=(--region "${S3_REGION}")
    fi

    # Add endpoint if specified (for S3-compatible services)
    if [ -n "${S3_ENDPOINT:-}" ]; then
      S3_CMD+=(--endpoint-url "${S3_ENDPOINT}")
    fi

    # Execute the upload
    if ! "${S3_CMD[@]}"; then
      info "Failed to upload logs to S3"
    fi
  # if PUBLISH_USER and PUBLISH_PASSWORD are set, or PUBLISH_TOKEN is set, publish logs
  elif [[ -n "${PUBLISH_USER:-}" && -n "${PUBLISH_PASSWORD:-}" ]]; then
    logs_url=$PUBLISH_URL/io/moderne/ingest-log/$index/$timestamp/ingest-log-cli-$timestamp-$index.zip
    info "Uploading logs to $logs_url"
    if ! curl -s -S --insecure -u "$PUBLISH_USER":"$PUBLISH_PASSWORD" -X PUT "$logs_url" -T "$DATA_DIR/log.zip"; then
        info "Failed to publish logs"
    fi
  elif [[ -n "${PUBLISH_TOKEN:-}" ]]; then
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
