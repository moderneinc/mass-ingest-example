#!/bin/sh
# Runs one mass ingest on this machine: a container per shard, all at once.
set -eu

SHARDS=${SHARDS:-8}
IMAGE=${IMAGE:-mass-ingest}
ENV_FILE=${ENV_FILE:-mass-ingest.env}

for i in $(seq 1 "$SHARDS"); do
  docker run -d --init --name "mass-ingest-$i" --env-file "$ENV_FILE" \
    --memory 12g --stop-timeout 120 \
    -v "$HOME/.git-credentials:/home/moderne/.git-credentials:ro" \
    "$IMAGE" mod publish /var/moderne/ws --sync-csv --shard "$i/$SHARDS"
done

for i in $(seq 1 "$SHARDS"); do
  echo "shard $i exited $(docker wait "mass-ingest-$i")"
  docker rm "mass-ingest-$i" > /dev/null
done
