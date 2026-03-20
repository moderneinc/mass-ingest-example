#!/bin/bash
set -euo pipefail

# GCP Batch sets BATCH_TASK_INDEX (0-based) and BATCH_TASK_COUNT.
# CHUNK_SIZE is passed via environment from the Terraform/Workflow config.

csv_file="${1:-$CSV_FILE}"
chunk_size="${CHUNK_SIZE:-10}"
task_index="${BATCH_TASK_INDEX:-0}"

start=$(( task_index * chunk_size + 1 ))
end=$(( start + chunk_size ))

printf "Task %d: processing repos %d to %d\n" "$task_index" "$start" "$end"

exec ./publish.sh "$csv_file" --start "$start" --end "$end"
