#!/bin/sh

docker run -i -p 3000:3000 \
  -v $(pwd)/grafana-datasource.yml:/etc/grafana/provisioning/datasources/grafana-datasource.yml \
  -v $(pwd)/grafana-dashboard.yml:/etc/grafana/provisioning/dashboards/grafana-dashboard.yml \
  -v $(pwd)/grafana-build-dashboard.json:/etc/grafana/dashboards/build.json \
  -v $(pwd)/grafana-run-dashboard.json:/etc/grafana/dashboards/run.json \
  grafana/grafana:latest
