# Multi-platform scalability examples

## Problem

The `3-scalability/` stage only covers AWS Batch. Customers on GCP or Azure have no reference implementation and must reverse-engineer the pattern from the AWS example. Additionally, some customers attempt to deploy on Kubernetes, which has known issues with resource-intensive LST builds (CPU throttling, OOM, debugging derailment).

## Solution

Add GCP Batch and Azure Batch examples alongside the existing AWS Batch example, all under `3-scalability/`. Each example is a self-contained, production-ready deployment with full Terraform IaC. A new top-level README explains the shared architecture pattern and why VM-based batch services are recommended over Kubernetes.

## Architecture

All three platforms implement the same pattern:

1. **Scheduled trigger** (weekly/daily cron) starts the chunk job
2. **Chunk job** reads `repos.csv`, calculates partitions, submits N processor jobs
3. **Processor jobs** each process a slice of the CSV (`--start N --end M`) using `publish.sh`
4. **Workers shut down** when their slice is complete; compute scales to zero
5. **Next trigger** repeats the cycle

`publish.sh` is shared across all platforms — it's already platform-agnostic and is NOT duplicated into platform subdirectories. Each platform's Docker image uses the same `publish.sh` from the repo root. Only the IaC and `chunk.sh` vary per cloud.

## Directory structure

```
3-scalability/
├── README.md                          # Platform overview, comparison, K8s recommendation
├── aws-batch/
│   ├── README.md                      # AWS-specific guide (migrated from current 3-scalability/)
│   ├── TROUBLESHOOTING.md             # AWS-specific troubleshooting (migrated)
│   ├── chunk.sh                       # Uses `aws batch submit-job`
│   └── terraform/
│       ├── main.tf
│       ├── variables.tf
│       └── terraform.tfvars.example   # New: example tfvars for consistency
├── gcp-batch/
│   ├── README.md                      # GCP-specific guide
│   ├── chunk.sh                       # Uses `gcloud batch jobs submit`
│   └── terraform/
│       ├── main.tf
│       ├── variables.tf
│       └── terraform.tfvars.example
└── azure-batch/
    ├── README.md                      # Azure-specific guide
    ├── chunk.sh                       # Uses `az batch task create --json-file`
    └── terraform/
        ├── main.tf
        ├── variables.tf
        └── terraform.tfvars.example
```

## Platform mapping

### AWS Batch (existing, migrated into aws-batch/)

No functional changes. Content moves from `3-scalability/` into `3-scalability/aws-batch/`. A `terraform.tfvars.example` is extracted from the README examples for consistency with the other platforms.

| Component | Implementation |
|---|---|
| Compute | EC2 instances (m6a.xlarge), managed compute environment |
| Job orchestration | AWS Batch job queue, array jobs |
| Scheduling | EventBridge Scheduler (cron) |
| Secrets | AWS Secrets Manager, injected as env vars |
| IAM | Chunk task role, processor task role, scheduler role, instance profile |
| Logging | CloudWatch Logs (7-day retention) |
| Storage | S3 (IAM-based) or Maven/Artifactory (credentials) |
| Volumes | 64 GB gp3 EBS (encrypted) |

### GCP Batch (new)

| Component | Implementation |
|---|---|
| Compute | Compute Engine VMs (e2-standard-4 or n2-standard-4), allocation policy |
| Job orchestration | Task groups, `BATCH_TASK_INDEX` for partitioning |
| Scheduling | Cloud Scheduler → Cloud Workflows → Batch API |
| Secrets | Google Secret Manager, mounted as env vars |
| IAM | Service accounts + IAM bindings (chunk SA, processor SA, scheduler SA) |
| Logging | Cloud Logging (default) |
| Storage | Maven/Artifactory (recommended), or GCS via S3-compatible interop (optional) |
| Volumes | Persistent Disk (pd-ssd) |

**Terraform resources**: `google_batch_job`, `google_service_account`, `google_secret_manager_secret`, `google_cloud_scheduler_job`, `google_workflows_workflow`, `google_compute_network`/`google_compute_firewall`, IAM bindings.

**Scheduling pattern**: Cloud Scheduler cannot directly submit GCP Batch jobs — it needs an intermediary. The recommended pattern is Cloud Scheduler → Cloud Workflows → Batch API. The Workflow definition calls the Batch API to create the job. This is documented by Google as the standard approach.

**chunk.sh**: Submits a job via `gcloud batch jobs submit` with a JSON spec. Sets `taskCount = ceil(total_repos / chunk_size)`. Each task reads `BATCH_TASK_INDEX` and `BATCH_TASK_COUNT` to derive `--start`/`--end`.

**Storage options**:
- Maven/Artifactory: Recommended primary option. Works as-is with `PUBLISH_URL`, `PUBLISH_USER`, `PUBLISH_PASSWORD`/`PUBLISH_TOKEN`.
- GCS: Optional. Use the S3-compatible interop endpoint (`storage.googleapis.com`) with HMAC keys. `publish.sh` uses `s3://` URL with `S3_ENDPOINT` pointing to GCS interop. Note: GCS interop has limitations (multipart upload differences, HMAC key auth instead of service account). Needs verification during implementation.

**CSV download in chunk.sh**: Uses `gcloud storage cp` for `gs://` URLs (replacing AWS's `aws s3 cp` for `s3://` URLs).

**Container registry**: Artifact Registry (replaces Container Registry). README includes `docker push` instructions for Artifact Registry.

### Azure Batch (new)

| Component | Implementation |
|---|---|
| Compute | Azure VMs (Standard_D4s_v5), auto-scale pool |
| Job orchestration | Batch account, pool, job, task collection with sequential task IDs |
| Scheduling | Azure Automation runbook + schedule |
| Secrets | Azure Key Vault, accessed via Managed Identity |
| IAM | Managed Identity + RBAC role assignments |
| Logging | Azure Monitor Logs |
| Storage | Maven/Artifactory (primary), Azure Blob via MinIO gateway (optional) |
| Volumes | Managed Disks |

**Terraform resources**: `azurerm_batch_account`, `azurerm_batch_pool` (auto-scale formula, `container_configuration` with `container_image_names` and optional `container_registries`), `azurerm_batch_job`, `azurerm_key_vault`, `azurerm_key_vault_secret`, `azurerm_automation_account`, `azurerm_automation_schedule`, `azurerm_automation_runbook`, `azurerm_user_assigned_identity`, RBAC assignments, VNet/NSG.

**Scheduling**: Azure Automation with a runbook schedule (`azurerm_automation_schedule` + `azurerm_automation_runbook`). Simpler than Logic Apps for a cron-triggered batch job — just a PowerShell/Python runbook that calls `az batch job create`.

**chunk.sh**: Uses `az batch task create --json-file tasks.json` with a task collection to submit all N tasks in a single call (not looping individual CLI calls). Each task gets a sequential ID (0, 1, 2, ...) used to derive `--start`/`--end`.

**Storage options**:
- Maven/Artifactory: Primary recommended option. Works as-is.
- Azure Blob: No native S3-compatible API. Customers can deploy MinIO as an S3 gateway in front of Azure Blob, but this adds complexity. Documented as optional.

**CSV download in chunk.sh**: Uses `az storage blob download` for Azure Blob URLs (replacing AWS's `aws s3 cp` for `s3://` URLs).

**Container registry**: Azure Container Registry (ACR). README includes `az acr login` and `docker push` instructions. Pool configuration references ACR with managed identity.

## Top-level 3-scalability/README.md

Contains:

1. **Platform comparison table** — quick decision matrix mapping cloud provider to subdirectory
2. **Architecture overview** — the shared chunk → parallel processors → scale to zero pattern
3. **Why VM-based batch, not Kubernetes** — real-world issues observed:
   - K8s doesn't guarantee pods get requested CPU/memory; LST builds get throttled or evicted
   - Debugging derailment: time spent on K8s infra instead of getting value from Moderne
   - Cost inefficiency: concrete example of 10x cost savings moving from K8s cluster to large VM
   - OOM incidents with 400+ projects on K8s
   - Mysterious build hangs due to memory pressure in K8s pods
   - Container environment quirks (random uid/gid, JDK user.home bugs)
4. **Prerequisites** — shared components (Docker image, `publish.sh`, `repos.csv`)
5. **Links** to each platform's subdirectory README

## What doesn't change

- `publish.sh` — already platform-agnostic via `--start`/`--end` args, stays at repo root
- `Dockerfile` / `Dockerfile.fips` — shared container image
- `repos.csv` format — same across all platforms
- `diagnostics/` — platform-independent
- Stages 1 (`1-quickstart/`) and 2 (`2-observability/`) — untouched

## Migration plan

1. Move existing `3-scalability/` contents into `3-scalability/aws-batch/`
2. Create `terraform.tfvars.example` for AWS (extracted from README examples)
3. Fix existing `chunk.sh` bug: line 20 uses `$csv_file` instead of `$local_csv_file` for `wc -l` — if the CSV is an S3 URL, `cat "s3://..."` fails
4. Update any internal references/paths in the moved files
5. Create `3-scalability/README.md` (platform overview)
6. Create `3-scalability/gcp-batch/` with Terraform, chunk.sh, README
7. Create `3-scalability/azure-batch/` with Terraform, chunk.sh, README
8. Update root `README.md` to reflect the new structure

## Open questions

- **GCS S3 interop**: Need to verify that the Moderne CLI / `publish.sh` works correctly with GCS's S3-compatible endpoint and HMAC keys. If not, Maven/Artifactory becomes the only GCS option.
- **Azure Batch container configuration**: Azure Batch pool nodes support containers via `container_configuration`. The `azurerm_batch_pool` resource supports `container_image_names` and `container_registries`. Needs confirmation during implementation but is likely straightforward.
- **GCP machine type**: `e2-standard-4` (4 vCPU, 16 GB) maps to the AWS `m6a.xlarge`. For consistent performance on CPU-intensive LST builds, `n2-standard-4` may be preferable since N2 provides sustained-use discounts and more consistent performance. Decide during implementation.
