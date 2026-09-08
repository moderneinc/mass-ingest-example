# Scalability: Azure Batch

Production-scale deployment using Azure Batch for parallel repository processing.

**Best for:**
- Large repository counts (> 10,000 repos)
- Enterprise production environments on Azure
- When you need automatic scaling and parallel processing
- Fully managed infrastructure with minimal operational overhead

## Overview

This example deploys mass-ingest at scale using:
- **Azure Batch** — managed batch processing with auto-scaling VM pools
- **Azure Automation** — scheduled daily runs via PowerShell runbook
- **Azure Key Vault** — secure credential storage
- **Managed Identity** — passwordless authentication between services

Architecture:
1. **Automation runbook** — creates a Batch job and submits the chunk task
2. **Chunk task** — divides repos.csv into partitions and submits processor tasks
3. **Processor tasks** — multiple workers process different repository ranges in parallel
4. **Auto-scale pool** — scales nodes up for pending tasks, back to zero when idle

## Prerequisites

- Azure subscription with appropriate permissions
- Terraform installed (>= 1.0)
- Docker for building the image
- Azure CLI (`az`) configured
- Azure Container Registry (ACR)
- repos.csv file with repositories to ingest
- Azure Key Vault for storing secrets
- Access to a Maven-compatible repository (Artifactory, Nexus, etc.)

## Quick start

### 1. Prepare your repository list

Create or edit `../../repos.csv` with your repositories.

```csv
cloneUrl,branch,origin,path
https://github.com/org/repo1,main,github.com,org/repo1
https://github.com/org/repo2,main,github.com,org/repo2
```

### 2. Build and push Docker image

```bash
# Login to ACR
az acr login --name myregistry

# Build the image from repository root
docker build -t mass-ingest:latest ../..

# Tag for ACR
docker tag mass-ingest:latest myregistry.azurecr.io/mass-ingest:latest

# Push
docker push myregistry.azurecr.io/mass-ingest:latest
```

### 3. Store secrets in Azure Key Vault

#### 3a. Moderne token

```bash
az keyvault secret set \
  --vault-name your-keyvault \
  --name moderne-token \
  --value "your-moderne-token"
```

#### 3b. Git credentials

For username+token authentication:

```bash
az keyvault secret set \
  --vault-name your-keyvault \
  --name git-credentials \
  --value "https://username:token@github.com
https://username:token@gitlab.com"
```

For SSH key authentication:

```bash
az keyvault secret set \
  --vault-name your-keyvault \
  --name ssh-private-key \
  --file id_ed25519
```

#### 3c. Publishing credentials

```bash
# For password authentication
az keyvault secret set \
  --vault-name your-keyvault \
  --name publish-user \
  --value "your-artifactory-user"

az keyvault secret set \
  --vault-name your-keyvault \
  --name publish-password \
  --value "your-artifactory-password"

# Or for token authentication
az keyvault secret set \
  --vault-name your-keyvault \
  --name publish-token \
  --value "your-publishing-token"
```

### 4. Configure Terraform variables

Copy and edit the example:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

See `terraform/terraform.tfvars.example` for all available options.

### 5. Deploy infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

This creates:
- Batch account and auto-scaling pool
- Automation account with scheduled runbook
- Managed identity with Key Vault and ACR access
- NSG rule for metrics scraping

### 6. Trigger manually (optional)

```bash
# Create a job
az batch job create \
  --account-name massingest \
  --id mass-ingest-manual \
  --pool-id mass-ingest-pool

# Submit chunk task
az batch task create \
  --account-name massingest \
  --job-id mass-ingest-manual \
  --task-id chunk \
  --command-line "./chunk.sh repos.csv 10"
```

## How it works

### Automation runbook
1. Creates a new Batch job on each scheduled run
2. Submits the chunk task with environment variables (`BATCH_JOB_ID`, `IMAGE`, etc.)

### Chunk task
1. Downloads `repos.csv` (from Azure Blob, HTTP, or local)
2. Calculates number of repositories and partitions
3. Submits processor tasks to the same Batch job

### Processor tasks
Each processor task:
1. Receives `--start X --end Y` parameters
2. Selects only repos X through Y from repos.csv
3. Clones, builds, and publishes LSTs for those repositories

### Auto-scale pool
- Evaluates pending/active tasks every 5 minutes
- Scales up dedicated nodes to match task count (up to `max_nodes`)
- Scales back to zero when all tasks complete
- Uses `taskcompletion` deallocation to avoid interrupting running tasks

## Configuration

### VM size

Default: `Standard_D4s_v5` (4 vCPU, 16 GB RAM)

Adjust in `terraform.tfvars`:
```hcl
vm_size = "Standard_D8s_v5"  # 8 vCPU, 32 GB RAM
```

### Pool scaling

```hcl
max_nodes = 64  # Maximum concurrent VMs
```

### Partition size

```hcl
chunk_size = 10  # Repositories per worker
```

## Monitoring

### Azure Portal

Monitor jobs in the Azure Portal:
- **Batch accounts** → your account → **Jobs** — see all jobs and task status
- **Batch accounts** → your account → **Pools** — see node scaling and utilization

### CLI

```bash
# List tasks in a job
az batch task list --account-name massingest --job-id <job-id> --output table

# View task output
az batch task file download \
  --account-name massingest \
  --job-id <job-id> \
  --task-id processor-0 \
  --file-path stdout.txt \
  --destination ./stdout.txt
```

### Azure Monitor

View logs via Azure Monitor:
```bash
az monitor log-analytics query \
  --workspace <workspace-id> \
  --analytics-query "AzureBatchJobLog | where TimeGenerated > ago(24h)"
```

## Cost optimization

### Low-priority (Spot) nodes

Use low-priority nodes for significant cost savings (up to 80% discount):

Modify the auto-scale formula in `main.tf`:
```hcl
formula = <<-EOT
  $totalNodes = max($PendingTasks.GetSample(TimeInterval_Minute * 5, 0), $ActiveTasks.GetSample(TimeInterval_Minute * 5, 0));
  $targetNodes = min($totalNodes, ${var.max_nodes});
  $TargetLowPriorityNodes = $targetNodes;
  $NodeDeallocationOption = taskcompletion;
EOT
```

> **Note:** Low-priority nodes can be preempted. Tasks on preempted nodes will be re-queued automatically.

### Auto-scaling

The pool already scales to zero when idle — you only pay for VMs while tasks are running.

## Troubleshooting

### Pool won't scale up

- Check Azure Batch quotas: **Batch accounts** → **Quotas** in the portal
- Verify the subnet has enough available IP addresses
- Check NSG allows outbound internet access (for pulling images and cloning repos)
- Verify the VM size is available in your region

### Tasks fail immediately

- Check container image is accessible from ACR
- Verify the managed identity has `AcrPull` role
- Review task stdout/stderr in the portal or via CLI
- Check Key Vault access policy grants `Get` and `List` permissions

### Out of memory errors

Increase VM size:
```hcl
vm_size = "Standard_D8s_v5"  # 8 vCPU, 32 GB RAM
```

Or reduce chunk size to process fewer repos per worker:
```hcl
chunk_size = 5
```

### Container image pull failures

- Verify ACR login server matches the image URL
- Check managed identity is assigned to the pool
- Ensure `container_registries` block references the correct ACR

## Cleanup

Remove all resources:

```bash
cd terraform
terraform destroy
```

Note: This does not delete:
- Container images in ACR
- Secrets in Key Vault
- Azure Monitor logs

## Storage options

### Maven/Artifactory (recommended)

The primary storage option. Works with any Maven-compatible repository:

```hcl
publish_url = "https://artifactory.example.com/artifactory/moderne-ingest/"
```

Credentials stored in Key Vault as `publish-user`/`publish-password` or `publish-token`.

### Azure Blob Storage (optional)

Azure Blob does not have a native S3-compatible API. If you need object storage, you can deploy [MinIO](https://min.io/) as an S3-compatible gateway in front of Azure Blob Storage. This adds operational complexity — Maven/Artifactory is simpler.

## Scaling guidance

| Repository count | Recommended config |
|---|---|
| < 100 | Use 1-quickstart or 2-observability |
| 100-1,000 | 1-2 workers |
| 1,000-10,000 | 5-10 workers |
| 10,000-50,000 | 10-50 workers |
| 50,000+ | 50+ workers, adjust max_nodes |

## Security considerations

- **Secrets**: Stored in Azure Key Vault, never in code
- **Identity**: Managed Identity for passwordless auth to Key Vault and ACR
- **Network**: NSG restricts inbound, allows outbound
- **Authentication**: AAD-only authentication for Batch account

## Cost estimation

Example for 1,000 repositories:
- **Compute**: 20 workers x Standard_D4s_v5 x 3 hours ≈ $15
- **Storage**: Managed disks ≈ $2
- **Network**: Minimal (same region)
- **Total per run**: ~$17

Actual costs vary based on repository sizes, build complexity, VM sizes, and region.

## Additional resources

- [Moderne CLI documentation](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro)
- [repos.csv reference](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv)
- [Azure Batch documentation](https://learn.microsoft.com/en-us/azure/batch/)
- [Terraform AzureRM provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
