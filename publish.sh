#!/bin/bash

#set -o errexit   # abort on nonzero exitstatus
set -o nounset   # abort on unbound variable
set -o pipefail  # don't hide errors within pipes

# Check for diagnostic mode first (before requiring csv file)
if [ "${DIAGNOSE:-}" = "true" ]; then
    echo "Running comprehensive diagnostics..."
    if [ -f "/app/diagnostics/diagnose.sh" ]; then
        exec /app/diagnostics/diagnose.sh
    else
        echo "Error: diagnostics/diagnose.sh not found"
        exit 1
    fi
fi

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

# Check if mod CLI version is >= required version (semver comparison)
# Returns 0 (true) if current version >= required version, 1 (false) otherwise
mod_version_at_least() {
  local required_version=$1
  local current_version
  current_version=$(mod --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)

  if [ -z "$current_version" ]; then
    return 1
  fi

  # Split versions into components
  local req_major req_minor req_patch
  local cur_major cur_minor cur_patch

  IFS='.' read -r req_major req_minor req_patch <<< "$required_version"
  IFS='.' read -r cur_major cur_minor cur_patch <<< "$current_version"

  # Compare major
  if [ "$cur_major" -gt "$req_major" ]; then return 0; fi
  if [ "$cur_major" -lt "$req_major" ]; then return 1; fi

  # Compare minor
  if [ "$cur_minor" -gt "$req_minor" ]; then return 0; fi
  if [ "$cur_minor" -lt "$req_minor" ]; then return 1; fi

  # Compare patch
  if [ "$cur_patch" -ge "$req_patch" ]; then return 0; fi
  return 1
}

main() {
  initialize_instance_metadata
  run_startup_diagnostics

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
    if mod_version_at_least "3.56.7"; then
      mod log syncs add "$clone_dir" "$DATA_DIR/syncs.zip" --last-sync
    fi
    mod git pull "$clone_dir"
    mod build "$clone_dir" --no-download
    mod publish "$clone_dir"
    mod log builds add "$clone_dir" "$DATA_DIR/log.zip" --last-build
    send_logs "org-$ORGANIZATION"
  else
    select_repositories "$csv_file"
    split_into_batches "$DATA_DIR/selected-repos.csv"

    for batch_file in "$DATA_DIR/batches/"*; do
      local partition_name
      partition_name=$(basename "$batch_file" .csv)

      if ! build_and_upload_repos "$partition_name" "$batch_file"; then
        info "Error building and uploading repositories from $partition_name"
      else
        info "Successfully built and uploaded repositories from $partition_name"
      fi

      rm -rf "$DATA_DIR/$partition_name"
    done
    rm -rf "$DATA_DIR/batches"

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
  TOKEN=$(curl --connect-timeout 2 -sf -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
  export INSTANCE_ID=$(curl --connect-timeout 2 -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "localhost")
}

# Run startup diagnostics if enabled
run_startup_diagnostics() {
  if [ "${DIAGNOSE_ON_START:-}" = "true" ]; then
    info "Running startup diagnostics"

    if [ -f "/app/diagnostics/diagnose.sh" ]; then
      /app/diagnostics/diagnose.sh || info "Diagnostic issues detected (see above)"
    fi
  fi
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

# Split a CSV into batch files under $DATA_DIR/batches/.
# When BATCH_SIZE is set, each file contains at most BATCH_SIZE rows.
# Without BATCH_SIZE the entire CSV is used as a single batch.
split_into_batches() {
  local csv_file=$1
  local batch_dir="$DATA_DIR/batches"
  mkdir -p "$batch_dir"

  local batch_size="${BATCH_SIZE:-0}"
  if [[ "$batch_size" -gt 0 ]]; then
    local header
    header=$(head -n 1 "$csv_file")

    # split data rows (skip header) into chunk files
    tail -n +2 "$csv_file" | split -l "$batch_size" - "$batch_dir/batch-"

    # prepend the header to each chunk
    for file in "$batch_dir"/batch-*; do
      ( echo "$header"; cat "$file" ) > "$file.csv"
      rm "$file"
    done

    local batch_count
    batch_count=$(ls "$batch_dir"/*.csv | wc -l | tr -d ' ')
    info "Split $(( $(wc -l < "$csv_file") - 1 )) repositories into $batch_count batches of $batch_size"
  else
    cp "$csv_file" "$batch_dir/all.csv"
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
  if mod_version_at_least "3.56.7"; then
    mod log syncs add "$clone_dir" "$DATA_DIR/syncs.zip" --last-sync
  fi

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
    # Construct S3 path for build logs
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

    # Upload sync logs to S3 (if they exist)
    if [ -f "$DATA_DIR/syncs.zip" ]; then
      sync_logs_path="${PUBLISH_URL}/.logs/$index/$timestamp/ingest-sync-log-cli-$timestamp-$index.zip"
      info "Uploading sync logs to $sync_logs_path"

      S3_CMD=(aws s3 cp "$DATA_DIR/syncs.zip" "$sync_logs_path")

      if [ -n "${S3_PROFILE:-}" ]; then
        S3_CMD+=(--profile "${S3_PROFILE}")
      fi
      if [ -n "${S3_REGION:-}" ]; then
        S3_CMD+=(--region "${S3_REGION}")
      fi
      if [ -n "${S3_ENDPOINT:-}" ]; then
        S3_CMD+=(--endpoint-url "${S3_ENDPOINT}")
      fi

      if ! "${S3_CMD[@]}"; then
        info "Failed to upload sync logs to S3"
      fi
    fi
  # if PUBLISH_USER and PUBLISH_PASSWORD are set, or PUBLISH_TOKEN is set, publish logs
  elif [[ -n "${PUBLISH_USER:-}" && -n "${PUBLISH_PASSWORD:-}" ]]; then
    logs_url=$PUBLISH_URL/io/moderne/ingest-log/$index/$timestamp/ingest-log-cli-$timestamp-$index.zip
    info "Uploading logs to $logs_url"
    if ! curl -s -S --insecure -u "$PUBLISH_USER":"$PUBLISH_PASSWORD" -X PUT "$logs_url" -T "$DATA_DIR/log.zip"; then
        info "Failed to publish logs"
    fi

    # Upload sync logs (if they exist)
    if [ -f "$DATA_DIR/syncs.zip" ]; then
      sync_logs_url=$PUBLISH_URL/io/moderne/ingest-sync-log/$index/$timestamp/ingest-sync-log-cli-$timestamp-$index.zip
      info "Uploading sync logs to $sync_logs_url"
      if ! curl -s -S --insecure -u "$PUBLISH_USER":"$PUBLISH_PASSWORD" -X PUT "$sync_logs_url" -T "$DATA_DIR/syncs.zip"; then
          info "Failed to publish sync logs"
      fi
    fi
  elif [[ -n "${PUBLISH_TOKEN:-}" ]]; then
    logs_url=$PUBLISH_URL/io/moderne/ingest-log/$index/$timestamp/ingest-log-cli-$timestamp-$index.zip
    info "Uploading logs to $logs_url"
    if ! curl -s -S --insecure -H "Authorization: Bearer $PUBLISH_TOKEN" -X PUT "$logs_url" -T "$DATA_DIR/log.zip"; then
        info "Failed to publish logs"
    fi

    # Upload sync logs (if they exist)
    if [ -f "$DATA_DIR/syncs.zip" ]; then
      sync_logs_url=$PUBLISH_URL/io/moderne/ingest-sync-log/$index/$timestamp/ingest-sync-log-cli-$timestamp-$index.zip
      info "Uploading sync logs to $sync_logs_url"
      if ! curl -s -S --insecure -H "Authorization: Bearer $PUBLISH_TOKEN" -X PUT "$sync_logs_url" -T "$DATA_DIR/syncs.zip"; then
          info "Failed to publish sync logs"
      fi
    fi
  else
    info "No log publishing credentials provided"
  fi
}

main "$@"
