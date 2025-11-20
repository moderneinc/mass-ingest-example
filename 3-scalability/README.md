# Scalability: Scale to production

Production-scale deployment using AWS Batch for parallel repository processing.

**Best for:**
- Large repository counts (> 10,000 repos)
- Enterprise production environments
- When you need automatic scaling and parallel processing
- Fully managed infrastructure with minimal operational overhead

## Overview

This example deploys mass-ingest at scale using:
- **AWS Batch** - Managed batch processing with automatic scaling
- **ECS** - Container orchestration
- **EventBridge Scheduler** - Automated daily runs
- **Parallel workers** - Process repository partitions concurrently

Architecture:
1. **Chunk job** - Divides repos.csv into partitions and submits processor jobs
2. **Processor jobs** - Multiple workers process different repository ranges in parallel
3. **Scheduler** - Triggers the chunk job daily (configurable)

## Prerequisites

- AWS account with appropriate permissions
- Terraform installed (>= 1.0)
- Docker for building the image
- AWS CLI configured
- ECR repository or Docker registry
- repos.csv file with repositories to ingest
- Access to one of the following storage options:
  - Amazon S3 bucket for LST storage
  - Artifactory with Maven 2 format support
  - Nexus or other Maven-compatible repository

## Quick start

### 1. Prepare your repository list

Create or edit `../repos.csv` with your repositories and determine where you wish to store it. Mass Ingest is capable of pulling your `repos.csv` from local disk, S3, or unauthenticated HTTP(S).

> [!INFO]
> [`chunk.sh`](chunk.sh#L11) and [`publish.sh`](../publish.sh#L40) can be updated to enable authenticated HTTP(S), if desired.

```csv
cloneUrl,branch,origin,path
https://github.com/org/repo1,main,github.com,org/repo1
https://github.com/org/repo2,main,github.com,org/repo2
```

Required columns:
- `cloneUrl` - Full HTTPS clone URL
- `branch` - Branch to build
- `origin` - Source control host (e.g., github.com)
- `path` - Repository path (e.g., org/repo)

### 2. Build and push Docker image

```bash
# Build the image from repository root
docker build -t mass-ingest:latest ..

# Tag for your registry
docker tag mass-ingest:latest <your-registry>/mass-ingest:latest

# Push to registry
docker push <your-registry>/mass-ingest:latest
```

For AWS ECR:
```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

docker build -t mass-ingest:latest ..
docker tag mass-ingest:latest <account-id>.dkr.ecr.us-east-1.amazonaws.com/mass-ingest:latest
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/mass-ingest:latest
```

### 3. Store secrets in AWS Secrets Manager

#### 3a. Moderne token

```bash
aws secretsmanager create-secret \
  --name mass-ingest/moderne-token \
  --secret-string "your-moderne-token"
```

#### 3b. Git credentials

For username+password or username+token authentication:

```bash
aws secretsmanager create-secret \
  --name mass-ingest/git-credentials \
  --secret-string "https://username:token@github.com
https://username:token@gitlab.com"
```

For SSH key authentication:

```bash
aws secretsmanager create-secret \
  --name mass-ingest/ssh-private-key \
  --secret-string file://id_ed25519
```

> [!WARNING]
> Certain special characters in the password can lead to potential problems

#### 3c. Publishing credentials

Choose one of the following storage options:

**Option A: S3 Storage**

S3 uses IAM roles by default (no secrets needed). The Terraform configuration automatically grants S3 permissions when you specify the bucket name.

S3 configuration is handled through Terraform variables (not secrets):
- `moderne_s3_profile` - AWS profile name (optional, uses IAM instance profile/task role by default)
- `moderne_s3_region` - AWS region for cross-region bucket access (optional)
- `moderne_s3_endpoint` - S3 endpoint URL for S3-compatible services like MinIO (optional)

These are configured directly in your `terraform.tfvars` file as shown in step 4 below.

**Option B: Maven/Artifactory Repository**

For password authentication:

```bash
aws secretsmanager create-secret \
  --name mass-ingest/publishing \
  --secret-string '{"username": "your-artifactory-user", "password": "your-artifactory-password"}'
```

For token authentication:
```bash
aws secretsmanager create-secret \
  --name mass-ingest/publishing \
  --secret-string '{"token":"your-publishing-token"}'
```

> [!WARNING]
> Certain special characters in the password can lead to potential problems

### 4. Configure Terraform variables

Create `terraform/terraform.tfvars`:

```hcl
name                      = "mass-ingest"
vpc_id                    = "vpc-xxxxx"
subnet_ids                = ["subnet-xxxxx", "subnet-yyyyy"]
image_registry            = "<your-registry>/mass-ingest"
image_tag                 = "latest"
moderne_tenant            = "https://app.moderne.io"  # or your tenant url
moderne_token             = "arn:aws:secretsmanager:region:account:secret:mass-ingest/moderne-token"

# Storage configuration - choose one option:

# Option A: S3 Storage
moderne_publish_url       = "s3://your-bucket"
moderne_s3_bucket_name   = "your-bucket"  # Required for IAM permissions
# Optional: S3 configuration parameters
# moderne_s3_profile       = "default"            # AWS profile name
# moderne_s3_region        = "us-west-2"          # For cross-region bucket access
# moderne_s3_endpoint      = "https://minio.example.com"  # For S3-compatible services

# Option B: Maven/Artifactory Repository
# moderne_publish_url       = "https://artifactory.example.com/artifactory/moderne-ingest/"
# Set either user+password or token for publishing
# moderne_publish_user      = "arn:aws:secretsmanager:region:account:secret:mass-ingest/publishing:username::"
# moderne_publish_password  = "arn:aws:secretsmanager:region:account:secret:mass-ingest/publishing:password::"
# moderne_publish_token     = "arn:aws:secretsmanager:region:account:secret:mass-ingest/publishing:token::"

# Git authentication - set either username+password/token or SSH
# moderne_git_credentials   = "arn:aws:secretsmanager:region:account:secret:mass-ingest/git-credentials"
# moderne_ssh_credentials   = "arn:aws:secretsmanager:region:account:secret:mass-ingest/ssh-private-key"

default_tags = {
  Environment = "production"
  Project     = "mass-ingest"
}
```

### 5. Deploy infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

This creates:
- Batch compute environment (EC2 instances)
- Batch job queue
- Job definitions (chunk + processor)
- IAM roles and policies (including S3 access if `moderne_s3_bucket_name` is set)
- EventBridge schedule (daily at midnight UTC)
- Security groups
- CloudWatch log groups

#### AWS IAM Configuration for S3

When using S3 storage, the Terraform automatically configures:

1. **Chunk Task Role**: Read-only S3 access (GetObject) for reading repos.csv from S3
2. **Processor Task Role**: Write-only S3 access (PutObject) for storing LST artifacts

The system uses the AWS SDK credential chain automatically:
- In ECS/Fargate: Uses IAM task role
- On EC2: Uses IAM instance profile
- No S3_PROFILE needed when running on AWS infrastructure

For local testing or non-AWS environments, you can specify:
- `S3_PROFILE` - AWS profile name
- `S3_REGION` - For cross-region bucket access
- `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` - Direct credentials

### 6. Trigger manually (optional)

```bash
aws batch submit-job \
  --job-name mass-ingest-manual \
  --job-queue mass-ingest-job-queue \
  --job-definition mass-ingest-chunk-job-definition
```

## How it works

### Chunk job
1. Reads `repos.csv`
2. Calculates number of repositories
3. Divides into partitions (e.g., 10 repos per worker)
4. Submits processor jobs for each partition with `--start` and `--end` parameters

### Processor jobs
Each processor job:
1. Receives `--start X --end Y` parameters
2. Selects only repos X through Y from repos.csv
3. Clones, builds, and publishes LSTs for those repositories
4. Uploads build logs

### Parallel execution
- Multiple processor jobs run simultaneously
- AWS Batch automatically scales EC2 instances based on demand
- Each worker is isolated and processes its partition independently

## Configuration

### Compute resources

Adjust in `terraform/main.tf`:

```hcl
resource "aws_batch_compute_environment" "compute_environment" {
  compute_resources {
    type = "EC2"  # or "FARGATE" for serverless
    instance_type = ["m6a.xlarge"]
    min_vcpus = 0     # Scale to zero when idle
    max_vcpus = 256   # Maximum parallel workers
  }
}
```

### Worker resources

Each processor job gets:
- **4 vCPUs**
- **15 GB RAM**
- **64 GB disk** (from launch template)
- **1 hour timeout**

Adjust in the job definition:
```hcl
resource "aws_batch_job_definition" "processor_job_definition" {
  container_properties = jsonencode({
    resourceRequirements = [
      { type = "VCPU", value = "4" },
      { type = "MEMORY", value = "15360" }
    ]
  })
  timeout {
    attempt_duration_seconds = 3600  # 1 hour
  }
}
```

### Schedule

Default: Daily at midnight UTC

Modify in `terraform/main.tf`:
```hcl
resource "aws_scheduler_schedule" "daily_trigger" {
  schedule_expression = "cron(0 0 * * ? *)"  # Daily at midnight
  # schedule_expression = "cron(0 */6 * * ? *)"  # Every 6 hours
  # schedule_expression = "rate(12 hours)"  # Every 12 hours
}
```

### Partition size

The `chunk.sh` script is responsible for splitting up the source CSV by the configured partition size. The default partition size is 10, but can be modified via the terraform variable:

```hcl
ingest_chunk_size=50  # Repositories per worker
```

## Monitoring

### CloudWatch Logs

View logs for all jobs:
```bash
aws logs tail /aws/batch/job --follow
```

Filter by job:
```bash
aws logs filter-log-events \
  --log-group-name /aws/batch/job \
  --filter-pattern "mass-ingest"
```

### Batch console

Monitor jobs in AWS Console:
- **Compute environments**: EC2 instance scaling
- **Job queues**: Pending/running jobs
- **Job dashboard**: Success/failure rates

### Metrics

Key CloudWatch metrics:
- `AWS/Batch/ComputeEnvironmentVCpuUtilization`
- `AWS/Batch/JobQueuePendingJobs`
- `AWS/Batch/JobQueueRunningJobs`

## Cost optimization

### Spot instances

Use Spot instances for cost savings:

```hcl
compute_resources {
  type = "SPOT"
  allocation_strategy = "SPOT_CAPACITY_OPTIMIZED"
  bid_percentage = 100  # % of On-Demand price
}
```

### Auto-scaling

The configuration already scales to zero when idle:
```hcl
min_vcpus = 0  # No instances when no jobs
max_vcpus = 256  # Scale up as needed
```

### Fargate

For simpler management (no instance management):

```hcl
compute_resources {
  type = "FARGATE"
  # Note: More expensive but fully managed
}
```

## Troubleshooting

See dedicated [troubleshooting](./TROUBLESHOOTING.md) page

## Cleanup

Remove all resources:

```bash
cd terraform
terraform destroy
```

Note: This does not delete:
- Docker images in ECR
- CloudWatch logs (7-day retention configured)
- Secrets in Secrets Manager

## Scaling guidance

General guidance is 1 worker per 1000 repositories provides a reasonable ingestion time at scale.

| Repository count | Recommended config |
|-----------------|-------------------|
| < 100 | Use 1-quickstart or 2-observability |
| 100-1000 | 1-2 workers |
| 1000-10000 | 5-10 workers |
| 10000-50000 | 10-50 workers |
| 50000+ | 50+ workers, adjust max_vcpus |

## Security considerations

- **Secrets**: Stored in AWS Secrets Manager, never in code
- **IAM**: Least-privilege roles for chunk and processor jobs
- **Network**: Security groups restrict inbound, allow outbound
- **Encryption**: EBS volumes encrypted at rest
- **IMDSv2**: Required (http_tokens = "required")

## Cost estimation

Example for 1000 repositories:
- **Compute**: 20 workers × m6a.xlarge × 3 hours = ~$12
- **Storage**: 64 GB EBS × 20 instances = ~$2
- **Network**: Minimal (same region)
- **Total per run**: ~$15

Actual costs vary based on:
- Repository sizes
- Build complexity
- Instance types
- Region

## Additional resources

- [Moderne CLI documentation](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro)
- [repos.csv reference](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv)
- [AWS Batch Documentation](https://docs.aws.amazon.com/batch/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [AWS Batch Best Practices](https://docs.aws.amazon.com/batch/latest/userguide/best-practices.html)

## Optional enhancements

- Set up CloudWatch alarms for job failures
- Configure SNS notifications for job completion
- Integrate with CI/CD for automatic image updates
- Add custom metrics for business intelligence
