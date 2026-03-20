#!/bin/bash
set -euo pipefail

main() {
  csv_file=$1
  chunk_size=${2:-10}

  if [[ "$csv_file" == "https://"*".blob.core.windows.net/"* ]]; then
    az storage blob download --blob-url "$csv_file" --file "repos.csv" --auth-mode login
    local_csv_file="repos.csv"
  elif [[ "$csv_file" == "http://"* || "$csv_file" == "https://"* ]]; then
    curl "$csv_file" -o "repos.csv"
    local_csv_file="repos.csv"
  elif [[ -f "$csv_file" ]]; then
    local_csv_file="$csv_file"
  else
    printf "File %s does not exist\n" "$1"
    exit 1
  fi

  total_lines=$(( $(wc -l < "$local_csv_file") - 1 ))

  if [[ $total_lines -le 0 ]]; then
    printf "No repositories found in %s\n" "$csv_file"
    exit 0
  fi

  total_tasks=$(( (total_lines + chunk_size - 1) / chunk_size ))

  printf "Submitting %d processor tasks (%d repos, chunk size %d)\n" "$total_tasks" "$total_lines" "$chunk_size"

  for (( i=0; i<total_tasks; i++ )); do
    start=$(( i * chunk_size + 1 ))
    end=$(( start + chunk_size ))

    cat > /tmp/task-${i}.json <<EOF
{
  "id": "processor-${i}",
  "commandLine": "./publish.sh ${local_csv_file} --start ${start} --end ${end}",
  "containerSettings": {
    "imageName": "${IMAGE}"
  }
}
EOF

    az batch task create \
      --job-id "$BATCH_JOB_ID" \
      --json-file /tmp/task-${i}.json
  done

  printf "Submitted %d processor tasks to job %s\n" "$total_tasks" "$BATCH_JOB_ID"
}

main "$@"
