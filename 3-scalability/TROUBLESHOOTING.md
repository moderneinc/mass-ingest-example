# Troubleshooting

## The run

### `The artifact store has no repos.csv at ...`

`mod publish --sync-csv` refuses to start without the input list, because `repos-lock.csv` is rebuilt from it and a missing list would look like an empty portfolio. Upload the full `repos.csv` to the location in the message (the store root for S3 and Artifactory; the `io/moderne/organization/sources/repos/1.0.0/repos-1.0.0.csv` coordinate for Maven repositories) and keep your repository fetcher overwriting it there.

### Everything is skipped

A row is skipped when its `repos-lock.csv` entry already has the remote HEAD as `changeset`, the running CLI version as `cliVersion` and `reproducible=true`. That is the intended steady state: only a new commit, a new CLI release or a build with dynamic dependency versions triggers a rebuild. To force a repository through, remove its row from `repos-lock.csv` in the store (or the whole file to rebuild everything). Development builds of the CLI report their version as `UNDEFINED`, which makes different dev builds look alike to the skip rule.

### The run was killed and the lock lost recent rows

The CLI flushes `repos-lock.csv` from a shutdown hook on SIGTERM and, while running, once per round at a 15-second turn set by the container's shard and organization, so containers take turns on the file; a round is five minutes for a handful of containers, 15 seconds per container beyond that, and half an hour at most. `docker stop`, a Batch timeout and Ctrl+C all deliver SIGTERM and wait for the flush; SIGKILL (`docker kill`, the OOM killer, a VM preemption) does not, and up to one round of results is then rebuilt on the next run, which is cheap because their LSTs were already published and only the rows are missing. If runs are killed regularly, give the container more memory or lower `PARALLEL`.

### S3: `Unable to contact EC2 metadata service`

Raise the IMDSv2 hop limit to 2 on the instance ([why](../docs/s3.md#ec2-instance-roles-raise-the-imdsv2-hop-limit)). The AWS Batch Terraform already does.

### Build failures

`data/.moderne/build/<command id>/trace.csv` lists every build with its outcome, and `data/.moderne/publish/<command id>/publish.log` has the stack traces; `DIAGNOSE=true` checks the toolchains and the SCM origins before a run. Out of memory: raise `-Xmx` in the Dockerfile's `mod config java options edit` and the container's memory limit together.

## AWS Batch

### Jobs stay in PENDING

This usually occurs because the Auto Scaling Group cannot scale up.

- Check VPC/subnet configuration
- Verify security group allows outbound traffic (main.tf)
- Check max_vcpus limit (main.tf)
- Check EC2 instance quotas (AWS Service Quotas)
- Review IAM permissions (main.tf)

### Jobs fail immediately

This usually occurs because the image cannot be pulled or a required parameter is missing.

- Check Docker image is accessible (tfvars, Image Registry)
- Verify secrets ARNs are correct (tfvars, Secrets Manager)
- Review CloudWatch logs
- Check PUBLISH_URL format (tfvars)

### Out of memory errors

This usually occurs while a job is running where the container exceeds its allowed memory limit.

Increase memory in job definition (main.tf):
```hcl
{ type = "MEMORY", value = "30720" }  # 30 GB
```

### Network timeouts

This usually occurs while a job is running where the container is not able to access a resource due to a networking restriction.

- Verify security group egress rules
- Check VPC/Subnet configuration
- Ensure route table has a NAT gateway entry for internet access
- Ensure ECR/Secrets Manager endpoints are reachable

## GCP Batch

### Tasks stay in SCHEDULED/PENDING

This usually occurs because VMs cannot be provisioned.

- Check quota limits: **IAM & Admin** → **Quotas** (CPUs per region, VM instances)
- Verify the VPC/subnet exists and is correctly configured
- Check the service account has Artifact Registry reader and Batch agent permissions
- Review Batch job events in the console: **Batch** → **Jobs** → select job → **Events**

### Tasks fail immediately

This usually occurs because the container image cannot be pulled or a required secret is missing.

- Check container image is accessible from Artifact Registry
- Verify the batch task service account has Secret Manager access
- Review task logs in Cloud Logging:
  ```bash
  gcloud logging read 'logName:"batch_task_logs"' --limit=50 --format='value(textPayload)'
  ```
- Check `PUBLISH_URL` and credential configuration
- `task.sh: No such file`: the `COPY ... task.sh` line in the root Dockerfile is still commented out

### The scheduler cannot create the batch job

- Verify the scheduler service account has `roles/batch.jobsEditor` and `roles/iam.serviceAccountUser` (it creates the job running as the batch task service account)
- Check the last run: `gcloud scheduler jobs describe mass-ingest-trigger --location=<region>`
- Enable the APIs: `gcloud services enable batch.googleapis.com cloudscheduler.googleapis.com secretmanager.googleapis.com`

### Out of memory errors

This usually occurs when the container exceeds its allowed memory limit during a build.

Increase the machine type in `terraform.tfvars`:
```hcl
machine_type = "n2-standard-8"  # 8 vCPU, 32 GB RAM
```

### Network timeouts

This usually occurs when the container cannot access external resources.

- Verify the VPC has a Cloud NAT or external IP access for outbound traffic
- Check firewall rules allow egress to required services
- Ensure Secret Manager, Artifact Registry, and git hosts are reachable
