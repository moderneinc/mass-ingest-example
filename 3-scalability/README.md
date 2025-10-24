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

## Quick start

### 1. Build and push Docker image

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

### 2. Configure Terraform variables

Create `terraform/terraform.tfvars`:

```hcl
name                      = "mass-ingest"
vpc_id                    = "vpc-xxxxx"
subnet_ids                = ["subnet-xxxxx", "subnet-yyyyy"]
image_registry            = "<your-registry>/mass-ingest"
image_tag                 = "latest"
moderne_tenant            = "app"  # or your tenant name
moderne_token             = "arn:aws:secretsmanager:region:account:secret:moderne-token"
moderne_publish_url       = "https://artifactory.example.com/artifactory/moderne-ingest/"
moderne_publish_user      = "arn:aws:secretsmanager:region:account:secret:publish-user"
moderne_publish_password  = "arn:aws:secretsmanager:region:account:secret:publish-password"

default_tags = {
  Environment = "production"
  Project     = "mass-ingest"
}
```

### 3. Store secrets in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name mass-ingest/moderne-token \
  --secret-string "your-moderne-token"

aws secretsmanager create-secret \
  --name mass-ingest/publish-user \
  --secret-string "your-artifactory-user"

aws secretsmanager create-secret \
  --name mass-ingest/publish-password \
  --secret-string "your-artifactory-password"
```

### 4. Deploy infrastructure

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
- IAM roles and policies
- EventBridge schedule (daily at midnight UTC)
- Security groups
- CloudWatch log groups

### 5. Prepare repos.csv

Create or edit `../repos.csv` with your repositories:

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

The repos.csv must be available to the chunk job. Options:

**Option A: Bake into image**
Already handled - repos.csv is copied from `../repos.csv` during build.

**Option B: Download from S3**
Modify the chunk job command to download from S3:
```hcl
command = ["sh", "-c", "aws s3 cp s3://bucket/repos.csv repos.csv && ./chunk.sh repos.csv"]
```

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
3. Divides into partitions (e.g., 50 repos per worker)
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

The `chunk.sh` script determines partition size. Modify `chunk.sh` in this directory:

```bash
PARTITION_SIZE=50  # Repositories per worker
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

### Jobs stay in PENDING
- Check VPC/subnet configuration
- Verify security group allows outbound traffic
- Check max_vcpus limit
- Review IAM permissions

### Jobs fail immediately
- Check Docker image is accessible
- Verify secrets ARNs are correct
- Review CloudWatch logs
- Check PUBLISH_URL format

### Out of memory errors
Increase memory in job definition:
```hcl
{ type = "MEMORY", value = "30720" }  # 30 GB
```

### Network timeouts
- Verify security group egress rules
- Check VPC has NAT gateway for internet access
- Ensure ECR/secrets endpoints are reachable

### Chunk job doesn't submit workers
- Check IAM role has `batch:SubmitJob` permission
- Verify job queue and definition ARNs
- Review chunk.sh script logs

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

| Repository count | Recommended config |
|-----------------|-------------------|
| < 100 | Use 1-quickstart or 2-observability |
| 100-1000 | 2-4 workers, m6a.xlarge |
| 1000-5000 | 10-20 workers, m6a.2xlarge |
| 5000+ | 50+ workers, adjust max_vcpus |

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

## Optional enhancements

- Set up CloudWatch alarms for job failures
- Configure SNS notifications for job completion
- Integrate with CI/CD for automatic image updates
- Add custom metrics for business intelligence

## Additional resources

- [AWS Batch Documentation](https://docs.aws.amazon.com/batch/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [AWS Batch Best Practices](https://docs.aws.amazon.com/batch/latest/userguide/best-practices.html)
