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
    mod log syncs add "$clone_dir" "$DATA_DIR/syncs.zip" --last-sync
    mod git pull "$clone_dir"
    refresh_codeartifact_token || info "Token refresh failed; continuing with the existing token"
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

  # BATCH_SIZE is consumed as a number by every publish path (split_into_batches); a
  # non-numeric value would otherwise surface as an opaque bash arithmetic error.
  if [ -n "${BATCH_SIZE:-}" ] && ! [[ "${BATCH_SIZE}" =~ ^[0-9]+$ ]]; then
    die "BATCH_SIZE must be a non-negative integer, not '${BATCH_SIZE}'"
  fi

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
  # AWS CodeArtifact (Maven repo with a short-lived, rotating auth token)
  if [ -n "${CODEARTIFACT_DOMAIN:-}" ]; then
    configure_codeartifact
  # S3 configuration (S3 bucket URL should start with s3://)
  elif [[ "${PUBLISH_URL:-}" == "s3://"* ]]; then
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

# CodeArtifact's Basic-auth token expires within 12h, so it is minted at runtime and
# refreshed before every batch; the same token reaches the build through
# maven/settings-codeartifact.xml and gradle/init-codeartifact.gradle, which both read
# ${CODEARTIFACT_AUTH_TOKEN}.
configure_codeartifact() {
  if [ -z "${PUBLISH_URL:-}" ]; then
    die "PUBLISH_URL must point at the CodeArtifact Maven endpoint when CODEARTIFACT_DOMAIN is set (e.g. https://<domain>-<owner>.d.codeartifact.<region>.amazonaws.com/maven/<repository>/)"
  fi
  if [[ "${PUBLISH_URL}" != "https://"* && "${PUBLISH_URL}" != "http://"* ]]; then
    die "PUBLISH_URL must be the CodeArtifact Maven HTTPS endpoint, not '${PUBLISH_URL}'. Unset CODEARTIFACT_DOMAIN to use S3/Artifactory instead."
  fi
  info "Configuring AWS CodeArtifact Maven repository: ${PUBLISH_URL}"

  # The domain owner (12-digit account id) and region are embedded in the CodeArtifact
  # host (<domain>-<owner>.d.codeartifact.<region>.amazonaws.com). Derive them so the
  # token is always minted against the right account/region even when not set explicitly
  # (the caller's default account/region is often wrong for a central artifacts account).
  local host="${PUBLISH_URL#*://}"; host="${host%%/*}"
  if [[ "$host" =~ -([0-9]{12})\.d\.codeartifact\.([a-z0-9-]+)\. ]]; then
    export CODEARTIFACT_DOMAIN_OWNER="${CODEARTIFACT_DOMAIN_OWNER:-${BASH_REMATCH[1]}}"
    export CODEARTIFACT_REGION="${CODEARTIFACT_REGION:-${BASH_REMATCH[2]}}"
  fi

  # Register the Maven settings at runtime, only when CodeArtifact is selected: its catch-all
  # mirror reads ${env.PUBLISH_URL}, so baking it in would break Maven builds in a
  # non-CodeArtifact run of the same image. A user-provided /root/.m2/settings.xml (the
  # "Custom Maven Settings" Dockerfile section) takes precedence.
  if [ ! -f /root/.m2/settings.xml ] && [ -f /app/maven/settings-codeartifact.xml ]; then
    mod config build maven settings edit /app/maven/settings-codeartifact.xml
  fi

  if [ ! -f /root/.m2/settings.xml ] && [ ! -f /app/maven/settings-codeartifact.xml ] && [ ! -f /app/gradle/init-codeartifact.gradle ]; then
    info "WARNING: CodeArtifact is configured for publishing, but no build dependency wiring was found. Uncomment the CodeArtifact build-tool lines in the Dockerfile so dependencies resolve from CodeArtifact rather than public repositories."
  fi

  # The token is refreshed per batch, so anything that does not batch (org mode, or the
  # default single-batch run) mints it only once and risks a build/publish past its expiry.
  if [ -n "${ORGANIZATION:-}" ]; then
    info "WARNING: org mode mints the CodeArtifact token once for the whole org. A build/publish that runs past the token lifetime will fail; raise CODEARTIFACT_TOKEN_DURATION or split the org if it is large."
  elif [[ "${BATCH_SIZE:-0}" -le 0 ]]; then
    info "WARNING: CodeArtifact tokens expire within 12h and are refreshed once per batch. Set BATCH_SIZE so each batch completes inside the token lifetime for long runs."
  fi

  refresh_codeartifact_token || die "Unable to configure the CodeArtifact publish target"
}

# No-op when CodeArtifact is not in use, so it is safe to call unconditionally before each
# batch. Returns non-zero rather than aborting, so a transient failure mid-run does not
# discard the remaining batches.
refresh_codeartifact_token() {
  [ -n "${CODEARTIFACT_DOMAIN:-}" ] || return 0

  info "Refreshing AWS CodeArtifact authorization token"

  local get_token_cmd=(aws codeartifact get-authorization-token
    --domain "${CODEARTIFACT_DOMAIN}"
    --query authorizationToken --output text)
  if [ -n "${CODEARTIFACT_DOMAIN_OWNER:-}" ]; then
    get_token_cmd+=(--domain-owner "${CODEARTIFACT_DOMAIN_OWNER}")
  fi
  if [ -n "${CODEARTIFACT_REGION:-}" ]; then
    get_token_cmd+=(--region "${CODEARTIFACT_REGION}")
  fi
  if [ -n "${CODEARTIFACT_TOKEN_DURATION:-}" ]; then
    get_token_cmd+=(--duration-seconds "${CODEARTIFACT_TOKEN_DURATION}")
  fi

  local token
  if ! token=$("${get_token_cmd[@]}"); then
    info "Failed to obtain a CodeArtifact authorization token (check that the AWS CLI is installed and IAM permissions / CODEARTIFACT_* settings are correct)"
    return 1
  fi
  if [ -z "$token" ] || [ "$token" = "None" ]; then
    info "CodeArtifact returned an empty authorization token"
    return 1
  fi

  # CodeArtifact's Basic-auth username is always "aws".
  if ! mod config lsts artifacts maven edit "${PUBLISH_URL}" --user aws --password "$token"; then
    info "Failed to apply the CodeArtifact token to the publish configuration"
    return 1
  fi

  # Exported only after the publish config accepted the token, so the build and the publish
  # step never end up on different tokens.
  export CODEARTIFACT_AUTH_TOKEN="$token"
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
  mod log syncs add "$clone_dir" "$DATA_DIR/syncs.zip" --last-sync

  # Refreshed after the (potentially long) clone and right before the build/publish that use
  # it, so the token can't expire mid-batch.
  refresh_codeartifact_token || info "Token refresh failed; continuing with the existing token"

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

  # CodeArtifact's Maven endpoint rejects the non-Maven log artifact paths, so skip the
  # upload rather than issue a PUT that always 400s. Logs stay in the local log.zip/syncs.zip.
  if [ -n "${CODEARTIFACT_DOMAIN:-}" ]; then
    info "Skipping build-log upload: AWS CodeArtifact does not accept non-Maven log artifacts"
    return 0
  fi

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
    log_response=$(curl -s -S --insecure -w "\n%{http_code}" -u "$PUBLISH_USER":"$PUBLISH_PASSWORD" -X PUT "$logs_url" -T "$DATA_DIR/log.zip" 2>&1)
    log_http_code=$(echo "$log_response" | tail -1)
    log_body=$(echo "$log_response" | sed '$d')
    if [[ "$log_http_code" -ge 200 && "$log_http_code" -lt 300 ]]; then
      info "Successfully published logs (HTTP $log_http_code)"
    else
      info "Failed to publish logs (HTTP $log_http_code): $log_body"
    fi

    # Upload sync logs (if they exist)
    if [ -f "$DATA_DIR/syncs.zip" ]; then
      sync_logs_url=$PUBLISH_URL/io/moderne/ingest-sync-log/$index/$timestamp/ingest-sync-log-cli-$timestamp-$index.zip
      info "Uploading sync logs to $sync_logs_url"
      sync_response=$(curl -s -S --insecure -w "\n%{http_code}" -u "$PUBLISH_USER":"$PUBLISH_PASSWORD" -X PUT "$sync_logs_url" -T "$DATA_DIR/syncs.zip" 2>&1)
      sync_http_code=$(echo "$sync_response" | tail -1)
      sync_body=$(echo "$sync_response" | sed '$d')
      if [[ "$sync_http_code" -ge 200 && "$sync_http_code" -lt 300 ]]; then
        info "Successfully published sync logs (HTTP $sync_http_code)"
      else
        info "Failed to publish sync logs (HTTP $sync_http_code): $sync_body"
      fi
    fi
  elif [[ -n "${PUBLISH_TOKEN:-}" ]]; then
    logs_url=$PUBLISH_URL/io/moderne/ingest-log/$index/$timestamp/ingest-log-cli-$timestamp-$index.zip
    info "Uploading logs to $logs_url"
    log_response=$(curl -s -S --insecure -w "\n%{http_code}" -H "Authorization: Bearer $PUBLISH_TOKEN" -X PUT "$logs_url" -T "$DATA_DIR/log.zip" 2>&1)
    log_http_code=$(echo "$log_response" | tail -1)
    log_body=$(echo "$log_response" | sed '$d')
    if [[ "$log_http_code" -ge 200 && "$log_http_code" -lt 300 ]]; then
      info "Successfully published logs (HTTP $log_http_code)"
    else
      info "Failed to publish logs (HTTP $log_http_code): $log_body"
    fi

    # Upload sync logs (if they exist)
    if [ -f "$DATA_DIR/syncs.zip" ]; then
      sync_logs_url=$PUBLISH_URL/io/moderne/ingest-sync-log/$index/$timestamp/ingest-sync-log-cli-$timestamp-$index.zip
      info "Uploading sync logs to $sync_logs_url"
      sync_response=$(curl -s -S --insecure -w "\n%{http_code}" -H "Authorization: Bearer $PUBLISH_TOKEN" -X PUT "$sync_logs_url" -T "$DATA_DIR/syncs.zip" 2>&1)
      sync_http_code=$(echo "$sync_response" | tail -1)
      sync_body=$(echo "$sync_response" | sed '$d')
      if [[ "$sync_http_code" -ge 200 && "$sync_http_code" -lt 300 ]]; then
        info "Successfully published sync logs (HTTP $sync_http_code)"
      else
        info "Failed to publish sync logs (HTTP $sync_http_code): $sync_body"
      fi
    fi
  else
    info "No log publishing credentials provided"
  fi
}

main "$@"
