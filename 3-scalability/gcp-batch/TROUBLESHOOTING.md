## Troubleshooting

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

### Workflow fails to create batch job

This usually occurs because the workflow service account lacks permissions.

- Verify the workflow service account has `roles/batch.jobsEditor`
- Verify the workflow service account has `roles/iam.serviceAccountUser` (needed to act as the batch task SA)
- Check Cloud Workflows execution logs in the console

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
