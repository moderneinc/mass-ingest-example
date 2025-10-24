# Mass ingest

Production-ready examples for ingesting large numbers of repositories into Moderne using the [Moderne CLI](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro).

## Choose your deployment stage

This repository provides three progressive deployment examples. Each stage is **completely independent** and self-contained - you can start at any stage based on your needs.

### 1-quickstart: Get started quickly

**Best for:**
- Quick proof of concept
- Small repository counts (< 1.000 repos)
- Development and testing
- Learning how mass-ingest works

**What's included:**
- Single Docker container
- Manual docker commands
- Basic monitoring via CLI metrics endpoint

**Resources needed:**
- 2 CPU cores
- 16 GB RAM
- 32+ GB disk

[→ Start with 1-quickstart](./1-quickstart/)

---

### 2-observability: Add monitoring and visibility

**Best for:**
- Production use on a single host
- Small repository counts (< 1.000 repos)
- Medium repository count with manual scaling (<10.000 repos)
- Need for operational visibility
- Continuous ingestion workflows

**What's included:**
- Docker Compose orchestration
- Integrated Grafana dashboards
- Prometheus metrics collection
- Automated restarts and scheduling

**Resources needed:**
- 3 CPU cores (2 for mass-ingest, 1 for monitoring)
- 18 GB RAM (16 for mass-ingest, 2 for monitoring)
- 50+ GB disk

[→ Start with 2-observability](./2-observability/)

---

### 3-scalability: Scale to production

**Best for:**
- Large repository counts (>10.000 repos)
- Parallel processing requirements
- Production deployment with automatic scaling
- Enterprise environments

**What's included:**
- AWS Batch for parallel workers
- Terraform infrastructure as code
- EventBridge Scheduler for automation
- Auto-scaling compute environment
- Production monitoring and cost optimization

**Resources needed:**
- AWS account with appropriate permissions
- Terraform >= 1.0
- VPC with NAT gateway
- Configurable compute (scales from 0 to 256+ vCPUs)

[→ Start with 3-scalability](./3-scalability/)

---

## Repository structure

```
mass-ingest-example/
├── Dockerfile            # Container image definition (used by all stages)
├── publish.sh            # Main ingestion script
├── publish.ps1           # PowerShell version
├── repos.csv             # Example repository list
│
├── 1-quickstart/         # Single container deployment
│   └── README.md
│
├── 2-observability/      # Docker Compose with monitoring
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── observability/    # Grafana and Prometheus configs
│   └── README.md
│
└── 3-scalability/        # AWS Batch production deployment
    ├── chunk.sh          # Batch job partitioning script
    ├── terraform/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── README.md
```

## Prerequisites (all stages)

Before starting with any stage, you'll need:

1. **Repository list**: Create `repos.csv` with repositories to ingest
   ```csv
   cloneUrl,branch,origin,path
   https://github.com/org/repo1,main,github.com,org/repo1
   https://github.com/org/repo2,main,github.com,org/repo2
   ```

2. **Artifact repository**: Maven-formatted repository for publishing LSTs
   - Artifactory, Nexus, or similar
   - Dedicated repository recommended (separate from other artifacts)
   - Credentials with publish permissions

3. **Source control access**: If repositories require authentication
   - Service account with read access to all repositories
   - Personal access token or credentials

4. **Docker**: Installed and running (for stages 1 and 2)

5. **AWS account**: Required only for stage 3

## Quick comparison

| Feature | 1-quickstart | 2-observability | 3-scalability |
|---------|---------|-----------|---------|
| **Deployment** | Single container | Docker Compose | AWS Batch + Terraform |
| **Monitoring** | CLI metrics endpoint | Grafana + Prometheus | CloudWatch + optional Grafana |
| **Scaling** | Manual | Single host | Auto-scaling parallel workers |
| **Scheduling** | Manual/cron | Docker restart policy | EventBridge Scheduler |
| **Cost** | Lowest | Low | Scales with usage |
| **Setup time** | 15 minutes | 30 minutes | 1-2 hours |
| **Ideal repo count** | < 100 | 100-1000 | 1000+ |
| **Parallel processing** | No | No | Yes |

## Common configuration

All stages share the same core configuration needs:

### Environment variables

- `PUBLISH_URL` - Artifact repository URL (e.g., `https://artifactory.example.com/artifactory/moderne-ingest/`)
- `PUBLISH_USER` - Repository username
- `PUBLISH_PASSWORD` - Repository password
- `PUBLISH_TOKEN` - Alternative to user/password for JFrog
- `MODERNE_TENANT` - Your Moderne tenant url (optional)
- `MODERNE_TOKEN` - Moderne API token (optional)

### Repository authentication

For private repositories, credentials are mounted at runtime (never baked into images):
- `.git-credentials` file for HTTPS
- `.ssh` directory for SSH

See each stage's README for specific mounting instructions.

### Repository list format
The `repos.csv` file must include:
- `cloneUrl` - Full git clone URL
- `branch` - Branch to build
- `origin` - Source identifier (e.g., `github.com`)
- `path` - Repository path/identifier

See [repos.csv documentation](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv) for advanced options.

### Build arguments

All Dockerfiles support:
- `MODERNE_CLI_VERSION` - Specific CLI version (defaults to latest stable)
- `MODERNE_CLI_STAGE` - Use `staging` for pre-release versions

## Generating repository lists

We provide scripts to generate `repos.csv` from various sources:
- [Repository Fetchers](https://github.com/moderneinc/repository-fetchers) - Scripts for GitHub, GitLab, Bitbucket, and more

## Support and documentation

- [Moderne CLI documentation](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro)
- [repos.csv reference](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv)
- [Report issues](https://github.com/moderneinc/mass-ingest-example/issues)

## License

This example code is provided as-is for use with Moderne products.
