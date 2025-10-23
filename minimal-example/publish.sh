#!/bin/bash

set -o nounset
set -o pipefail

if [ -n "${REPOS_CSV_URL:-}" ]; then
    echo "Downloading repos.csv from ${REPOS_CSV_URL}"
    curl -f -o repos.csv "${REPOS_CSV_URL}"
fi

if [ $# -eq 0 ]; then
    echo "No repository file supplied. Please provide the path to the csv file."
    exit 1
fi

MONITOR_PID="monitor.pid"
SOURCE_CSV=""
START_INDEX=""
END_INDEX=""

export NO_COLOR=1

info() {
    if [[ -n "$START_INDEX" && -n "$END_INDEX" ]]; then
        printf "[%d-%d] %s\n" "$START_INDEX" "$END_INDEX" "$1"
    else
        printf "%s\n" "$1"
    fi
}

die() {
    if [[ -n "$START_INDEX" && -n "$END_INDEX" ]]; then
        printf "[%d-%d] %s\n" "$START_INDEX" "$END_INDEX" "$1" >&2
    else
        printf "%s\n" "$1" >&2
    fi
    exit 1
}

main() {
    SOURCE_CSV=$1
    shift

    while [[ $# -ne 0 ]]; do
        arg="$1"
        case "$arg" in
            --end)
                END_INDEX="$2"
                ;;
            --start)
                START_INDEX="$2"
                ;;
            *)
                die "Invalid option: $arg"
                ;;
        esac
        shift 2
    done

    ingest_repos
}

ingest_repos() {
    prepare_environment
    start_monitoring
    select_repositories "$SOURCE_CSV"

    partition_name=$(date +"%Y-%m-%d-%H-%M")

    if ! build_and_upload_repos "$partition_name" "$DATA_DIR/selected-repos.csv"; then
        info "Error building and uploading repositories"
    else
        info "Successfully built and uploaded repositories"
    fi

    send_logs
    stop_monitoring
}

prepare_environment() {
    info "Preparing environment"
    mkdir -p "$DATA_DIR"
    rm -rf "${DATA_DIR:?}"/*
    mkdir -p "$HOME/.moderne/cli/metrics/"
    rm -rf "$HOME/.moderne/cli/metrics"/*
}

start_monitoring() {
    info "Starting monitoring"
    nohup mod monitor --port 8080 > /dev/null 2>&1 &
    echo $! > "$DATA_DIR/$MONITOR_PID"
}

stop_monitoring() {
    info "Cleaning up monitoring"
    if [ -f "$DATA_DIR/$MONITOR_PID" ]; then
        kill -9 $(cat "$DATA_DIR/$MONITOR_PID") 2>/dev/null || true
        rm "$DATA_DIR/$MONITOR_PID"
    fi
}

select_repositories() {
    local csv_file=$1

    if [ ! -f "$csv_file" ]; then
        die "File $csv_file does not exist"
    fi

    if [[ -n "$START_INDEX" && -n "$END_INDEX" ]]; then
        info "Selecting repositories from $csv_file starting at $START_INDEX and ending at $END_INDEX"

        header=$(head -n 1 "$csv_file")
        selected_lines=$(tail -n +2 "$csv_file" | sed -n "${START_INDEX},${END_INDEX}p")

        ( echo "$header"; echo "$selected_lines" ) > "$DATA_DIR/selected-repos.csv"
    else
        info "Selected all repositories from $csv_file"
        cp "$csv_file" "$DATA_DIR/selected-repos.csv"
    fi
}

build_and_upload_repos() {
    local clone_dir="$DATA_DIR/$1"
    local partition_file=$2
    info "Building and uploading repositories into $clone_dir from $partition_file"

    export NO_COLOR=true
    export TERM=dumb

    mod git sync csv "$clone_dir" "$partition_file" --with-sources

    timeout 2700 mod build "$clone_dir" --no-download
    ret=$?
    if [ $ret -eq 124 ]; then
        printf "\n* Build timed out after 45 minutes\n\n"
    fi

    mod publish "$clone_dir"
    mod log builds add "$clone_dir" "$DATA_DIR/log.zip" --last-build
    return $ret
}

send_logs() {
    local index_label
    if [[ -n "$START_INDEX" && -n "$END_INDEX" ]]; then
        index_label="$START_INDEX-$END_INDEX"
    else
        index_label="full"
    fi

    local timestamp=$(date +"%Y%m%d%H%M")

    if [[ -n "$PUBLISH_USER" && -n "$PUBLISH_PASSWORD" ]]; then
        logs_url=$PUBLISH_URL/io/moderne/ingest-log/$index_label/$timestamp/ingest-log-cli-$timestamp-$index_label.zip
        info "Uploading logs to $logs_url"
        if ! curl -s -S --insecure -u "$PUBLISH_USER":"$PUBLISH_PASSWORD" -X PUT "$logs_url" -T "$DATA_DIR/log.zip"; then
            info "Failed to publish logs"
        fi
    else
        info "No log publishing credentials provided"
    fi
}

main "$@"
