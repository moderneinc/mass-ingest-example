# GCP Batch

One Google Cloud Batch job per schedule with one task per organization, created directly by Cloud Scheduler, on Compute Engine VMs that are deleted when the tasks finish.

## 1. Build and push the image

Uncomment the `COPY ... 3-scalability/gcp-batch/task.sh task.sh` line in the root `Dockerfile`: each task runs `task.sh`, which picks its organization from `BATCH_TASK_INDEX` and execs `publish.sh`.

```bash
gcloud auth configure-docker us-docker.pkg.dev
docker build -t us-docker.pkg.dev/your-project/mass-ingest/mass-ingest:latest ../..
docker push us-docker.pkg.dev/your-project/mass-ingest/mass-ingest:latest
```

## 2. Store secrets in Secret Manager

```bash
echo -n "your-moderne-token" | gcloud secrets create mass-ingest-moderne-token --data-file=-

# private repositories: one of
printf "https://username:token@github.com\nhttps://username:token@gitlab.com" | \
  gcloud secrets create mass-ingest-git-credentials --data-file=-
gcloud secrets create mass-ingest-ssh-key --data-file=id_ed25519

# publishing: user + password, or a token
echo -n "your-artifactory-user" | gcloud secrets create mass-ingest-publish-user --data-file=-
echo -n "your-artifactory-password" | gcloud secrets create mass-ingest-publish-password --data-file=-
echo -n "your-publishing-token" | gcloud secrets create mass-ingest-publish-token --data-file=-
```

## 3. Configure Terraform

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Set the project, network, image, tenant and `publish_url` with its secrets, then list the `organizations` to ingest. A Maven/Artifactory store is the straightforward choice; GCS works through its S3-compatible XML API (`publish_url = "s3://bucket"`, `s3_endpoint = "https://storage.googleapis.com"`, `s3_region = "auto"`) with HMAC keys (`gsutil hmac create <service-account>`).

## 4. Apply

```bash
cd terraform
terraform init
terraform apply
```

This enables the Batch, Compute, Scheduler, Secret Manager and Logging APIs and creates the batch task service account (secret access, Artifact Registry reader, Batch agent, log writer), the scheduler service account (`batch.jobsEditor` and `iam.serviceAccountUser`), a firewall rule for metrics scraping, and the Cloud Scheduler job that POSTs the Batch job to `batch.googleapis.com` with `taskCount = parallelism = number of organizations` (1 when the list is empty) and `ORGANIZATIONS` in the environment.

## 5. Trigger manually

```bash
gcloud scheduler jobs run mass-ingest-trigger --location=us-central1
gcloud batch jobs list --location=us-central1
gcloud logging read 'logName:"batch_task_logs"' --limit=100 --format='value(textPayload)'
```

## Tuning

- `organizations`: one task each. Leave it empty for a single task over the whole `repos.csv`.
- `parallel`: repositories in flight per task; raise it together with `machine_type` (default `n2-standard-4`, 4 vCPU / 16 GB).
- `max_run_duration_seconds` (default one day): a run flushes `repos-lock.csv` when it is terminated, so a timeout costs only the repository in flight.
- `schedule` (default daily at midnight UTC) and `max_retry_count` (default 0; set it together with `provisioningModel = "SPOT"` in `main.tf`, since Spot VMs can be preempted).
- `boot_disk_size_gb` (default 64) is plenty: a task holds one repository at a time.

`terraform destroy` removes everything except the images, the secrets and the logs.
