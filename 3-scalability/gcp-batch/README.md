# Scalability: GCP Batch

Production-scale deployment using Google Cloud Batch for parallel repository processing.

**Best for:**
- Large repository counts (> 10,000 repos)
- Enterprise production environments on GCP
- When you need automatic scaling and parallel processing
- Fully managed infrastructure with minimal operational overhead

## Overview

This example deploys mass-ingest at scale using:
- **Google Cloud Batch** — managed batch processing on Compute Engine VMs
- **Cloud Workflows** — orchestrates job creation with dynamic task count
- **Cloud Scheduler** — automated daily runs
- **Secret Manager** — secure credential storage
- **Service Accounts** — least-privilege IAM

Architecture:
1. **Cloud Scheduler** triggers the workflow on a cron schedule
2. **Cloud Workflow** determines the number of tasks (fetches CSV from URL to count lines, or uses a provided `total_repos`) and creates a Batch job
3. **Batch tasks** — N parallel tasks, each running `chunk.sh` which downloads the CSV (if URL) and computes `--start`/`--end` from `BATCH_TASK_INDEX`
4. **VMs scale to zero** when all tasks complete

> **Note:** Unlike the AWS example, GCP does not use a separate chunk job. The Cloud Workflow handles task count calculation and creates the Batch job directly with N parallel tasks.

## Prerequisites

- GCP project with billing enabled
- Terraform installed (>= 1.0)
- Docker for building the image
- `gcloud` CLI configured (`gcloud auth login`)
- Artifact Registry repository for Docker images
- repos.csv — either hosted at an HTTP/HTTPS URL or baked into the container image
- Access to one of the following storage options:
  - Maven/Artifactory repository (recommended)
  - GCS bucket with S3-compatible interop (optional)

## Quick start

### 1. Prepare your repository list

Create your `repos.csv`:

```csv
cloneUrl,branch,origin,path
https://github.com/org/repo1,main,github.com,org/repo1
https://github.com/org/repo2,main,github.com,org/repo2
```

**Option A: Host at a URL (recommended)** — the workflow counts repos automatically:
```bash
gsutil cp repos.csv gs://your-bucket/repos.csv
```
Set `csv_file` to the URL (e.g., `https://storage.googleapis.com/your-bucket/repos.csv`).

**Option B: Bake into the container image** — add the CSV to your Docker build and set `csv_file = "repos.csv"`. You must also set `total_repos` to the number of repos (excluding the header row).

### 2. Build and push Docker image

```bash
# Configure Docker for Artifact Registry
gcloud auth configure-docker us-docker.pkg.dev

# Build the image from repository root
docker build -t mass-ingest:latest ../..

# Tag for Artifact Registry
docker tag mass-ingest:latest us-docker.pkg.dev/your-project/mass-ingest/mass-ingest:latest

# Push
docker push us-docker.pkg.dev/your-project/mass-ingest/mass-ingest:latest
```

### 3. Store secrets in Secret Manager

#### 3a. Moderne token

```bash
echo -n "your-moderne-token" | gcloud secrets create mass-ingest-moderne-token --data-file=-
```

#### 3b. Git credentials

For username+token authentication:

```bash
printf "https://username:token@github.com\nhttps://username:token@gitlab.com" | \
  gcloud secrets create mass-ingest-git-credentials --data-file=-
```

For SSH key authentication:

```bash
gcloud secrets create mass-ingest-ssh-key --data-file=id_ed25519
```

#### 3c. Publishing credentials

```bash
# For password authentication
echo -n "your-artifactory-user" | gcloud secrets create mass-ingest-publish-user --data-file=-
echo -n "your-artifactory-password" | gcloud secrets create mass-ingest-publish-password --data-file=-

# Or for token authentication
echo -n "your-publishing-token" | gcloud secrets create mass-ingest-publish-token --data-file=-
```

### 4. Configure Terraform variables

Copy and edit the example:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

**Important:** Set `csv_file` to the location of your `repos.csv` — either an HTTP/HTTPS URL or a local file path baked into the container image. When using a URL, the workflow counts repos automatically. When using a local path, also set `total_repos`.

See `terraform/terraform.tfvars.example` for all available options.

### 5. Deploy infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

This creates:
- Service accounts with least-privilege IAM
- Cloud Workflows workflow
- Cloud Scheduler cron trigger
- Firewall rule for metrics scraping
- Secret Manager IAM bindings

### 6. Trigger manually (optional)

```bash
gcloud workflows execute mass-ingest --location=us-central1
```

## How it works

### Cloud Workflow
1. Determines total repositories — fetches the CSV from the URL and counts lines, or uses the provided `total_repos`
2. Computes `taskCount = ceil(totalRepos / chunkSize)`
3. Creates a GCP Batch job with N parallel tasks

### Batch tasks
Each task:
1. Runs `chunk.sh` which downloads the CSV (if URL) or reads it locally, and reads `BATCH_TASK_INDEX` from the environment
2. Computes `start = index * chunk_size + 1` and `end = start + chunk_size`
3. Calls `publish.sh --start $start --end $end`
4. Clones, builds, and publishes LSTs for its partition of repositories

### Compute
- Each task gets a dedicated Compute Engine VM
- Default: `n2-standard-4` (4 vCPU, 15 GB RAM, 64 GB disk)
- VMs are provisioned on demand and deleted when the job completes

## Configuration

### Machine type

Default: `n2-standard-4` (4 vCPU, 15 GB RAM). Each task gets a full VM — no resource contention with other workloads.

Larger repositories or monorepos may need more CPU and memory. Adjust in `terraform.tfvars`:
```hcl
machine_type = "n2-standard-8"  # 8 vCPU, 32 GB RAM
```

### Worker resources

Each task gets a full VM. Adjust disk size:
```hcl
boot_disk_size_gb = 128  # For large repositories
```

### Schedule

Default: daily at midnight UTC

Modify in `terraform.tfvars`:
```hcl
schedule = "0 0 * * 0"  # Weekly on Sunday
```

### Partition size

```hcl
chunk_size = 50  # Repositories per worker
```

> **Note:** When using an HTTP/HTTPS URL, the workflow automatically counts repositories at runtime — no need to update configuration when repos.csv changes. When using a local file, update `total_repos` when your CSV changes.

## Monitoring

### Cloud Logging

View logs for batch tasks:
```bash
gcloud logging read 'logName:"batch_task_logs"' --limit=100 --format='value(textPayload)'
```

Filter by job name:
```bash
gcloud logging read '"mass-ingest-1234567890"' --limit=100 --format='value(textPayload)'
```

### Batch console

Monitor jobs in the GCP Console:
- **Batch** → **Jobs** — see all jobs and task status
- **Batch** → **Jobs** → select a job → **Tasks** — individual task logs

### CLI

```bash
# List jobs
gcloud batch jobs list --location=us-central1

# Describe a job
gcloud batch jobs describe mass-ingest-1234567890 --location=us-central1

# List tasks in a job
gcloud batch tasks list --job=mass-ingest-1234567890 --location=us-central1
```

## Cost optimization

### Spot VMs

Use Spot VMs for significant cost savings (up to 60-91% discount):

In `main.tf`, add to the allocation policy's instance policy:
```hcl
provisioningModel = "SPOT"
```

> **Note:** Spot VMs can be preempted. Configure `maxRetryCount` in the task spec to automatically retry preempted tasks (default is 0 — no retries).

### Auto-scaling

The configuration already scales to zero — VMs are only created when a job runs and deleted when it completes.

## Troubleshooting

### API not enabled

If you see "API not enabled" errors:
```bash
gcloud services enable batch.googleapis.com workflows.googleapis.com cloudscheduler.googleapis.com secretmanager.googleapis.com
```

### Quota exceeded

Check and request quota increases:
- **IAM & Admin** → **Quotas** in the console
- Common limits: CPUs per region, VM instances per project

### Tasks fail immediately

- Check container image is accessible from Artifact Registry
- Verify service account has Secret Manager access
- Review task logs in Cloud Logging
- Check `PUBLISH_URL` and credential configuration

### Network timeouts

- Verify the VPC has a Cloud NAT or external IP access for outbound traffic
- Check firewall rules allow egress to required services
- Ensure Secret Manager and Artifact Registry are reachable

## Cleanup

Remove all resources:

```bash
cd terraform
terraform destroy
```

Note: This does not delete:
- Container images in Artifact Registry
- Secrets in Secret Manager
- Cloud Logging logs

## Storage options

### Maven/Artifactory (recommended)

The primary storage option. Works with any Maven-compatible repository:

```hcl
publish_url = "https://artifactory.example.com/artifactory/moderne-ingest/"
```

Credentials stored in Secret Manager as `mass-ingest-publish-user`/`mass-ingest-publish-password` or `mass-ingest-publish-token`.

### GCS via S3-compatible interop (optional)

GCS provides an S3-compatible API via the XML API endpoint. To use it:

```hcl
publish_url = "s3://your-gcs-bucket"
s3_endpoint = "https://storage.googleapis.com"
s3_region   = "auto"
```

This requires HMAC keys for authentication (not service account keys). Create HMAC keys:
```bash
gsutil hmac create your-service-account@your-project.iam.gserviceaccount.com
```

> **Note:** GCS interop has limitations compared to native S3 (different multipart upload behavior, HMAC auth instead of IAM). Maven/Artifactory is simpler and recommended.

## Scaling guidance

| Repository count | Recommended config |
|---|---|
| < 100 | Use 1-quickstart or 2-observability |
| 100-1,000 | 1-2 workers |
| 1,000-10,000 | 5-10 workers |
| 10,000-50,000 | 10-50 workers |
| 50,000+ | 50+ workers |

## Security considerations

- **Secrets**: Stored in Google Secret Manager, never in code
- **IAM**: Least-privilege service accounts (batch task, scheduler, workflow)
- **Network**: Firewall restricts inbound, allows outbound
- **Logging**: All task output goes to Cloud Logging

## Cost estimation

Example for 1,000 repositories:
- **Compute**: 20 workers x n2-standard-4 x 3 hours ≈ $13
- **Storage**: Boot disks ≈ $2
- **Network**: Minimal (same region)
- **Total per run**: ~$15

Actual costs vary based on repository sizes, build complexity, machine types, and region.

## Additional resources

- [Moderne CLI documentation](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro)
- [repos.csv reference](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv)
- [Google Cloud Batch documentation](https://cloud.google.com/batch/docs)
- [Terraform Google provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
