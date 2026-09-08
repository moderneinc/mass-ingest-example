## Troubleshooting

Start with the task output: **Batch accounts** > your account > **Jobs** > the job > the task > `stdout.txt` and `stderr.txt`. Every failure in `chunk.sh` and `task.sh` prints a line starting with `chunk:` or `task:` that names the failing call and the HTTP status.

### The runbook fails

Look at **Automation accounts** > your account > **Jobs** > the job > **Errors**.

- `Connect-AzAccount` fails: the Automation account must have the user-assigned identity attached (terraform does this) and the runbook must pass its client id with `-AccountId`.
- `Get-AzBatchAccount` or `New-AzBatchJob` returns 403 / `AuthorizationFailed`: the identity needs `Reader` and `Azure Batch Job Submitter` on the Batch account. Role assignments take a few minutes to propagate after `terraform apply`.
- `New-AzBatchJob` fails with `PoolNotFound`: the pool name in the runbook does not match; re-run `terraform apply`.
- Cmdlet not found: the Automation account imports the `Az` modules by default. If yours was created without them, add `Az.Accounts` and `Az.Batch` under **Modules**.

### The chunk task fails

- `/app/chunk.sh: no such file or directory`: the image was built without the Azure Batch `COPY` lines in the `Dockerfile`.
- `Could not get a Batch token from IMDS`: the pool has no user-assigned identity, or `AZURE_CLIENT_ID` does not match it. Both come from terraform; check the pool's **Identity** blade.
- `POST /jobs/.../addtaskcollection failed (HTTP 403)`: the identity lacks `Azure Batch Job Submitter` on the Batch account.
- `Could not download https://...`: the `csv_file` URL must be readable from the nodes without authentication (use a blob SAS URL) and the subnet must have outbound internet access.

### Processor tasks fail immediately

- `Access denied reading Key Vault secret` (HTTP 403): the identity needs secret read access on the vault. Terraform grants an access policy (`Get`) on access-policy vaults and `Key Vault Secrets User` on RBAC vaults. Check which model the vault uses under **Access configuration**, and whether a Key Vault firewall blocks the pool subnet.
- `Could not get a Key Vault token from IMDS`: see the chunk task section.
- `publish.sh` complains that `PUBLISH_URL` or credentials are missing: the secret names must match the table in the README exactly, and `publish_url` must be set in `terraform.tfvars`.
- Image pull errors on the pool (**Pools** > nodes > **Errors**): the identity needs `AcrPull` on the registry and `acr_name` must be set so the pool authenticates with it.

### Pool never scales up

- Check the Batch core quota for the VM family: **Batch accounts** > your account > **Quotas**. A new account often starts with zero dedicated cores and needs a quota request.
- The auto-scale formula runs every 5 minutes; the first nodes appear a few minutes after the chunk task adds tasks. **Pools** > the pool > **Auto scale** shows the last evaluation and any formula error.
- The subnet needs free IP addresses for `max_nodes` VMs.
- `target_node_communication_mode = "Simplified"` needs outbound HTTPS from the subnet to the `BatchNodeManagement.<region>` and `Storage.<region>` service tags.

### Processor tasks end after the time limit

Batch terminates a processor task that runs longer than `task_max_wall_clock_time` (default 4 hours) and the task shows as failed. Raise the limit for very large repositories, or lower `chunk_size` so each task has fewer repositories to build.

### `terraform apply` fails with `MissingSubscriptionRegistration`

The subscription has not registered a resource provider. A subscription owner runs `az provider register --namespace Microsoft.Batch` (or `Microsoft.Automation`, `Microsoft.ManagedIdentity`) and the apply can be retried once registration completes.

### Out of memory errors

Use a larger VM size or a smaller chunk size:

```hcl
vm_size    = "Standard_D8s_v5"  # 8 vCPU, 32 GB RAM
chunk_size = 5
```

### Jobs accumulate

`chunk.sh` sets `onAllTasksComplete = terminatejob`, so a job completes when its last processor task finishes. If a run failed before the chunk task got that far, delete the job by hand:

```bash
az batch job delete --job-id mass-ingest-20260908-000000 --yes
```

### Network timeouts

- Outbound internet is required to clone repositories, pull dependencies and publish LSTs. Check the subnet's route table and NSG outbound rules.
- Key Vault, ACR and the Batch service can all be reached over private endpoints if your subscription requires it; the scripts use the standard public hostnames, which resolve to the private endpoints when Private DNS is configured on the VNet.
