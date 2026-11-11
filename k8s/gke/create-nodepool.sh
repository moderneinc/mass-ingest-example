#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID to the cluster project ID}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME to an existing GKE Standard cluster}"
: "${LOCATION:?Set LOCATION to the cluster region or zone}"

# Use a dedicated node identity when supplied; otherwise GKE uses its default.
set --
if [[ -n "${NODE_SERVICE_ACCOUNT:-}" ]]; then
  set -- --service-account="$NODE_SERVICE_ACCOUNT" --scopes=cloud-platform
fi

# Total limits apply across all zones; match MAX_NODES to the desired concurrency.
# The taint keeps unrelated workloads off this pool.
gcloud container node-pools create mass-ingest \
  --project="$PROJECT_ID" \
  --cluster="$CLUSTER_NAME" \
  --location="$LOCATION" \
  --machine-type=e2-standard-4 \
  --image-type=COS_CONTAINERD \
  --disk-type=pd-balanced \
  --disk-size=300 \
  --spot \
  --num-nodes=0 \
  --enable-autoscaling \
  --total-min-nodes=0 \
  --total-max-nodes="${MAX_NODES:-8}" \
  --location-policy=ANY \
  --workload-metadata=GKE_METADATA \
  --node-taints=mass-ingest=true:NoSchedule \
  --quiet \
  "$@"
