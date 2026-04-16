#!/bin/bash
set -euo pipefail

# Worker script for GCP Batch tasks. Unlike AWS chunk.sh (which orchestrates
# by submitting N jobs), this script runs inside each parallel task — the
# Cloud Workflow handles orchestration.
#
# GCP Batch sets BATCH_TASK_INDEX (0-based) and BATCH_TASK_COUNT.
# CHUNK_SIZE and CSV_FILE are passed via environment from the Terraform/Workflow config.

csv_file="${1:-$CSV_FILE}"
chunk_size="${CHUNK_SIZE:-10}"
task_index="${BATCH_TASK_INDEX:-0}"

# Download CSV if it's a URL
if [[ "$csv_file" == "http://"* || "$csv_file" == "https://"* ]]; then
  curl -sfL "$csv_file" -o repos.csv
  csv_file="repos.csv"
elif [[ ! -f "$csv_file" ]]; then
  printf "CSV not found: %s\n" "$csv_file"
  exit 1
fi

total_lines=$(( $(wc -l < "$csv_file") - 1 ))
if [[ $total_lines -le 0 ]]; then
  printf "No repositories found in %s\n" "$csv_file"
  exit 0
fi

start=$(( task_index * chunk_size + 1 ))
end=$(( start + chunk_size ))

printf "Task %d: processing repos %d to %d\n" "$task_index" "$start" "$end"

exec ./publish.sh "$csv_file" --start "$start" --end "$end"
