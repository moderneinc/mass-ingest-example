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
├── 3-scalability/        # AWS Batch production deployment
│   ├── chunk.sh          # Batch job partitioning script
│   ├── terraform/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── README.md
│
└── diagnostics/          # Comprehensive diagnostic system
    ├── diagnose.sh       # Main script with shared functions
    └── checks/           # Modular check scripts
        ├── system.sh     # CPUs, memory, disk space
        ├── tools.sh      # git, curl, jq, etc.
        ├── docker.sh     # CPU arch, emulation detection
        ├── java.sh       # JDKs, JAVA_HOME
        ├── cli.sh        # mod CLI version, config
        ├── config.sh     # Env vars, credentials
        ├── repos-csv.sh  # File validation, columns, origins
        ├── network.sh    # Connectivity to all hosts
        ├── ssl.sh        # SSL handshakes, cert expiry
        ├── auth-publish.sh # Write/read/delete test
        ├── auth-scm.sh   # Test clone with timeout
        ├── publish-latency.sh # Throughput and rate limiting
        ├── maven-repos.sh # Maven repos from settings.xml
        └── dependency-repos.sh # User-specified repos (Gradle, etc.)
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

### Dependency repositories (optional)

Create `dependency-repos.csv` to test connectivity to Maven/Gradle dependency repositories during diagnostics:

```csv
url,username,password,token
https://nexus.example.com/releases,${NEXUS_USER},${NEXUS_PASSWORD},
https://artifactory.example.com/libs,,,${ARTIFACTORY_TOKEN}
https://repo.spring.io/release,,,
```

- Use `username` + `password` for basic auth
- Use `token` for bearer auth (leave username/password empty)
- Leave all auth fields empty for anonymous access
- Use `${ENV_VAR}` syntax to reference environment variables

See `dependency-repos.csv.example` for a template.

### Build arguments

All Dockerfiles support:
- `MODERNE_CLI_VERSION` - Specific CLI version (defaults to latest stable)
- `MODERNE_CLI_STAGE` - Use `staging` for pre-release versions

## Generating repository lists

We provide scripts to generate `repos.csv` from various sources:
- [Repository Fetchers](https://github.com/moderneinc/repository-fetchers) - Scripts for GitHub, GitLab, Bitbucket, and more

## Diagnostics

The `diagnostics/` directory contains a comprehensive diagnostic system to validate your mass-ingest setup before starting ingestion.

### Diagnostic mode (full validation)

Run comprehensive diagnostics without starting ingestion:

```bash
DIAGNOSE=true docker compose up
```

This validates the entire setup and produces a detailed report:
- System (CPUs, memory, disk space)
- Required tools (git, curl, jq, unzip, tar)
- Docker image (CPU architecture, emulation detection)
- Java/JDKs (available JDKs, JAVA_HOME)
- Moderne CLI (version, build config, proxy, trust store, tenant)
- Configuration (env vars, credentials, git credentials)
- repos.csv (file validation, columns, origins, sample entries)
- Network (Maven Central, Gradle plugins, publish URL, SCM hosts)
- SSL/Certificates (handshakes, expiry warnings)
- Authentication (publish write/read/delete test, SCM clone test)
- Publish latency (throughput testing, rate limit detection)
- Maven repositories (dependency repo connectivity from settings.xml)
- Dependency repositories (user-specified repos from dependency-repos.csv)

The container exits with code 0 if all checks pass, or 1 if any failures are detected.

**Use cases:**
- Initial setup validation before first real run
- After configuration changes before deploying
- Troubleshooting when something stops working
- Generating diagnostic output to send to Moderne support

### Diagnostics at startup

Set `DIAGNOSE_ON_START=true` to run diagnostics before ingestion starts:

```bash
docker run -e DIAGNOSE_ON_START=true ...
```

This runs all diagnostic checks and then proceeds to normal ingestion regardless of the results. Use this to capture diagnostic output in your logs while still attempting ingestion.

### Running diagnostics directly

You can run the main diagnostic script or individual checks:

```bash
# Full diagnostics
./diagnostics/diagnose.sh

# Individual checks can be run directly
./diagnostics/checks/docker.sh
./diagnostics/checks/network.sh
./diagnostics/checks/auth-publish.sh
```

### Example output

```
Mass-ingest Diagnostics
Generated: 2025-01-20 14:32 UTC

=== System ===
[PASS] CPUs: 4
[PASS] Memory: 12.5GB / 16.0GB available
[PASS] Disk (data): 45.2GB / 100.0GB available

=== Required tools ===
[PASS] git: 2.39.3
[PASS] curl: 8.4.0
[PASS] jq: 1.7
[PASS] unzip: 6.00
[PASS] tar: 1.35

=== Docker image ===
[PASS] Architecture: x86_64 (no emulation detected)
[PASS] Base image: Ubuntu 24.04.1 LTS

=== Java/JDKs ===
[PASS] JAVA_HOME: /opt/java/openjdk
       Detected JDKs (mod config java jdk list):
         21.0.1-tem   $JAVA_HOME     /opt/java/openjdk
         17.0.9-tem   OS directory   /usr/lib/jvm/temurin-17
[PASS] 5 JDK(s) available in /usr/lib/jvm/

=== Moderne CLI ===
[PASS] CLI installed: v3.56.0
       Configuration:
         Trust store: default JVM
         Proxy: not configured
         LST artifacts: Maven (https://artifactory.company.com/moderne)
         Build timeouts: default

=== Configuration ===
[PASS] DATA_DIR: /var/moderne (writable)
[PASS] PUBLISH_URL: https://artifactory.company.com/moderne
[PASS] Publish credentials: PUBLISH_USER/PASSWORD set
       Git credentials:
[PASS] HTTPS credentials: /root/.git-credentials (2 entries)

=== repos.csv ===
[PASS] File: /app/repos.csv (exists)
[PASS] Repositories: 427
[PASS] Required columns: cloneUrl, branch (present)
[PASS] Additional columns: origin, path (present)
       Repositories by origin:
         github.com: 412 repos
         gitlab.internal.com: 15 repos
       Sample entries (first 3):
         https://github.com/company/repo-one (main)
         https://github.com/company/repo-two (main)

=== Network ===
[PASS] Maven Central: reachable (45ms)
[PASS] Gradle plugins: reachable (52ms)
[PASS] PUBLISH_URL: reachable (23ms)
[PASS] github.com: reachable (31ms)
[FAIL] gitlab.internal.com: unreachable

=== SSL/Certificates ===
[PASS] artifactory.company.com: SSL OK (expires in 285 days)
[PASS] github.com: SSL OK (expires in 180 days)
[PASS] repo1.maven.org: SSL OK (expires in 340 days)

=== Authentication - Publish ===
[PASS] Write test: succeeded (HTTP 201)
[PASS] Read test: succeeded (HTTP 200)
[PASS] Overwrite test: succeeded (HTTP 201)
[PASS] Delete test: succeeded (HTTP 204)

=== Authentication - SCM ===
       Testing clone: repo-one (main)
[PASS] Clone test: succeeded (12s)
       Cleaned up test clone

=== Publish latency ===
       Running sequential latency test (10 requests)...
       Sequential: min=23ms avg=45ms max=89ms
[PASS] Average latency: 45ms
       Running parallel throughput test (3 × 100 concurrent)...
       Parallel batches: 1250ms, 1180ms, 1320ms (avg 12ms/req)
[PASS] Parallel throughput: 12ms/request

=== Maven repositories ===
       Using: /root/.m2/settings.xml
[PASS] central: reachable (42ms)
[PASS] internal-nexus: reachable (18ms) (via mirror: nexus-mirror)
       Tip: High latency to dependency repos can significantly slow builds.

=== Dependency repositories ===
       Using: ./dependency-repos.csv
[PASS] nexus.example.com: reachable (23ms) (basic auth)
[PASS] repo.spring.io: reachable (67ms)

========================================
RESULT: 1 failure(s), 0 warning(s), 24 passed
========================================
```

## Support and documentation

- [Moderne CLI documentation](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro)
- [repos.csv reference](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv)
- [Report issues](https://github.com/moderneinc/mass-ingest-example/issues)

## License

This example code is provided as-is for use with Moderne products.
