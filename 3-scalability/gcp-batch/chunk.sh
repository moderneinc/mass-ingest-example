#!/bin/bash
set -euo pipefail

# GCP Batch sets BATCH_TASK_INDEX (0-based) and BATCH_TASK_COUNT.
# CHUNK_SIZE and CSV_URL are passed via environment from the Terraform/Workflow config.

csv_url="${CSV_URL}"
chunk_size="${CHUNK_SIZE:-10}"
task_index="${BATCH_TASK_INDEX:-0}"

# Download CSV from URL
if [[ "$csv_url" == "http://"* || "$csv_url" == "https://"* ]]; then
  curl -sfL "$csv_url" -o repos.csv
  csv_file="repos.csv"
elif [[ -f "$csv_url" ]]; then
  csv_file="$csv_url"
else
  printf "CSV not found: %s\n" "$csv_url"
  exit 1
fi

start=$(( task_index * chunk_size + 1 ))
end=$(( start + chunk_size ))

printf "Task %d: processing repos %d to %d\n" "$task_index" "$start" "$end"

exec ./publish.sh "$csv_file" --start "$start" --end "$end"
