#!/bin/bash
set -euo pipefail

# Azure Batch chunk task: splits repos.csv and adds one task.sh processor task per partition to its own job (see README).

BATCH_API_VERSION="2025-06-01"
BATCH_RESOURCE="https://batch.core.windows.net/"
MAX_TASKS_PER_REQUEST=100

info() { printf 'chunk: %s\n' "$1"; }
die() { printf 'chunk: %s\n' "$1" >&2; exit 1; }

imds_token() {
  local url="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$1"
  if [ -n "${AZURE_CLIENT_ID:-}" ]; then
    url="${url}&client_id=${AZURE_CLIENT_ID}"
  fi
  curl -sS -f -H 'Metadata: true' "$url" | jq -r '.access_token // empty'
}

# batch_request METHOD PATH BODY_FILE -> prints the response body, fails on non-200
batch_request() {
  local method=$1 path=$2 body_file=$3 response http_code body
  response=$(curl -sS -X "$method" \
    -H "Authorization: Bearer $BATCH_TOKEN" \
    -H 'Content-Type: application/json; odata=minimalmetadata' \
    --data-binary @"$body_file" \
    -w '\n%{http_code}' \
    "${AZ_BATCH_ACCOUNT_URL%/}${path}?api-version=${BATCH_API_VERSION}")
  http_code=${response##*$'\n'}
  body=${response%$'\n'*}
  if [ "$http_code" != "200" ]; then
    die "$method $path failed (HTTP $http_code): $body"
  fi
  printf '%s' "$body"
}

main() {
  csv_file=${1:?usage: chunk.sh <repos.csv path or https URL> [chunk_size]}
  chunk_size=${2:-10}
  [[ "$chunk_size" =~ ^[1-9][0-9]*$ ]] || die "chunk_size must be a positive integer, got '$chunk_size'"
  max_wall_clock_time=${TASK_MAX_WALL_CLOCK_TIME:-PT4H}
  max_retry_count=${TASK_MAX_RETRY_COUNT:-0}
  : "${IMAGE:?IMAGE must be set to the processor container image}"
  : "${AZ_BATCH_ACCOUNT_URL:?AZ_BATCH_ACCOUNT_URL is set by Azure Batch; run this script as a Batch task}"
  : "${AZ_BATCH_JOB_ID:?AZ_BATCH_JOB_ID is set by Azure Batch; run this script as a Batch task}"

  if [[ "$csv_file" == "http://"* || "$csv_file" == "https://"* ]]; then
    curl -fsSL "$csv_file" -o repos.csv || die "Could not download $csv_file"
    local_csv_file="repos.csv"
  elif [[ -f "$csv_file" ]]; then
    local_csv_file="$csv_file"
  else
    die "File $csv_file does not exist"
  fi

  total_lines=$(( $(wc -l < "$local_csv_file") - 1 ))
  if [[ $total_lines -le 0 ]]; then
    info "No repositories found in $csv_file"
    exit 0
  fi
  total_tasks=$(( (total_lines + chunk_size - 1) / chunk_size ))
  info "Submitting $total_tasks processor tasks ($total_lines repos, chunk size $chunk_size) to job $AZ_BATCH_JOB_ID"

  BATCH_TOKEN=$(imds_token "$BATCH_RESOURCE") || die "Could not get a Batch token from IMDS for identity ${AZURE_CLIENT_ID:-<default>}"
  [ -n "$BATCH_TOKEN" ] || die "IMDS returned an empty Batch token"

  # Only non-secret settings are forwarded; task.sh reads credentials from Key Vault itself.
  env_settings="[]"
  for var_name in MODERNE_TENANT PUBLISH_URL KEY_VAULT_URI AZURE_CLIENT_ID; do
    if [ -n "${!var_name:-}" ]; then
      env_settings=$(jq -c --arg name "$var_name" --arg value "${!var_name}" '. + [{name: $name, value: $value}]' <<<"$env_settings")
    fi
  done

  request_file=$(mktemp)
  trap 'rm -f "$request_file"' EXIT

  for (( first=0; first<total_tasks; first+=MAX_TASKS_PER_REQUEST )); do
    count=$(( total_tasks - first < MAX_TASKS_PER_REQUEST ? total_tasks - first : MAX_TASKS_PER_REQUEST ))
    jq -n \
      --arg csv "$csv_file" \
      --arg image "$IMAGE" \
      --argjson env "$env_settings" \
      --argjson first "$first" \
      --argjson count "$count" \
      --argjson chunk "$chunk_size" \
      --arg max_wall_clock_time "$max_wall_clock_time" \
      --argjson max_retry_count "$max_retry_count" \
      '{
        value: [ range($first; $first + $count) as $n |
          {
            id: "processor-\($n)",
            commandLine: "/app/task.sh \($csv) --start \($n * $chunk + 1) --end \(($n + 1) * $chunk + 1)",
            containerSettings: { imageName: $image, containerRunOptions: "--workdir /app" },
            userIdentity: { autoUser: { scope: "pool", elevationLevel: "admin" } },
            constraints: { maxWallClockTime: $max_wall_clock_time, maxTaskRetryCount: $max_retry_count },
            environmentSettings: $env
          }
        ]
      }' > "$request_file"

    response=$(batch_request POST "/jobs/${AZ_BATCH_JOB_ID}/addtaskcollection" "$request_file")
    failed=$(jq -r '[.value[] | select(.status != "success") | "\(.taskId): \(.error.code // "unknown") \(.error.message.value // "")"] | join("; ")' <<<"$response")
    if [ -n "$failed" ]; then
      die "Some processor tasks were not added: $failed"
    fi
    info "Added processor tasks $first to $(( first + count - 1 ))"
  done

  # Terminate the job once every processor task completes, so jobs do not count against the active job quota.
  printf '{"onAllTasksComplete":"terminatejob"}' > "$request_file"
  batch_request PATCH "/jobs/${AZ_BATCH_JOB_ID}" "$request_file" > /dev/null

  info "Submitted $total_tasks processor tasks to job $AZ_BATCH_JOB_ID"
}

main "$@"
