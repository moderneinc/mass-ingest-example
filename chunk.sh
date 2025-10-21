#!/bin/bash

main() {
  csv_file=$1
  chunk_size=${2:-10}

  if [ ! -f "$1" ]; then
    printf "File %s does not exist\n" "$1"
    exit 1
  fi

  total_lines=$(( $(cat "$csv_file" | wc -l) - 1 ))

  for start in $(seq 1 $(( chunk_size + 1 )) $total_lines); do
    aws batch submit-job --job-name "$JOB_NAME" --job-queue "$JOB_QUEUE" --job-definition "$JOB_DEFINITION" --parameters "Start=$start,End=$(( start + chunk_size))"
  done
}

main "$@"
