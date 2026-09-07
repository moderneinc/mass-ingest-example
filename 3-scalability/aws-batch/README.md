# AWS Batch

One AWS Batch job per organization, submitted by EventBridge Scheduler on a cron schedule, on EC2 instances that scale to zero.

## 1. Build and push the image

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com
docker build -t <account-id>.dkr.ecr.us-east-1.amazonaws.com/mass-ingest:latest ../..
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/mass-ingest:latest
```

## 2. Store secrets in Secrets Manager

```bash
aws secretsmanager create-secret --name mass-ingest/moderne-token --secret-string "your-moderne-token"

# private repositories: one of
aws secretsmanager create-secret --name mass-ingest/git-credentials \
  --secret-string "https://username:token@github.com
https://username:token@gitlab.com"
aws secretsmanager create-secret --name mass-ingest/ssh-private-key --secret-string file://id_ed25519

# Maven/Artifactory publishing: one of (S3 uses the job's IAM role, no secret)
aws secretsmanager create-secret --name mass-ingest/publishing \
  --secret-string '{"username": "your-artifactory-user", "password": "your-artifactory-password"}'
aws secretsmanager create-secret --name mass-ingest/publishing --secret-string '{"token":"your-publishing-token"}'
```

Percent-encode special characters in passwords; git and Maven cannot parse some of them raw.

## 3. Configure Terraform

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Set the VPC, subnets, image, tenant and the storage option (`moderne_publish_url` plus `moderne_s3_bucket_name` for S3, or the publishing secret ARNs for Maven/Artifactory), then list the `organizations` to ingest. With S3 the processor role gets `GetObject`, `PutObject` and `ListBucket` on the bucket; the launch template sets the IMDSv2 hop limit to 2 so the container can reach the instance role.

## 4. Apply

```bash
cd terraform
terraform init
terraform apply
```

This creates the compute environment, job queue, processor job definition, IAM roles, a security group, the CloudWatch log group (7 day retention) and one EventBridge schedule per organization (a single `all` schedule when the list is empty), each submitting the job with `ORGANIZATION` set through a container override.

## 5. Trigger manually

```bash
aws batch submit-job --job-name mass-ingest-payments --job-queue mass-ingest-job-queue \
  --job-definition mass-ingest-processor-job-definition \
  --container-overrides 'environment=[{name=ORGANIZATION,value=Payments}]'
```

Follow along with `aws logs tail /aws/batch/job --follow`, or in the Batch console.

## Tuning

- `organizations`: one job each. Leave it empty for a single job over the whole `repos.csv`.
- `job_timeout_seconds` (default one day): a run flushes `repos-lock.csv` when it is terminated, so a timeout costs only the repository in flight.
- `instance_type` (default `m6a.xlarge`) and `max_vcpus` in `main.tf`; `type = "SPOT"` in the compute environment for cheaper instances.
- `schedule_expression` (default daily at midnight UTC), e.g. `cron(0 */6 * * ? *)` or `rate(12 hours)`.
- The launch template's 64 GB volume is plenty: a job holds one repository at a time.

`terraform destroy` removes everything except the ECR images, the log group's contents and the secrets.
