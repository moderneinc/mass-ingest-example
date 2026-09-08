# Scalability: Azure Batch

Production-scale deployment using Azure Batch for parallel repository processing.

**Best for:**
- Large repository counts (> 1,000 repos)
- Enterprise production environments on Azure
- Automatic scaling and parallel processing with no cluster to operate

> [!IMPORTANT]
> This example has not yet been integration-tested end to end on an Azure subscription. Each moving part follows the documented Azure Batch, Key Vault and Automation APIs, but expect to spend an afternoon on the first run. See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for the failure modes to look at first.

## Overview

This example deploys mass-ingest at scale using:
- **Azure Batch**: managed batch processing with an auto-scaling VM pool that runs the mass-ingest container
- **Azure Automation**: a scheduled PowerShell runbook that starts a run every day
- **Azure Key Vault**: credential storage, read by the tasks at runtime
- **Managed Identity**: one user-assigned identity for the pool nodes and the runbook, so no keys are stored anywhere

Architecture:
1. **Automation runbook** creates a Batch job and submits the `chunk` task
2. **Chunk task** (`chunk.sh`) reads `repos.csv`, calculates partitions and adds one `processor-N` task per partition to the same job
3. **Processor tasks** (`task.sh`) load credentials from Key Vault and run `publish.sh --start X --end Y` for their slice
4. **Auto-scale pool** grows to one node per pending task (up to `max_nodes`) and shrinks to zero when the job is done

```
┌────────────────┐     ┌────────────┐     ┌───────────────┐
│  Automation    │────>│ chunk task │────>│ processor-0   │──> task.sh repos.csv --start 1  --end 11
│  runbook (cron)│     │ (chunk.sh) │     │ processor-1   │──> task.sh repos.csv --start 11 --end 21
└────────────────┘     └────────────┘     │     ...       │
                                          │ processor-N   │──> task.sh repos.csv --start X  --end Y
                                          └───────────────┘
```

The container image needs no Azure tooling. `chunk.sh` and `task.sh` use `curl` and `jq` (already in the image) against the Instance Metadata Service, Key Vault and the Batch REST API.

## Prerequisites

- Azure subscription with **Contributor** on a resource group (creates a Batch account, pool, user-assigned identity and Automation account) and permission to create role assignments on the Batch account, Key Vault and ACR (**User Access Administrator** or **Owner** on those resources)
- The `Microsoft.Batch`, `Microsoft.Automation` and `Microsoft.ManagedIdentity` resource providers registered on the subscription. Terraform does not register providers here (Contributor on a resource group is not enough to do so); a subscription owner runs `az provider register --namespace Microsoft.Batch` and the same for the other two once
- Existing virtual network and subnet with outbound internet access for the pool nodes
- Existing Azure Container Registry (ACR)
- Existing Azure Key Vault (access-policy or RBAC authorization; terraform detects which). Use a vault dedicated to mass ingest: the pool identity gets read access to every secret in it
- Terraform >= 1.5 and the Azure CLI (`az login`)
- Docker for building the image
- A Maven-compatible repository (Artifactory, Nexus, etc.) to publish LSTs to
- Batch quota: at least `max_nodes` dedicated cores of the chosen VM family in the region (**Batch accounts** > **Quotas** in the portal)

## Quick start

### 1. Prepare your repository list

Create `repos.csv` in the repository root:

```csv
cloneUrl,branch,origin,path
https://github.com/org/repo1,main,github.com,org/repo1
https://github.com/org/repo2,main,github.com,org/repo2
```

Two ways to give it to the tasks:

**Option A: Bake into the image** (default). The `Dockerfile` copies `repos.csv` into `/app`. Set `csv_file = "repos.csv"` and rebuild the image when the list changes.

**Option B: HTTPS URL.** Set `csv_file` to a URL that the nodes can fetch without extra authentication, for example a blob SAS URL:

```bash
az storage blob upload --account-name yourstorage --container-name ingest --name repos.csv --file repos.csv --auth-mode login
az storage blob generate-sas --account-name yourstorage --container-name ingest --name repos.csv \
  --permissions r --expiry 2027-01-01 --https-only --full-uri --auth-mode login --as-user
```

### 2. Build and push the Docker image

Uncomment the Azure Batch lines in the `Dockerfile` so `chunk.sh` and `task.sh` end up in the image:

```dockerfile
COPY --chmod=755 3-scalability/azure-batch/chunk.sh chunk.sh
COPY --chmod=755 3-scalability/azure-batch/task.sh task.sh
```

Then build with the repository root as the Docker context (the command below runs from this directory) and push to ACR:

```bash
az acr login --name myregistry

docker build -t mass-ingest:latest ../..
docker tag mass-ingest:latest myregistry.azurecr.io/mass-ingest:latest
docker push myregistry.azurecr.io/mass-ingest:latest
```

### 3. Store secrets in Azure Key Vault

`task.sh` reads these secret names. A missing secret is skipped, so only store what you need. Publishing credentials are required: either `publish-user` and `publish-password`, or `publish-token`. Git credentials are only needed for private repositories.

| Secret name        | Environment variable  | Purpose                                          | Required                              |
|--------------------|-----------------------|--------------------------------------------------|---------------------------------------|
| `moderne-token`    | `MODERNE_TOKEN`       | Moderne API token                                | No                                    |
| `git-credentials`  | `GIT_CREDENTIALS`     | `https://user:token@host` lines for HTTPS clones | For private repos over HTTPS          |
| `ssh-private-key`  | `GIT_SSH_CREDENTIALS` | Private key for SSH clones                       | For private repos over SSH            |
| `publish-user`     | `PUBLISH_USER`        | Maven repository user                            | Yes, with `publish-password`          |
| `publish-password` | `PUBLISH_PASSWORD`    | Maven repository password                        | Yes, with `publish-user`              |
| `publish-token`    | `PUBLISH_TOKEN`       | Artifactory token                                | Yes, instead of user and password     |

```bash
az keyvault secret set --vault-name your-keyvault --name moderne-token --value "your-moderne-token"

# HTTPS git credentials (one URL per line)
az keyvault secret set --vault-name your-keyvault --name git-credentials \
  --value "https://username:token@github.com
https://username:token@gitlab.com"

# Or SSH
az keyvault secret set --vault-name your-keyvault --name ssh-private-key --file id_ed25519

# Publishing: user/password ...
az keyvault secret set --vault-name your-keyvault --name publish-user --value "your-artifactory-user"
az keyvault secret set --vault-name your-keyvault --name publish-password --value "your-artifactory-password"
# ... or a token
az keyvault secret set --vault-name your-keyvault --name publish-token --value "your-publishing-token"
```

### 4. Configure Terraform variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

See `terraform/terraform.tfvars.example` for all options. Pick a `batch_account_name` that is unique in the region.

### 5. Deploy infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

This creates:
- A user-assigned managed identity with `AcrPull` on the registry, secret read access on the Key Vault (access policy or the `Key Vault Secrets User` role, depending on the vault), and `Azure Batch Job Submitter` plus `Reader` on the Batch account
- A Batch account (Entra ID authentication only) and an auto-scaling container pool using that identity
- An Automation account, runbook and daily schedule
- Optionally, an NSG rule that allows metrics scraping on port 8080 from inside the VNet

Role assignments can take a few minutes to propagate. Wait before the first run.

### 6. Trigger a run manually

Start the runbook (the identity, image and Key Vault are baked into it):

```bash
az automation runbook start \
  --resource-group your-resource-group \
  --automation-account-name mass-ingest-automation \
  --name mass-ingest-trigger
```

## How it works

### Automation runbook
1. Signs in with the user-assigned identity (`Connect-AzAccount -Identity -AccountId <client id>`)
2. Creates a Batch job `mass-ingest-<timestamp>` on the pool
3. Adds the `chunk` task: the mass-ingest image running `/app/chunk.sh <csv_file> <chunk_size>`, with the non-secret settings (`IMAGE`, `KEY_VAULT_URI`, `AZURE_CLIENT_ID`, `MODERNE_TENANT`, `PUBLISH_URL`, task time limit and retries) as environment variables

### Chunk task
1. Downloads `repos.csv` when `csv_file` is a URL, or reads it from the image
2. Calculates the number of partitions
3. Gets a Batch token for the pool identity from the Instance Metadata Service and adds the `processor-N` tasks to its own job through the Batch REST API, 100 per request, each limited to `task_max_wall_clock_time` and `task_max_retry_count` retries
4. Marks the job to terminate once all tasks complete, so finished jobs do not pile up

### Processor tasks
Each processor task runs `task.sh`, which:
1. Gets a Key Vault token for the pool identity from the Instance Metadata Service
2. Reads the secrets listed above and exports them
3. Runs `publish.sh <csv_file> --start X --end Y`, which clones, builds and publishes LSTs for repos X to Y

Secrets never appear in task definitions, the portal or the Batch API. Only the tasks themselves see them.

### Auto-scale pool
- Evaluates every 5 minutes (the minimum Batch allows)
- Sets the dedicated node count to the number of pending tasks, capped at `max_nodes`
- Scales back to zero when no tasks are pending
- Uses `taskcompletion` deallocation so a node is only removed once its task has finished
- Runs one task per node, so every processor task gets the whole VM

### Container tasks run as root

Batch runs container tasks as its own node user unless told otherwise, and that user cannot write the Moderne CLI configuration under `/home/moderne` in the image. Both task types therefore use the pool auto-user with `admin` elevation, which runs the container as root. Inside the container everything still lives under `/app` and `/home/moderne` as in the other stages.

## Configuration

### VM size

Default: `Standard_D4s_v5` (4 vCPU, 16 GB RAM)

```hcl
vm_size = "Standard_D8s_v5"  # 8 vCPU, 32 GB RAM
```

### Pool scaling

```hcl
max_nodes = 64  # Maximum concurrent VMs (and processor tasks)
```

### Partition size

```hcl
chunk_size = 10  # Repositories per processor task
```

### Task time limit and retries

```hcl
task_max_wall_clock_time = "PT4H"  # Batch kills a processor task that runs longer and frees its node
task_max_retry_count     = 0       # Retries restart the whole slice; keep chunk_size small if you raise this
```

### Schedule

The runbook runs daily. Change `azurerm_automation_schedule.daily` in `main.tf` for another cadence (Azure Automation supports hourly, daily, weekly and monthly schedules).

## Monitoring

### Azure Portal

- **Batch accounts** > your account > **Jobs**: job and task status, task `stdout.txt` / `stderr.txt`
- **Batch accounts** > your account > **Pools**: node count and scaling history
- **Automation accounts** > your account > **Jobs**: runbook output and errors

### CLI

The account only allows Entra ID authentication, so sign in with `az login` and pass the endpoint (`terraform output batch_account_endpoint`):

```bash
export AZURE_BATCH_ENDPOINT=https://massingest.eastus.batch.azure.com
export AZURE_BATCH_ACCOUNT=massingest

az batch job list --output table
az batch task list --job-id mass-ingest-20260908-000000 --output table

# Task output
az batch task file download --job-id mass-ingest-20260908-000000 --task-id processor-0 \
  --file-path stdout.txt --destination ./processor-0-stdout.txt
```

### Metrics

The CLI exposes Prometheus metrics on port 8080 inside each container. Set `nsg_name` so the pool subnet's NSG allows scraping from the VNet, and point a Prometheus in the VNet at the node IPs (see `2-observability` for the Grafana dashboard).

## Cost optimization

### Spot nodes

Change the auto-scale formula in `main.tf` to target `$TargetLowPriorityNodes` instead of `$TargetDedicatedNodes` to run on Spot VMs (up to 80% cheaper). Spot nodes can be evicted; an evicted task is requeued and starts its slice over, so keep `chunk_size` small when using them.

### Scale to zero

The pool scales to zero when idle, so you only pay for VMs while tasks are running. The Automation account and Batch account have no idle cost beyond the Automation minutes for the daily runbook.

## Troubleshooting

See the dedicated [troubleshooting](./TROUBLESHOOTING.md) page.

## Cleanup

```bash
cd terraform
terraform destroy
```

This does not delete container images in ACR, secrets in Key Vault, or the VNet, subnet and NSG you supplied.

## Storage options

### Maven/Artifactory (recommended)

Works with any Maven-compatible repository:

```hcl
publish_url = "https://artifactory.example.com/artifactory/moderne-ingest/"
```

Credentials come from Key Vault as `publish-user`/`publish-password` or `publish-token`.

### Azure Blob Storage

Azure Blob has no S3-compatible API, and the Moderne CLI publishes LSTs to Maven repositories or S3. To publish to Blob you would need an S3-compatible gateway such as [MinIO](https://min.io/) in front of it. Maven/Artifactory is simpler.

## Scaling guidance

| Repository count | Recommended config                                 |
|------------------|----------------------------------------------------|
| < 100            | Use 1-quickstart or 2-observability                |
| 100-1,000        | `max_nodes = 10`, `chunk_size = 10`                |
| 1,000-10,000     | `max_nodes = 50`, `chunk_size = 10`                |
| 10,000+          | `max_nodes = 100+`, request Batch core quota first |

## Security considerations

- **Secrets**: stored in Key Vault and read by the tasks at runtime with the pool identity. They are not part of any task definition, so they are not visible through the Batch API or portal.
- **Identity**: one user-assigned managed identity, no keys. It holds `AcrPull`, Key Vault secret read, and `Azure Batch Job Submitter` plus `Reader` on the Batch account (jobs and tasks only; it cannot change pools or the account). Every task on the pool can obtain tokens for this identity, so keep the Key Vault dedicated to mass ingest.
- **Batch account**: Entra ID authentication only; shared keys are disabled.
- **Network**: nodes need outbound HTTPS only (Batch uses simplified node communication). No inbound rules are required; the optional metrics rule is limited to the VNet.
- **Tasks**: run as the pool's admin auto-user, which makes them root inside the container (see above). Each node runs one task at a time and is discarded when the pool scales down.

## Cost estimation

Example for 1,000 repositories:
- **Compute**: 20 nodes x Standard_D4s_v5 x 3 hours ≈ $15
- **Storage**: OS disks ≈ $2
- **Automation**: within the free 500 minutes per month
- **Total per run**: ~$17

Actual costs vary with repository sizes, build complexity, VM sizes and region.

## Additional resources

- [Moderne CLI documentation](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro)
- [repos.csv reference](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv)
- [Azure Batch documentation](https://learn.microsoft.com/en-us/azure/batch/)
- [Container workloads on Azure Batch](https://learn.microsoft.com/en-us/azure/batch/batch-docker-container-workloads)
- [Managed identities in Batch pools](https://learn.microsoft.com/en-us/azure/batch/managed-identity-pools)
- [Terraform AzureRM provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
