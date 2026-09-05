#!/bin/bash
set -euo pipefail

# One Batch task per organization: GCP sets BATCH_TASK_INDEX (0-based) and Terraform passes
# the comma-separated ORGANIZATIONS. With no organizations, the single task ingests everything.
IFS=',' read -r -a organizations <<< "${ORGANIZATIONS:-}"
if [ "${#organizations[@]}" -gt 0 ]; then
  export ORGANIZATION="${organizations[${BATCH_TASK_INDEX:-0}]}"
  printf 'Task %s: organization %s\n' "${BATCH_TASK_INDEX:-0}" "$ORGANIZATION"
fi

exec ./publish.sh
