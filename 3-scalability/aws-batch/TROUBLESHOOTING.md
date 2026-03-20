## Troubleshoot

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

### Chunk job doesn't submit workers
- Review CloudTrail for Access Denied errors related to the chunk job's IAM role
- Check IAM role has `batch:SubmitJob` permission
- Verify job queue and definition ARNs
- Review chunk.sh script logs