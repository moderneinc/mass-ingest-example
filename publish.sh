#!/bin/bash

set -o nounset   # abort on unbound variable
set -o pipefail  # don't hide errors within pipes

info() {
  printf '%s\n' "$1"
}

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

main() {
  : "${DATA_DIR:?DATA_DIR must be set}"
  mod publish --help | grep -q -- --sync-csv ||
    die "This Moderne CLI has no 'mod publish --sync-csv'; rebuild the image with a release that ships it"

  # turn off color output and cursor movement in the CLI
  export NO_COLOR=true TERM=dumb

  configure_credentials
  # The Dockerfile symlinks the CLI's type-table store here so it lands on the data volume
  mkdir -p "$DATA_DIR/.types"

  if [ "${DIAGNOSE:-}" = "true" ]; then
    exec mod doctor "$DATA_DIR" --sync-csv
  fi
  if [ "${DIAGNOSE_ON_START:-}" = "true" ]; then
    mod doctor "$DATA_DIR" --sync-csv || true
  fi

  start_monitoring
  publish
  local ret=$?
  stop_monitoring
  exit "$ret"
}

# Works through the store's repos.csv one repository at a time: clone, build, publish, record
# in the store's repos-lock.csv, delete. Rows whose lock entry already matches are skipped.
publish() {
  local cmd=(mod publish "$DATA_DIR" --sync-csv)
  if [ -n "${ORGANIZATION:-}" ]; then
    cmd+=(--organization "$ORGANIZATION")
  fi
  if [ -n "${PARALLEL:-}" ]; then
    cmd+=(--parallel "$PARALLEL")
  fi
  info "Running: ${cmd[*]}"

  # Backgrounded so TERM/INT (docker stop, a batch timeout) can be forwarded: the CLI then
  # flushes the central repos-lock.csv from its shutdown hook before exiting.
  "${cmd[@]}" &
  local pid=$! ret
  trap 'kill -TERM "$pid" 2>/dev/null' TERM INT
  wait "$pid"
  ret=$?
  while kill -0 "$pid" 2>/dev/null; do  # wait returns early when a trapped signal arrives
    wait "$pid"
    ret=$?
  done
  trap - TERM INT
  return "$ret"
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
    echo -e "${GIT_CREDENTIALS}" > "$HOME/.git-credentials"
    # Register the store helper so git consults the file, independent of image-level config.
    git config --global credential.helper "store --file=$HOME/.git-credentials"
  fi

  if [ -n "${GIT_SSH_CREDENTIALS:-}" ]; then
    mkdir -p "$HOME/.ssh"
    echo -e "${GIT_SSH_CREDENTIALS}" > "$HOME/.ssh/private-key"
    chmod 600 "$HOME/.ssh/private-key"
    # Point git at the key and accept unknown host keys so the clone does not block.
    git config --global core.sshCommand "ssh -i $HOME/.ssh/private-key -o StrictHostKeyChecking=accept-new"
  fi

  # Configure artifact repository
  if [[ "${PUBLISH_URL:-}" == "s3://"* ]]; then
    info "Configuring S3 artifact repository: ${PUBLISH_URL}"
    local s3_cmd=(mod config lsts artifacts s3 edit "${PUBLISH_URL}")
    if [ -n "${S3_ENDPOINT:-}" ]; then
      s3_cmd+=(--endpoint-url "${S3_ENDPOINT}")
    fi
    if [ -n "${S3_PROFILE:-}" ]; then
      s3_cmd+=(--profile "${S3_PROFILE}")
    fi
    if [ -n "${S3_REGION:-}" ]; then
      s3_cmd+=(--region "${S3_REGION}")
    fi
    info "Running: ${s3_cmd[*]}"
    "${s3_cmd[@]}" || die "Failed to configure the S3 artifact repository; publishing would fall through to whatever was configured before"
  elif [ -n "${PUBLISH_URL:-}" ] && [ -n "${PUBLISH_USER:-}" ] && [ -n "${PUBLISH_PASSWORD:-}" ]; then
    info "Configuring Maven artifact repository with username/password"
    mod config lsts artifacts maven add "${PUBLISH_URL}" --user "${PUBLISH_USER}" --password "${PUBLISH_PASSWORD}"
  elif [ -n "${PUBLISH_URL:-}" ] && [ -n "${PUBLISH_TOKEN:-}" ]; then
    info "Configuring Artifactory artifact repository with API token"
    mod config lsts artifacts artifactory add "${PUBLISH_URL}" --jfrog-api-token "${PUBLISH_TOKEN}"
  else
    die "PUBLISH_URL must be supplied via environment variable. For S3, use s3:// URL format. For Maven/Artifactory, also provide PUBLISH_USER/PUBLISH_PASSWORD or PUBLISH_TOKEN"
  fi
}

start_monitoring() {
  info "Starting monitoring"
  nohup mod monitor --port 8080 > /dev/null 2>&1 &
  MONITOR_PID=$!
}

stop_monitoring() {
  info "Cleaning up monitoring"
  kill "$MONITOR_PID" 2>/dev/null
}

main "$@"
