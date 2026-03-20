# Multi-platform scalability implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GCP Batch and Azure Batch scalability examples alongside the existing AWS Batch example, restructuring `3-scalability/` into per-platform subdirectories.

**Architecture:** All three platforms implement the same chunk → parallel processors → scale-to-zero pattern. `publish.sh` (repo root) is shared — only IaC (`main.tf`, `variables.tf`), `chunk.sh`, and READMEs vary per cloud. Each platform uses its native VM-based batch service, secret store, scheduler, and IAM model.

**Tech Stack:** Terraform (AWS, Google, AzureRM providers), Bash, GCP Batch, Azure Batch, Cloud Scheduler, Cloud Workflows, Azure Automation

**Spec:** `docs/superpowers/specs/2026-03-20-multi-platform-scalability-design.md`

---

## File map

### Moved (no functional changes unless noted)

| Current path | New path | Notes |
|---|---|---|
| `3-scalability/README.md` | `3-scalability/aws-batch/README.md` | Update relative paths |
| `3-scalability/TROUBLESHOOTING.md` | `3-scalability/aws-batch/TROUBLESHOOTING.md` | No changes |
| `3-scalability/chunk.sh` | `3-scalability/aws-batch/chunk.sh` | Fix `$csv_file` → `$local_csv_file` bug on line 20 |
| `3-scalability/terraform/main.tf` | `3-scalability/aws-batch/terraform/main.tf` | No changes |
| `3-scalability/terraform/variables.tf` | `3-scalability/aws-batch/terraform/variables.tf` | No changes |

### New files

| Path | Responsibility |
|---|---|
| `3-scalability/README.md` | Platform overview, comparison table, K8s recommendation, links to subdirectories |
| `3-scalability/aws-batch/terraform/terraform.tfvars.example` | Example tfvars extracted from README |
| `3-scalability/gcp-batch/README.md` | GCP-specific deployment guide |
| `3-scalability/gcp-batch/chunk.sh` | Computes `--start`/`--end` from `BATCH_TASK_INDEX` and runs `publish.sh` (entrypoint wrapper) |
| `3-scalability/gcp-batch/terraform/main.tf` | GCP Batch infra: batch job, service accounts, secrets, scheduler, workflows, networking |
| `3-scalability/gcp-batch/terraform/variables.tf` | GCP-specific variables |
| `3-scalability/gcp-batch/terraform/terraform.tfvars.example` | Example GCP tfvars |
| `3-scalability/azure-batch/README.md` | Azure-specific deployment guide |
| `3-scalability/azure-batch/chunk.sh` | CSV download from Azure Blob + task submission via `az batch task create --json-file` |
| `3-scalability/azure-batch/terraform/main.tf` | Azure Batch infra: batch account, pool, job, key vault, automation, identity, networking |
| `3-scalability/azure-batch/terraform/variables.tf` | Azure-specific variables |
| `3-scalability/azure-batch/terraform/terraform.tfvars.example` | Example Azure tfvars |

### Modified

| Path | Change |
|---|---|
| `README.md` (root) | Update `3-scalability` section to mention multi-cloud, update directory tree |

---

## Task 1: migrate AWS Batch into subdirectory

Move existing `3-scalability/` contents into `3-scalability/aws-batch/`, fix the chunk.sh bug, and create `terraform.tfvars.example`.

**Files:**
- Move: `3-scalability/chunk.sh` → `3-scalability/aws-batch/chunk.sh`
- Move: `3-scalability/README.md` → `3-scalability/aws-batch/README.md`
- Move: `3-scalability/TROUBLESHOOTING.md` → `3-scalability/aws-batch/TROUBLESHOOTING.md`
- Move: `3-scalability/terraform/` → `3-scalability/aws-batch/terraform/`
- Create: `3-scalability/aws-batch/terraform/terraform.tfvars.example`

- [ ] **Step 1: Create aws-batch subdirectory and move files**

```bash
cd 3-scalability
mkdir -p aws-batch/terraform
git mv chunk.sh aws-batch/chunk.sh
git mv TROUBLESHOOTING.md aws-batch/TROUBLESHOOTING.md
git mv README.md aws-batch/README.md
git mv terraform/main.tf aws-batch/terraform/main.tf
git mv terraform/variables.tf aws-batch/terraform/variables.tf
rmdir terraform
```

- [ ] **Step 2: Fix chunk.sh bugs**

In `3-scalability/aws-batch/chunk.sh`, fix two bugs:

**Bug 1 (line 20):** Uses `$csv_file` instead of `$local_csv_file` for `wc -l` — if the CSV is an S3 URL, `cat` fails.

**Bug 2 (line 22):** The `seq` step is `$(( chunk_size + 1 ))` which should be `$chunk_size` — the +1 causes an off-by-one error, skipping one repo between chunks.

Also add `set -euo pipefail` at the top for production safety.

The corrected `chunk.sh`:
```bash
#!/bin/bash
set -euo pipefail

main() {
  csv_file=$1
  chunk_size=${2:-10}

  if [[ "$csv_file" == "s3://"* ]]; then
    aws s3 cp "$csv_file" "repos.csv"
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

  for start in $(seq 1 "$chunk_size" "$total_lines"); do
    aws batch submit-job --job-name "$JOB_NAME" --job-queue "$JOB_QUEUE" --job-definition "$JOB_DEFINITION" --parameters "Start=$start,End=$(( start + chunk_size))"
  done
}

main "$@"
```

- [ ] **Step 3: Update relative paths in aws-batch/README.md**

The README references `chunk.sh#L11` and `../publish.sh#L40`. Since the README moved one directory deeper:
- `chunk.sh#L11` → stays the same (chunk.sh is in the same directory)
- `../publish.sh` → `../../publish.sh`
- `../repos.csv` → `../../repos.csv`
- `./TROUBLESHOOTING.md` → stays the same
- `terraform/main.tf` → stays the same

Search for all `../` references and add one more `../` level.

- [ ] **Step 4: Create terraform.tfvars.example**

Create `3-scalability/aws-batch/terraform/terraform.tfvars.example` — extract the example from the README's "Configure Terraform variables" section:

```hcl
name       = "mass-ingest"
vpc_id     = "vpc-xxxxx"
subnet_ids = ["subnet-xxxxx", "subnet-yyyyy"]

image_registry = "<account-id>.dkr.ecr.<region>.amazonaws.com/mass-ingest"
image_tag      = "latest"

moderne_tenant = "https://app.moderne.io"
moderne_token  = "arn:aws:secretsmanager:<region>:<account>:secret:mass-ingest/moderne-token"

# Storage — choose one option:

# Option A: S3
moderne_publish_url    = "s3://your-bucket"
moderne_s3_bucket_name = "your-bucket"
# moderne_s3_region    = "us-west-2"
# moderne_s3_endpoint  = "https://minio.example.com"

# Option B: Maven/Artifactory
# moderne_publish_url      = "https://artifactory.example.com/artifactory/moderne-ingest/"
# moderne_publish_user     = "arn:aws:secretsmanager:<region>:<account>:secret:mass-ingest/publishing:username::"
# moderne_publish_password = "arn:aws:secretsmanager:<region>:<account>:secret:mass-ingest/publishing:password::"
# moderne_publish_token    = "arn:aws:secretsmanager:<region>:<account>:secret:mass-ingest/publishing:token::"

# Git authentication — choose one:
# moderne_git_credentials = "arn:aws:secretsmanager:<region>:<account>:secret:mass-ingest/git-credentials"
# moderne_ssh_credentials = "arn:aws:secretsmanager:<region>:<account>:secret:mass-ingest/ssh-private-key"

# Ingestion settings
# ingest_csv_file  = "repos.csv"
# ingest_chunk_size = 10

default_tags = {
  Environment = "production"
  Project     = "mass-ingest"
}
```

- [ ] **Step 5: Commit**

```bash
git add 3-scalability/aws-batch/
git commit -m "Move AWS Batch example into 3-scalability/aws-batch/

Restructure for multi-platform support. Fix chunk.sh bug where
\$csv_file was used instead of \$local_csv_file for wc -l.
Add terraform.tfvars.example for consistency."
```

---

## Task 2: create top-level 3-scalability/README.md

The entry point that explains the shared architecture, compares platforms, and warns about Kubernetes.

**Files:**
- Create: `3-scalability/README.md`

- [ ] **Step 1: Write the platform overview README**

Create `3-scalability/README.md` with the following structure:

```markdown
# Scalability: scale to production

Production-scale deployment using cloud-native batch services for parallel repository processing. Choose the example that matches your cloud provider.

## Choose your platform

| Cloud provider | Service | Compute | Guide |
|---|---|---|---|
| **AWS** | [AWS Batch](https://aws.amazon.com/batch/) | EC2 instances | [aws-batch/](./aws-batch/) |
| **GCP** | [Google Cloud Batch](https://cloud.google.com/batch) | Compute Engine VMs | [gcp-batch/](./gcp-batch/) |
| **Azure** | [Azure Batch](https://azure.microsoft.com/en-us/products/batch) | Azure VMs | [azure-batch/](./azure-batch/) |

All three examples implement the same architecture — only the infrastructure-as-code and cloud-specific tooling differ.

## Architecture

All platforms follow the same pattern:

1. **Scheduled trigger** (daily/weekly cron) starts the chunk job
2. **Chunk job** reads `repos.csv`, calculates partitions, submits N processor jobs
3. **Processor jobs** each process a slice of the CSV (`--start N --end M`) using the shared `publish.sh` script
4. **Workers shut down** when their slice is complete — compute scales to zero
5. **Next trigger** repeats the cycle

```
┌─────────────┐     ┌───────────┐     ┌──────────────┐
│  Scheduler  │────>│ Chunk Job │────>│ Processor #1 │──> publish.sh --start 1  --end 10
│  (cron)     │     │           │     │ Processor #2 │──> publish.sh --start 11 --end 20
└─────────────┘     └───────────┘     │ Processor #3 │──> publish.sh --start 21 --end 30
                                      │     ...      │
                                      │ Processor #N │──> publish.sh --start X  --end Y
                                      └──────────────┘
```

### Shared components

These files are shared across all platforms and live at the repository root:

- `publish.sh` — main ingestion script, already supports `--start`/`--end` for partitioning
- `Dockerfile` / `Dockerfile.fips` — container image definition
- `repos.csv` — repository list
- `diagnostics/` — pre-ingestion validation

## Why VM-based batch services (not Kubernetes)

We recommend VM-based batch services (AWS Batch, GCP Batch, Azure Batch) over Kubernetes for mass ingestion. This recommendation is based on real-world experience across multiple customer deployments.

**LST builds are resource-intensive.** Building Lossless Semantic Trees involves cloning repositories, resolving dependencies, and running full Java builds. This requires dedicated CPU and memory — the kind of workload where resource contention causes hard-to-diagnose failures.

### Issues observed with Kubernetes deployments

- **Unreliable resource guarantees** — Kubernetes does not always give pods the CPU and memory they request. Under resource pressure, LST builds get throttled or evicted, causing flaky ingestion that appears to work sometimes and fail unpredictably.
- **Debugging derailment** — Kubernetes deployments tend to derail into debugging K8s infrastructure (scheduling, networking, storage) instead of getting value from Moderne. The operational overhead is significant.
- **Cost inefficiency** — Kubernetes clusters typically consume only ~15% of available CPU. In one case, moving a comparable workload from a 2-node K8s cluster to a single large VM reduced costs by 10x.
- **Out-of-memory incidents** — Customers have run out of memory running mass ingestion on K8s with as few as 400 projects, even with resource requests configured.
- **Mysterious build hangs** — Repositories that build successfully on a developer machine can hang indefinitely in a K8s pod due to memory pressure that is invisible to the build process.
- **Container environment quirks** — Random uid/gid assignment in some K8s setups breaks filesystem operations. JDKs 8–18 have a `user.home` bug in containerized environments that causes directories named `?`.

### Why VM-based batch works better

- **Dedicated resources** — each job gets a full VM with guaranteed CPU and memory
- **No scheduling surprises** — no pod eviction, no CPU throttling, no noisy neighbors
- **Scale to zero** — all three services tear down VMs when jobs complete
- **Same container image** — you still use Docker containers, just on dedicated VMs
- **Simpler debugging** — when something goes wrong, you debug your build, not your orchestration platform

> **Note:** Some customers have successfully deployed mass ingestion on Kubernetes, but it required significant effort to tune resource limits, node affinity, and scheduling policies. If you must use Kubernetes, ensure each pod gets a dedicated node or use guaranteed QoS with generous resource limits.
```

- [ ] **Step 2: Commit**

```bash
git add 3-scalability/README.md
git commit -m "Add top-level scalability README with platform comparison

Explains the shared architecture pattern across AWS/GCP/Azure batch
services and documents why VM-based approaches are recommended over
Kubernetes based on real customer experiences."
```

---

## Task 3: create GCP Batch terraform

The complete Terraform configuration for GCP Batch.

**Files:**
- Create: `3-scalability/gcp-batch/terraform/main.tf`
- Create: `3-scalability/gcp-batch/terraform/variables.tf`
- Create: `3-scalability/gcp-batch/terraform/terraform.tfvars.example`

- [ ] **Step 1: Create variables.tf**

Create `3-scalability/gcp-batch/terraform/variables.tf`:

```hcl
variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "name" {
  type    = string
  default = "mass-ingest"
}

variable "network" {
  type        = string
  description = "VPC network name or self_link"
  default     = "default"
}

variable "subnetwork" {
  type        = string
  description = "VPC subnetwork name or self_link"
  default     = "default"
}

variable "image" {
  type        = string
  description = "Container image URL (e.g., us-docker.pkg.dev/project/repo/mass-ingest:latest)"
}

variable "machine_type" {
  type    = string
  default = "n2-standard-4"
}

variable "boot_disk_size_gb" {
  type    = number
  default = 64
}

variable "moderne_tenant" {
  type        = string
  description = "Moderne tenant URL (e.g., https://app.moderne.io)"
}

variable "moderne_token_secret" {
  type        = string
  description = "Secret Manager secret name for Moderne token"
  default     = "mass-ingest-moderne-token"
}

variable "git_credentials_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret name for git credentials (optional)"
}

variable "ssh_credentials_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret name for SSH private key (optional)"
}

variable "publish_url" {
  type        = string
  description = "Artifact repository URL (Maven/Artifactory URL or s3:// with S3_ENDPOINT for GCS interop)"
}

variable "publish_user_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret name for publish username (optional)"
}

variable "publish_password_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret name for publish password (optional)"
}

variable "publish_token_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret name for publish token (optional, alternative to user/password)"
}

variable "s3_endpoint" {
  type        = string
  default     = ""
  description = "S3-compatible endpoint for GCS interop (e.g., https://storage.googleapis.com)"
}

variable "s3_region" {
  type        = string
  default     = ""
  description = "S3 region for GCS interop (e.g., auto)"
}

variable "csv_file" {
  type    = string
  default = "repos.csv"
}

variable "chunk_size" {
  type    = number
  default = 10
}

variable "total_repos" {
  type        = number
  description = "Total number of repositories in repos.csv (excluding header). Used to calculate task count."
}

variable "schedule" {
  type        = string
  default     = "0 0 * * *"
  description = "Cron schedule for the batch job (default: daily at midnight UTC)"
}

variable "labels" {
  type = map(string)
  default = {
    environment = "production"
    managed-by  = "terraform"
  }
}
```

- [ ] **Step 2: Create main.tf**

Create `3-scalability/gcp-batch/terraform/main.tf`. This file defines:

1. **Provider and APIs** — enable required GCP APIs (batch, workflows, cloudscheduler, secretmanager)
2. **Service accounts** — processor SA (runs the batch tasks) and scheduler SA (invokes workflows)
3. **IAM bindings** — grant processor SA access to secrets, scheduler SA access to workflows
4. **Firewall rule** — allow metrics scraping on port 8080 from internal network
5. **Cloud Workflows** — workflow that creates a Batch job via the Batch API
6. **Cloud Scheduler** — cron trigger that executes the workflow
7. **Batch job template** — defined within the workflow YAML (GCP Batch jobs are created per-execution, not as standing resources)

Key implementation notes:
- **No separate chunk job.** Unlike AWS, the GCP Workflow handles chunking directly. The Workflow receives `total_repos` as a runtime argument (or from a Cloud Storage object), computes `taskCount = ceil(total_repos / chunk_size)`, and creates the processor Batch job with that many tasks. This avoids needing `gcloud` CLI in the container image.
- GCP Batch does not have a standing "job definition" like AWS. Instead, the Workflow contains the full job spec and creates a new job on each execution.
- Each task runs `chunk.sh` which is a simple entrypoint wrapper that computes `--start`/`--end` from `BATCH_TASK_INDEX` and `CHUNK_SIZE` environment variables, then calls `publish.sh`.
- Secrets are accessed via `secretmanager.googleapis.com` and mounted as environment variables using the `secretVariables` field in the task spec.

```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable required APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "batch.googleapis.com",
    "compute.googleapis.com",
    "workflows.googleapis.com",
    "cloudscheduler.googleapis.com",
    "secretmanager.googleapis.com",
    "logging.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# Service account for batch tasks (chunk + processor)
resource "google_service_account" "batch_task" {
  account_id   = "${var.name}-batch-task"
  display_name = "Mass Ingest Batch Task"
}

# Grant batch task SA access to secrets
resource "google_secret_manager_secret_iam_member" "moderne_token" {
  secret_id = var.moderne_token_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_secret_manager_secret_iam_member" "git_credentials" {
  count     = var.git_credentials_secret != "" ? 1 : 0
  secret_id = var.git_credentials_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_secret_manager_secret_iam_member" "ssh_credentials" {
  count     = var.ssh_credentials_secret != "" ? 1 : 0
  secret_id = var.ssh_credentials_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_secret_manager_secret_iam_member" "publish_user" {
  count     = var.publish_user_secret != "" ? 1 : 0
  secret_id = var.publish_user_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_secret_manager_secret_iam_member" "publish_password" {
  count     = var.publish_password_secret != "" ? 1 : 0
  secret_id = var.publish_password_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_secret_manager_secret_iam_member" "publish_token" {
  count     = var.publish_token_secret != "" ? 1 : 0
  secret_id = var.publish_token_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

# Grant batch task SA permission to submit batch jobs (for chunk.sh)
resource "google_project_iam_member" "batch_task_batch_agent" {
  project = var.project_id
  role    = "roles/batch.agentReporter"
  member  = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_project_iam_member" "batch_task_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.batch_task.email}"
}

# Service account for the scheduler to invoke workflows
resource "google_service_account" "scheduler" {
  account_id   = "${var.name}-scheduler"
  display_name = "Mass Ingest Scheduler"
}

resource "google_project_iam_member" "scheduler_workflows_invoker" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.scheduler.email}"
}

# Service account for workflows to submit batch jobs
resource "google_service_account" "workflow" {
  account_id   = "${var.name}-workflow"
  display_name = "Mass Ingest Workflow"
}

resource "google_project_iam_member" "workflow_batch_submitter" {
  project = var.project_id
  role    = "roles/batch.jobsEditor"
  member  = "serviceAccount:${google_service_account.workflow.email}"
}

resource "google_project_iam_member" "workflow_sa_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.workflow.email}"
}

# Firewall rule — allow metrics scraping on port 8080
resource "google_compute_firewall" "metrics" {
  name    = "${var.name}-metrics"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = ["10.0.0.0/8"]
  target_service_accounts = [google_service_account.batch_task.email]
}

# Workflow that creates and runs the chunk batch job
resource "google_workflows_workflow" "mass_ingest" {
  name            = var.name
  region          = var.region
  service_account = google_service_account.workflow.id

  source_contents = yamlencode({
    main = {
      params = ["args"]
      steps = [
        {
          init = {
            assign = [
              { totalRepos = "$${args.totalRepos}" },
              { taskCount = "$${int(math.ceil(totalRepos / ${var.chunk_size}))}" },
            ]
          }
        },
        {
          create_batch_job = {
            call = "googleapis.batch.v1.projects.locations.jobs.create"
            args = {
              parent = "projects/${var.project_id}/locations/${var.region}"
              jobId  = "${var.name}-$${sys.now()}"
              body = {
                taskGroups = [
                  {
                    taskCount   = "$${taskCount}"
                    parallelism = "$${taskCount}"
                    taskSpec = {
                      runnables = [
                        {
                          container = {
                            imageUri = var.image
                            entrypoint = "/bin/bash"
                            commands = ["-c", "./chunk.sh $${CSV_FILE}"]
                          }
                        }
                      ]
                      computeResource = {
                        cpuMilli  = 4000
                        memoryMib = 15360
                      }
                      maxRunDuration = "3600s"
                      environment = {
                        variables = merge(
                          {
                            MODERNE_TENANT = var.moderne_tenant
                            PUBLISH_URL    = var.publish_url
                            CSV_FILE       = var.csv_file
                            CHUNK_SIZE     = tostring(var.chunk_size)
                          },
                          var.s3_endpoint != "" ? { S3_ENDPOINT = var.s3_endpoint } : {},
                          var.s3_region != "" ? { S3_REGION = var.s3_region } : {},
                        )
                        secretVariables = merge(
                          {
                            MODERNE_TOKEN = "projects/${var.project_id}/secrets/${var.moderne_token_secret}/versions/latest"
                          },
                          var.git_credentials_secret != "" ? {
                            GIT_CREDENTIALS = "projects/${var.project_id}/secrets/${var.git_credentials_secret}/versions/latest"
                          } : {},
                          var.ssh_credentials_secret != "" ? {
                            GIT_SSH_CREDENTIALS = "projects/${var.project_id}/secrets/${var.ssh_credentials_secret}/versions/latest"
                          } : {},
                          var.publish_user_secret != "" ? {
                            PUBLISH_USER = "projects/${var.project_id}/secrets/${var.publish_user_secret}/versions/latest"
                          } : {},
                          var.publish_password_secret != "" ? {
                            PUBLISH_PASSWORD = "projects/${var.project_id}/secrets/${var.publish_password_secret}/versions/latest"
                          } : {},
                          var.publish_token_secret != "" ? {
                            PUBLISH_TOKEN = "projects/${var.project_id}/secrets/${var.publish_token_secret}/versions/latest"
                          } : {},
                        )
                      }
                    }
                  }
                ]
                allocationPolicy = {
                  instances = [
                    {
                      policy = {
                        machineType = var.machine_type
                        bootDisk = {
                          sizeGb = var.boot_disk_size_gb
                        }
                      }
                    }
                  ]
                  network = {
                    networkInterfaces = [
                      {
                        network    = "projects/${var.project_id}/global/networks/${var.network}"
                        subnetwork = "projects/${var.project_id}/regions/${var.region}/subnetworks/${var.subnetwork}"
                      }
                    ]
                  }
                  serviceAccount = {
                    email = google_service_account.batch_task.email
                  }
                }
                logsPolicy = {
                  destination = "CLOUD_LOGGING"
                }
                labels = var.labels
              }
            }
            result = "createResult"
          }
        },
        {
          return_result = {
            return = "$${createResult}"
          }
        }
      ]
    }
  })

  depends_on = [google_project_service.apis]
}

# Cloud Scheduler — triggers the workflow on a cron schedule
resource "google_cloud_scheduler_job" "trigger" {
  name      = "${var.name}-trigger"
  region    = var.region
  schedule  = var.schedule
  time_zone = "UTC"

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.mass_ingest.id}/executions"
    body        = base64encode(jsonencode({
      argument = jsonencode({ totalRepos = var.total_repos })
    }))
    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_project_service.apis]
}
```

Note: Unlike AWS, GCP does not use a separate chunk job. The Cloud Workflow handles the task count calculation and creates the Batch job directly with N parallel tasks. Each task runs `chunk.sh`, which is a simple entrypoint wrapper that computes `--start`/`--end` from `BATCH_TASK_INDEX` and `CHUNK_SIZE`, then calls `publish.sh`. The Cloud Scheduler passes `totalRepos` as a runtime argument — update this value when repos.csv changes, or use a workflow step to count lines from GCS before job creation.

**Important:** The `total_repos` variable must be set in `terraform.tfvars`. If repos.csv changes frequently, consider adding a Workflow step that reads the CSV from GCS and counts lines dynamically.

- [ ] **Step 3: Create terraform.tfvars.example**

Create `3-scalability/gcp-batch/terraform/terraform.tfvars.example`:

```hcl
project_id = "your-gcp-project-id"
region     = "us-central1"
name       = "mass-ingest"

network    = "default"
subnetwork = "default"

image = "us-docker.pkg.dev/your-project/mass-ingest/mass-ingest:latest"

machine_type = "n2-standard-4"

moderne_tenant       = "https://app.moderne.io"
moderne_token_secret = "mass-ingest-moderne-token"

# Storage — choose one option:

# Option A: Maven/Artifactory (recommended)
publish_url = "https://artifactory.example.com/artifactory/moderne-ingest/"
# publish_user_secret     = "mass-ingest-publish-user"
# publish_password_secret = "mass-ingest-publish-password"
# publish_token_secret    = "mass-ingest-publish-token"

# Option B: GCS via S3-compatible interop (optional)
# publish_url  = "s3://your-gcs-bucket"
# s3_endpoint  = "https://storage.googleapis.com"
# s3_region    = "auto"

# Git authentication — choose one:
# git_credentials_secret = "mass-ingest-git-credentials"
# ssh_credentials_secret = "mass-ingest-ssh-key"

# Ingestion settings
total_repos = 1000  # Number of repos in repos.csv (excluding header)
# csv_file    = "repos.csv"
# chunk_size  = 10
# schedule    = "0 0 * * *"
```

- [ ] **Step 4: Commit**

```bash
git add 3-scalability/gcp-batch/terraform/
git commit -m "Add GCP Batch Terraform configuration

Includes Batch job via Cloud Workflows, Cloud Scheduler trigger,
Secret Manager integration, service accounts with least-privilege
IAM, and firewall rules for metrics scraping."
```

---

## Task 4: create GCP Batch chunk.sh

A simple entrypoint wrapper that computes `--start`/`--end` from `BATCH_TASK_INDEX` and `CHUNK_SIZE`, then calls `publish.sh`. Unlike the AWS version, this does NOT submit jobs — the Cloud Workflow handles that.

**Files:**
- Create: `3-scalability/gcp-batch/chunk.sh`

- [ ] **Step 1: Write chunk.sh**

Create `3-scalability/gcp-batch/chunk.sh`:

```bash
#!/bin/bash
set -euo pipefail

# GCP Batch sets BATCH_TASK_INDEX (0-based) and BATCH_TASK_COUNT.
# CHUNK_SIZE is passed via environment from the Terraform/Workflow config.

csv_file="${1:-$CSV_FILE}"
chunk_size="${CHUNK_SIZE:-10}"
task_index="${BATCH_TASK_INDEX:-0}"

start=$(( task_index * chunk_size + 1 ))
end=$(( start + chunk_size ))

printf "Task %d: processing repos %d to %d\n" "$task_index" "$start" "$end"

exec ./publish.sh "$csv_file" --start "$start" --end "$end"
```

This is much simpler than the AWS chunk.sh because the Cloud Workflow handles task count calculation and job submission. Each GCP Batch task just needs to compute its range and delegate to `publish.sh`.

- [ ] **Step 2: Make executable**

```bash
chmod +x 3-scalability/gcp-batch/chunk.sh
```

- [ ] **Step 3: Commit**

```bash
git add 3-scalability/gcp-batch/chunk.sh
git commit -m "Add GCP Batch chunk.sh

Downloads CSV from GCS/HTTP, calculates partitions, and submits
processor batch job via gcloud with computed task count."
```

---

## Task 5: create GCP Batch README

**Files:**
- Create: `3-scalability/gcp-batch/README.md`

- [ ] **Step 1: Write the GCP README**

Model the structure after `3-scalability/aws-batch/README.md` but with GCP-specific instructions. Include:

1. **Overview** — same architecture description but referencing GCP Batch, Cloud Workflows, Cloud Scheduler
2. **Prerequisites** — GCP project, Terraform, Docker, `gcloud` CLI, Artifact Registry, repos.csv, storage option
3. **Quick start** steps:
   - Prepare repository list (same as AWS)
   - Build and push Docker image (Artifact Registry commands: `gcloud auth configure-docker`, `docker push`)
   - Store secrets in Google Secret Manager (`gcloud secrets create ...`)
   - Configure Terraform variables (reference `terraform.tfvars.example`)
   - Deploy infrastructure (`terraform init/plan/apply`)
   - Manual trigger (`gcloud workflows execute`)
4. **How it works** — chunk job, processor jobs, parallel execution (same concepts, GCP terminology)
5. **Configuration** — machine type, worker resources, schedule, partition size
6. **Monitoring** — Cloud Logging commands (`gcloud logging read`), Batch console
7. **Cost optimization** — Spot VMs (`provisioningModel: SPOT`), auto-scaling
8. **Troubleshooting** — GCP-specific issues (API not enabled, quota, IAM)
9. **Cleanup** — `terraform destroy`
10. **Storage options** — Maven/Artifactory (recommended) and GCS interop (optional)

- [ ] **Step 2: Commit**

```bash
git add 3-scalability/gcp-batch/README.md
git commit -m "Add GCP Batch deployment guide

Complete guide for deploying mass-ingest on GCP using Batch,
Cloud Workflows, Cloud Scheduler, and Secret Manager."
```

---

## Task 6: create Azure Batch terraform

**Files:**
- Create: `3-scalability/azure-batch/terraform/main.tf`
- Create: `3-scalability/azure-batch/terraform/variables.tf`
- Create: `3-scalability/azure-batch/terraform/terraform.tfvars.example`

- [ ] **Step 1: Create variables.tf**

Create `3-scalability/azure-batch/terraform/variables.tf`:

```hcl
variable "name" {
  type    = string
  default = "mass-ingest"
}

variable "resource_group_name" {
  type        = string
  description = "Azure resource group name"
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "vnet_name" {
  type        = string
  description = "Virtual network name"
}

variable "subnet_name" {
  type        = string
  description = "Subnet name for Batch pool nodes"
}

variable "nsg_name" {
  type        = string
  description = "Network Security Group name for the Batch subnet"
}

variable "image" {
  type        = string
  description = "Container image URL (e.g., myregistry.azurecr.io/mass-ingest:latest)"
}

variable "acr_name" {
  type        = string
  default     = ""
  description = "Azure Container Registry name (optional, for ACR authentication)"
}

variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

variable "max_nodes" {
  type    = number
  default = 64
}

variable "disk_size_gb" {
  type    = number
  default = 64
}

variable "moderne_tenant" {
  type        = string
  description = "Moderne tenant URL"
}

variable "key_vault_name" {
  type        = string
  description = "Key Vault name for storing secrets"
}

variable "publish_url" {
  type        = string
  description = "Artifact repository URL (Maven/Artifactory)"
}

variable "csv_file" {
  type    = string
  default = "repos.csv"
}

variable "chunk_size" {
  type    = number
  default = 10
}

variable "schedule" {
  type        = string
  default     = "0 0 * * *"
  description = "Cron schedule (default: daily at midnight UTC)"
}

variable "tags" {
  type = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
```

- [ ] **Step 2: Create main.tf**

Create `3-scalability/azure-batch/terraform/main.tf`. This file defines:

1. **Provider** — AzureRM
2. **Data sources** — existing resource group, VNet, subnet, Key Vault
3. **User Assigned Identity** — for Batch pool nodes to access Key Vault and ACR
4. **Batch Account** — the Azure Batch account
5. **Batch Pool** — auto-scale pool with container configuration, VM size, disk
6. **Automation Account** — for scheduling
7. **Automation Runbook** — PowerShell script that creates a Batch job and submits chunk task
8. **Automation Schedule** — cron trigger
9. **Key Vault access** — grant identity access to secrets
10. **NSG rule** — allow metrics scraping on port 8080

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
}

data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

data "azurerm_key_vault" "kv" {
  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

# User Assigned Identity for Batch pool nodes
resource "azurerm_user_assigned_identity" "batch" {
  name                = "${var.name}-batch-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Grant identity access to Key Vault secrets
resource "azurerm_key_vault_access_policy" "batch" {
  key_vault_id = data.azurerm_key_vault.kv.id
  tenant_id    = azurerm_user_assigned_identity.batch.tenant_id
  object_id    = azurerm_user_assigned_identity.batch.principal_id

  secret_permissions = ["Get", "List"]
}

# Grant identity access to ACR (if specified)
data "azurerm_container_registry" "acr" {
  count               = var.acr_name != "" ? 1 : 0
  name                = var.acr_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_role_assignment" "acr_pull" {
  count                = var.acr_name != "" ? 1 : 0
  scope                = data.azurerm_container_registry.acr[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.batch.principal_id
}

# Batch Account
resource "azurerm_batch_account" "batch" {
  name                                = replace(var.name, "-", "")
  resource_group_name                 = var.resource_group_name
  location                            = var.location
  pool_allocation_mode                = "BatchService"
  allowed_authentication_modes        = ["AAD"]

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.batch.id]
  }

  tags = var.tags
}

# Batch Pool with container support
resource "azurerm_batch_pool" "pool" {
  name                = "${var.name}-pool"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_batch_account.batch.name
  vm_size             = var.vm_size
  node_agent_sku_id   = "batch.node.ubuntu 22.04"

  auto_scale {
    evaluation_interval = "PT5M"
    formula             = <<-EOT
      $totalNodes = max($PendingTasks.GetSample(TimeInterval_Minute * 5, 0), $ActiveTasks.GetSample(TimeInterval_Minute * 5, 0));
      $targetNodes = min($totalNodes, ${var.max_nodes});
      $TargetDedicatedNodes = $targetNodes;
      $NodeDeallocationOption = taskcompletion;
    EOT
  }

  container_configuration {
    type                  = "DockerCompatible"
    container_image_names = [var.image]

    dynamic "container_registries" {
      for_each = var.acr_name != "" ? [1] : []
      content {
        registry_server           = data.azurerm_container_registry.acr[0].login_server
        user_assigned_identity_id = azurerm_user_assigned_identity.batch.id
      }
    }
  }

  storage_image_reference {
    publisher = "microsoft-azure-batch"
    offer     = "ubuntu-server-container"
    sku       = "22-04-lts"
    version   = "latest"
  }

  network_configuration {
    subnet_id = data.azurerm_subnet.subnet.id
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.batch.id]
  }

  task_scheduling_policy {
    node_fill_type = "Pack"
  }

  tags = var.tags
}

# NSG rule for metrics scraping
resource "azurerm_network_security_rule" "metrics" {
  name                        = "${var.name}-metrics"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8080"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = var.nsg_name
}

# Automation Account for scheduling
resource "azurerm_automation_account" "automation" {
  name                = "${var.name}-automation"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Basic"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.batch.id]
  }

  tags = var.tags
}

# Automation Runbook — creates a Batch job and submits chunk task
resource "azurerm_automation_runbook" "trigger" {
  name                    = "${var.name}-trigger"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.automation.name
  log_verbose             = false
  log_progress            = false
  runbook_type            = "PowerShell"

  content = <<-PS
    Connect-AzAccount -Identity

    $batchContext = Get-AzBatchAccount -AccountName "${azurerm_batch_account.batch.name}" -ResourceGroupName "${var.resource_group_name}"

    $jobId = "${var.name}-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-AzBatchJob -Id $jobId -PoolInformation (New-Object Microsoft.Azure.Commands.Batch.Models.PSPoolInformation -Property @{PoolId="${azurerm_batch_pool.pool.name}"}) -BatchContext $batchContext

    $taskSettings = New-Object Microsoft.Azure.Commands.Batch.Models.PSTaskContainerSettings -Property @{
      ImageName = "${var.image}"
    }

    $envVars = @(
      (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="BATCH_JOB_ID"; Value=$jobId}),
      (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="IMAGE"; Value="${var.image}"}),
      (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="MODERNE_TENANT"; Value="${var.moderne_tenant}"}),
      (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="PUBLISH_URL"; Value="${var.publish_url}"})
    )

    $task = New-Object Microsoft.Azure.Commands.Batch.Models.PSCloudTask -Property @{
      Id = "chunk"
      CommandLine = "./chunk.sh ${var.csv_file} ${var.chunk_size}"
      ContainerSettings = $taskSettings
      EnvironmentSettings = $envVars
    }

    New-AzBatchTask -JobId $jobId -Task $task -BatchContext $batchContext
  PS

  tags = var.tags
}

# Schedule — cron trigger
resource "azurerm_automation_schedule" "daily" {
  name                    = "${var.name}-daily"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.automation.name
  frequency               = "Day"
  interval                = 1
  timezone                = "UTC"
  start_time              = timeadd(timestamp(), "24h")

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_job_schedule" "trigger" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.automation.name
  schedule_name           = azurerm_automation_schedule.daily.name
  runbook_name            = azurerm_automation_runbook.trigger.name
}
```

- [ ] **Step 3: Create terraform.tfvars.example**

Create `3-scalability/azure-batch/terraform/terraform.tfvars.example`:

```hcl
name                = "mass-ingest"
resource_group_name = "your-resource-group"
location            = "eastus"

vnet_name   = "your-vnet"
subnet_name = "your-subnet"
nsg_name    = "your-subnet-nsg"

image    = "myregistry.azurecr.io/mass-ingest:latest"
acr_name = "myregistry"

vm_size   = "Standard_D4s_v5"
max_nodes = 64

moderne_tenant = "https://app.moderne.io"
key_vault_name = "your-keyvault"

# Storage — Maven/Artifactory (recommended)
publish_url = "https://artifactory.example.com/artifactory/moderne-ingest/"

# Git authentication — choose one:
# Secrets stored in Key Vault: moderne-token, git-credentials, publish-user, publish-password, etc.

# Ingestion settings
# csv_file   = "repos.csv"
# chunk_size = 10
# schedule   = "0 0 * * *"
```

- [ ] **Step 4: Commit**

```bash
git add 3-scalability/azure-batch/terraform/
git commit -m "Add Azure Batch Terraform configuration

Includes Batch account and pool with container support, Azure
Automation runbook for scheduling, Key Vault integration,
managed identity with least-privilege RBAC, and NSG rules."
```

---

## Task 7: create Azure Batch chunk.sh

**Files:**
- Create: `3-scalability/azure-batch/chunk.sh`

- [ ] **Step 1: Write chunk.sh**

Create `3-scalability/azure-batch/chunk.sh`:

```bash
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

  # Submit tasks individually — az batch task create --json-file expects a single task object
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
```

Note: `az batch task create --json-file` expects a single task object, not an array. Tasks are submitted individually in a loop. For very large task counts (1000+), consider using the Azure Batch REST API directly with `az rest` for bulk submission.

- [ ] **Step 2: Make executable**

```bash
chmod +x 3-scalability/azure-batch/chunk.sh
```

- [ ] **Step 3: Commit**

```bash
git add 3-scalability/azure-batch/chunk.sh
git commit -m "Add Azure Batch chunk.sh

Downloads CSV from Azure Blob/HTTP, calculates partitions, and
submits all processor tasks as a collection via az batch task create."
```

---

## Task 8: create Azure Batch README

**Files:**
- Create: `3-scalability/azure-batch/README.md`

- [ ] **Step 1: Write the Azure README**

Model the structure after `3-scalability/aws-batch/README.md` but with Azure-specific instructions. Include:

1. **Overview** — same architecture referencing Azure Batch, Azure Automation, Key Vault
2. **Prerequisites** — Azure subscription, Terraform, Docker, `az` CLI, ACR, repos.csv, storage option
3. **Quick start** steps:
   - Prepare repository list (same)
   - Build and push Docker image (ACR commands: `az acr login`, `docker push`)
   - Store secrets in Azure Key Vault (`az keyvault secret set ...`)
   - Configure Terraform variables (reference `terraform.tfvars.example`)
   - Deploy infrastructure (`terraform init/plan/apply`)
   - Manual trigger (`az batch job create` + `az batch task create`)
4. **How it works** — chunk job, processor jobs, parallel execution (Azure terminology: pool, job, tasks)
5. **Configuration** — VM size, pool scaling, schedule, partition size
6. **Monitoring** — Azure Portal Batch monitoring, `az batch task list`, Azure Monitor
7. **Cost optimization** — Spot VMs (low-priority nodes), auto-scale formula
8. **Troubleshooting** — Azure-specific issues (pool resize errors, ACR auth, quota)
9. **Cleanup** — `terraform destroy`
10. **Storage options** — Maven/Artifactory (recommended), Azure Blob via MinIO (optional)

- [ ] **Step 2: Commit**

```bash
git add 3-scalability/azure-batch/README.md
git commit -m "Add Azure Batch deployment guide

Complete guide for deploying mass-ingest on Azure using Batch,
Azure Automation, Key Vault, and managed identity."
```

---

## Task 9: update root README.md

**Files:**
- Modify: `README.md` (root)

- [ ] **Step 1: Update the 3-scalability section**

In `README.md`, update the `### 3-scalability` section to mention multi-cloud support:

Change the "What's included" list from AWS-specific to multi-cloud:
```markdown
**What's included:**
- Cloud-native batch services (AWS Batch, GCP Batch, Azure Batch)
- Terraform infrastructure as code
- Scheduled automation (daily/weekly)
- Auto-scaling compute — scales to zero when idle
- Production monitoring and cost optimization
```

Change the "Resources needed" list:
```markdown
**Resources needed:**
- Cloud account (AWS, GCP, or Azure)
- Terraform >= 1.0
- VPC/VNet with internet access
- Configurable compute (scales from 0 to 256+ vCPUs)
```

- [ ] **Step 2: Update the directory tree**

In the "Repository structure" section, update the `3-scalability/` subtree:

```
├── 3-scalability/        # Cloud-native batch deployment (multi-cloud)
│   ├── README.md          # Platform comparison and architecture overview
│   ├── aws-batch/         # AWS Batch + EventBridge + Secrets Manager
│   │   ├── chunk.sh
│   │   ├── terraform/
│   │   └── README.md
│   ├── gcp-batch/         # GCP Batch + Cloud Scheduler + Secret Manager
│   │   ├── chunk.sh
│   │   ├── terraform/
│   │   └── README.md
│   └── azure-batch/       # Azure Batch + Automation + Key Vault
│       ├── chunk.sh
│       ├── terraform/
│       └── README.md
```

- [ ] **Step 3: Update the quick comparison table**

Change the `3-scalability` column from AWS-specific to multi-cloud:

| Feature | 3-scalability |
|---|---|
| **Deployment** | Cloud-native batch + Terraform |
| **Monitoring** | Cloud-native logging + optional Grafana |
| **Scheduling** | Cloud-native scheduler |

- [ ] **Step 4: Update prerequisites**

Change `6. **AWS account**: Required only for stage 3` to:
```markdown
6. **Cloud account**: AWS, GCP, or Azure account (required only for stage 3)
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Update root README for multi-cloud scalability

Reflect the new AWS/GCP/Azure batch options in the scalability
stage description, directory tree, and comparison table."
```
