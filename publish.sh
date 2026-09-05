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
  start_codeartifact_refresher
  publish
  local ret=$?
  finalize_codeartifact_versions || info "Some CodeArtifact versions could not be finalized"
  stop_codeartifact_refresher
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
  if [ -n "${CODEARTIFACT_DOMAIN:-}" ]; then
    configure_codeartifact
  elif [[ "${PUBLISH_URL:-}" == "s3://"* ]]; then
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

# CodeArtifact's Basic-auth token expires within 12h, so it is minted at runtime and refreshed
# in the background while the CLI runs (see start_codeartifact_refresher).
configure_codeartifact() {
  if [ -z "${PUBLISH_URL:-}" ]; then
    die "PUBLISH_URL must point at the CodeArtifact Maven endpoint when CODEARTIFACT_DOMAIN is set (e.g. https://<domain>-<owner>.d.codeartifact.<region>.amazonaws.com/maven/<repository>/)"
  fi
  if [[ "${PUBLISH_URL}" != "https://"* && "${PUBLISH_URL}" != "http://"* ]]; then
    die "PUBLISH_URL must be the CodeArtifact Maven HTTPS endpoint, not '${PUBLISH_URL}'. Unset CODEARTIFACT_DOMAIN to use S3/Artifactory instead."
  fi
  info "Configuring AWS CodeArtifact Maven repository: ${PUBLISH_URL}"

  # The domain owner (12-digit account id) and region are embedded in the CodeArtifact
  # host (<domain>-<owner>.d.codeartifact.<region>.amazonaws.com).
  local host="${PUBLISH_URL#*://}"; host="${host%%/*}"
  if [[ "$host" =~ -([0-9]{12})\.d\.codeartifact\.([a-z0-9-]+)\. ]]; then
    export CODEARTIFACT_DOMAIN_OWNER="${CODEARTIFACT_DOMAIN_OWNER:-${BASH_REMATCH[1]}}"
    export CODEARTIFACT_REGION="${CODEARTIFACT_REGION:-${BASH_REMATCH[2]}}"
  fi

  refresh_codeartifact_token || die "Unable to configure the CodeArtifact publish target"

  # Only registered on a CodeArtifact run: the catch-all mirror would break Maven builds in a
  # non-CodeArtifact run of the same image. A user-provided $HOME/.m2/settings.xml (the
  # "Custom Maven settings" Dockerfile section) takes precedence.
  if [ ! -f "$HOME/.m2/settings.xml" ] && [ -f "$HOME/.m2/settings-codeartifact.xml" ]; then
    mod config build maven settings edit "$HOME/.m2/settings-codeartifact.xml"
  fi

  if [ ! -f "$HOME/.m2/settings.xml" ] && [ ! -f /app/maven/settings-codeartifact.xml ] && [ ! -f /app/gradle/init-codeartifact.gradle ]; then
    info "WARNING: CodeArtifact is configured for publishing, but no build dependency configuration was found. Uncomment the CodeArtifact build-tool lines in the Dockerfile so dependencies resolve from CodeArtifact rather than public repositories."
  fi
}

# Mints a token and writes it everywhere the running CLI and the build tools read it from
# disk, because an environment variable cannot reach an already-running process.
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

  if ! mod config lsts artifacts maven add "${PUBLISH_URL}" --user aws --password "$token"; then
    info "Failed to apply the CodeArtifact token to the publish configuration"
    return 1
  fi

  (
    umask 077
    # gradle/init-codeartifact.gradle reads the token file; Maven gets it rendered into its settings
    printf '%s' "$token" > "$HOME/.codeartifact-token"
    if [ -f /app/maven/settings-codeartifact.xml ]; then
      mkdir -p "$HOME/.m2"
      sed "s|\${env.CODEARTIFACT_AUTH_TOKEN}|$token|" /app/maven/settings-codeartifact.xml > "$HOME/.m2/settings-codeartifact.xml"
    fi
  )
  export CODEARTIFACT_AUTH_TOKEN="$token"
}

start_codeartifact_refresher() {
  [ -n "${CODEARTIFACT_DOMAIN:-}" ] || return 0

  local lifetime="${CODEARTIFACT_TOKEN_DURATION:-43200}"
  # 0 ties the token to the role session, whose minimum is 15 minutes
  [ "$lifetime" -gt 0 ] || lifetime=900
  (
    next=$(( lifetime * 3 / 4 ))
    while sleep "$next"; do
      if refresh_codeartifact_token; then
        next=$(( lifetime * 3 / 4 ))
      else
        info "CodeArtifact token refresh failed; retrying in 5 minutes"
        next=300
      fi
    done
  ) &
  REFRESHER_PID=$!
}

stop_codeartifact_refresher() {
  if [ -n "${REFRESHER_PID:-}" ]; then
    kill "$REFRESHER_PID" 2>/dev/null
  fi
}

# CodeArtifact marks versions uploaded without a maven-metadata.xml as Unfinished, and its
# Maven endpoint returns 404 for every asset of an Unfinished version.
# see https://docs.aws.amazon.com/codeartifact/latest/ug/maven-curl.html
# No-op when CodeArtifact is not in use; a failure leaves the versions hidden but recoverable
# (rerun `aws codeartifact update-package-versions-status` manually), so callers only warn.
finalize_codeartifact_versions() {
  [ -n "${CODEARTIFACT_DOMAIN:-}" ] || return 0

  info "Finalizing CodeArtifact package versions to Published status"

  # <domain>-<owner>.d.codeartifact.<region>.amazonaws.com/maven/<repository>/
  local repository="${PUBLISH_URL##*/maven/}"
  repository="${repository%%/*}"
  if [ -z "$repository" ]; then
    info "Could not derive the CodeArtifact repository name from PUBLISH_URL '${PUBLISH_URL}'"
    return 1
  fi

  local aws_args=(--domain "${CODEARTIFACT_DOMAIN}" --repository "$repository" --format maven)
  if [ -n "${CODEARTIFACT_DOMAIN_OWNER:-}" ]; then
    aws_args+=(--domain-owner "${CODEARTIFACT_DOMAIN_OWNER}")
  fi
  if [ -n "${CODEARTIFACT_REGION:-}" ]; then
    aws_args+=(--region "${CODEARTIFACT_REGION}")
  fi

  # No local csv survives the run, so the coordinates come from the repository itself
  local packages
  packages=$(aws codeartifact list-packages "${aws_args[@]}" \
    --query 'packages[].[namespace,package]' --output text) || return 1

  local failed=0
  local namespace package versions
  while read -r namespace package; do
    [ -n "$package" ] || continue
    # shellcheck disable=SC2016 # backticks are JMESPath literals, not command substitution
    versions=$(aws codeartifact list-package-versions "${aws_args[@]}" \
      --namespace "$namespace" --package "$package" --status Unfinished \
      --query 'versions[?origin.originType==`INTERNAL`].version' --output text 2>/dev/null) || continue
    if [ -z "$versions" ] || [ "$versions" = "None" ]; then
      continue
    fi
    # shellcheck disable=SC2086 # versions is a tab-separated list that must word-split
    if aws codeartifact update-package-versions-status "${aws_args[@]}" \
        --namespace "$namespace" --package "$package" --versions $versions \
        --target-status Published > /dev/null; then
      info "Published CodeArtifact version(s) of ${namespace}:${package}"
    else
      info "Failed to finalize ${namespace}:${package} version(s) ${versions}; they stay hidden from the Maven endpoint until published manually"
      failed=1
    fi
  done <<< "$packages"

  return $failed
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
