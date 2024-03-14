#!/bin/bash

echo "Running the mass recipe run with the following parameters: $*"

recipe_arguments=()
csv_file="repos.csv"
recipe=""
organization=""
index=0

for arg in "$@"; do
  recipe_arguments+=("$arg")
done

for arg in "$@"
do
  if [[ "$arg" == --recipe=* ]]; then
    recipe="${recipe_arguments[index]}"
  elif [[ "$arg" == --recipe ]]; then
    recipe="${recipe_arguments[index+1]}"
  elif [ "$arg" == "--organization" ]; then
    organization="${recipe_arguments[index+1]}"
    unset 'recipe_arguments[index]'
    unset 'recipe_arguments[index+1]'
  elif [ "$arg" == "-P" ]; then
    recipe_arguments[index+1]="\"${recipe_arguments[index+1]}\""
  fi
  index=$((index+1))
done

function printArgs() {
  echo "csv_file: $csv_file"
  echo "recipe: $recipe"
  echo "organization: $organization"
  echo "recipe_arguments: ${recipe_arguments[*]}"
}


function start_supervisord() {
  /usr/bin/supervisord --loglevel=error --directory=/tmp --configuration=/etc/supervisord.conf > /dev/null 2>&1 &
}


function install_recipe() {
  if [ -z "$recipe" ]; then
    if ! mod config recipes moderne sync; then 
      echo "Failed to sync the recipes"
      exit 1
    fi
  else
    # split the recipe name on `.` and use the last part as the recipe name
    recipe_name=$(echo "$recipe" | rev | cut -d'.' -f1 | rev)
    if ! mod config recipes moderne install "$recipe_name"; then
      echo "Failed to install the recipe"
      exit 1
    fi
  fi
}


function split_and_verify_csv() {
  rm -f repos-*

  partition_size=10
  header=$(head -n 1 "$csv_file")

  split -l "$partition_size" "$csv_file" repos-

  for file in repos-*
  do
    if [ "$(head -n 1 "$file")" != "$header" ]; then
      echo "$header" | cat - "$file" > temp && mv temp "$file"
    fi
  done
}


function publish_log() {
  if [ -z "$PUBLISH_USER" ] || [ -z "$PUBLISH_PASSWORD" ] || [ -z "$PUBLISH_URL" ]; then
    echo "No log publishing credentials provided"
  else
    log_version=$(date '+%Y%m%d%H%M%S')
    curl --insecure -u "$PUBLISH_USER":"$PUBLISH_PASSWORD" -X PUT \
      "$PUBLISH_URL/io/moderne/ingest-log/$log_version/ingest-log-$log_version.zip" \
      -T log.zip
  fi
}


function build_and_run_recipe_from_csv() {
  split_and_verify_csv

  for file in repos-*
  do
    partition_name=$(echo "$file" | cut -d'-' -f2)

    if ! mod git clone csv "$partition_name" "$file"  --filter=tree:0; then
      continue
    fi

    build_run_and_log "$partition_name"
  done

  publish_log
}


function build_and_run_recipe_from_organization() {
  partition_name=$organization
  
  mod git clone moderne "$partition_name" "$organization"
  
  build_run_and_log "$partition_name"
}

function build_run_and_log() {
  local partition_name=$1
  mod build "./$partition_name"

  bash -c "mod run ./$partition_name ${recipe_arguments[*]}"
  
  cleanup "$partition_name"
  publish_log
}

function cleanup() {
  if [ -d "./$1" ]; then
    rm -rf "./$1"
  fi
}



function main() {
  start_supervisord
  install_recipe

  if [ -n "$organization" ]; then
    echo "Running recipe on organization: $organization"
    build_and_run_recipe_from_organization
  elif [ -n "$csv_file" ] && [ -f "$csv_file" ]; then
    echo "Running recipe on csv file: $csv_file"
    build_and_run_recipe_from_csv
  else 
    echo "No organization or csv file was provided"
    exit 1
  fi
}

main