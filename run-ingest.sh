#!/usr/bin/env bash

docker run --rm -it \
    -p 7001:3000 -p 7080:8080 -p 7090:9090 \
    -w /app \
    -v "${PWD}/docker-entrypoint-publish.sh:/app/docker-entrypoint-publish.sh" \
    --entrypoint /app/docker-entrypoint-publish.sh \
    moderne-mass-ingest:latest "$@"
