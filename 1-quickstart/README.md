# Quickstart: Get started quickly

Single container deployment for ingesting repositories into Moderne.

**Best for:**
- Proof of concept deployments
- Development of the mass-ingest scripts
- Learning how mass-ingest works
- Simple use cases with small repository counts (<1,000 repos)

## Overview

This example demonstrates the simplest way to run mass-ingest: a single Docker container that clones repositories, builds LSTs, and publishes them to your artifact repository.

## Prerequisites

- Docker installed
- Access to one of the following storage options:
  - Amazon S3 bucket or S3-compatible storage (MinIO, etc.)
  - Artifactory with Maven 2 format support
  - Nexus or other Maven-compatible repository
- A `repos.csv` file listing repositories to ingest

## Quick start

### 1. Prepare your repository list

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

### 2. Build the Docker image

```bash
docker build -t mass-ingest:quickstart ..
```

Optional build arguments:
- `MODERNE_CLI_VERSION` - Specific CLI version (optional, defaults to latest stable)

Example with specific CLI version:
```bash
docker build -t mass-ingest:quickstart --build-arg MODERNE_CLI_VERSION=3.50.0 ..
```

### 3. Run the container

Credentials are configured at runtime (not baked into the image). You can use S3, Artifactory, or any Maven-compatible repository.

#### Option A: Using S3 Storage

For S3 or S3-compatible storage, the Moderne CLI supports all standard AWS credential providers.

**S3 Configuration Variables:**
- `PUBLISH_URL` - S3 bucket URL (must start with `s3://`)
- `S3_PROFILE` - AWS profile name (optional, uses AWS credential chain by default)
- `S3_REGION` - AWS region (optional, for cross-region bucket access)
- `S3_ENDPOINT` - S3 endpoint URL (optional, for S3-compatible services like MinIO)

**AWS Authentication:**
The container supports all standard AWS authentication methods:
- IAM roles (automatic on EC2/ECS/Fargate)
- Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
- AWS credentials file with profiles
- AWS SSO
- For detailed options, see [AWS CLI Configuration documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html)

**Option 1: Using AWS Environment Variables (Simplest)**
```bash
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -e PUBLISH_URL=s3://your-bucket \
  -e AWS_ACCESS_KEY_ID=your-access-key \
  -e AWS_SECRET_ACCESS_KEY=your-secret-key \
  -e AWS_REGION=us-east-1 \
  mass-ingest:quickstart
```

**Option 2: Using AWS Profile**
```bash
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -v ~/.aws:/root/.aws:ro \
  -e PUBLISH_URL=s3://your-bucket \
  -e S3_PROFILE=your-profile \
  mass-ingest:quickstart
```

**Option 3: Using AWS SSO**
```bash
# First, login via AWS SSO
aws sso login --profile your-profile

# Run with mounted AWS config
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -v ~/.aws:/root/.aws:ro \
  -e PUBLISH_URL=s3://your-bucket \
  -e S3_PROFILE=your-profile \
  mass-ingest:quickstart
```

**Option 4: Using Temporary Credentials**
```bash
# Export credentials from AWS CLI (works with SSO, assume-role, etc.)
eval $(aws configure export-credentials --profile your-profile --format env)

docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -e PUBLISH_URL=s3://your-bucket \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN \
  -e AWS_REGION \
  mass-ingest:quickstart
```

**Example with MinIO (S3-compatible):**
```bash
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -e PUBLISH_URL=s3://moderne-lsts \
  -e S3_ENDPOINT=https://minio.example.com \
  -e AWS_ACCESS_KEY_ID=minio-access-key \
  -e AWS_SECRET_ACCESS_KEY=minio-secret-key \
  -e AWS_REGION=us-east-1 \
  mass-ingest:quickstart
```

#### Option B: Using Maven/Artifactory

For traditional artifact repositories:

```bash
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -e PUBLISH_URL=https://your-artifactory.com/artifactory/moderne-ingest/ \
  -e PUBLISH_USER=your-username \
  -e PUBLISH_PASSWORD=your-password \
  mass-ingest:quickstart
```

Maven/Artifactory environment variables:
- `PUBLISH_URL` - Artifact repository URL
- `PUBLISH_USER` + `PUBLISH_PASSWORD` - Repository credentials (OR use PUBLISH_TOKEN)
- `PUBLISH_TOKEN` - Artifactory API token (alternative to user/password)

#### Common Optional Variables

Optional environment variables for all storage types:
- `MODERNE_TOKEN` - Moderne platform token
- `MODERNE_TENANT` - Moderne tenant url (e.g., "https://app.moderne.io" or "https://tenant.moderne.io")

The container will:
1. Start metrics server on port 8080
2. Clone all repositories from repos.csv
3. Build LSTs for each repository
4. Publish LSTs to your artifact repository
5. Upload build logs
6. Exit when complete

### 4. Monitor progress

While the container is running, check metrics:

```bash
curl http://localhost:8080/prometheus
```

Or view logs:

```bash
docker logs -f <container-id>
```

## Configuration

### Repository authentication

If your repositories require authentication, create a `.git-credentials` file and mount it at runtime:

Create `.git-credentials`:
```
https://username:token@github.com
https://username:token@gitlab.com
```

Mount it when running the container:
```bash
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -v $(pwd)/.git-credentials:/root/.git-credentials:ro \
  -e PUBLISH_URL=https://your-artifactory.com/artifactory/moderne-ingest/ \
  -e PUBLISH_USER=your-username \
  -e PUBLISH_PASSWORD=your-password \
  mass-ingest:quickstart
```

Alternatively, use SSH keys by mounting your `.ssh` directory:
```bash
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -v $(pwd)/.ssh:/root/.ssh:ro \
  -e PUBLISH_URL=https://your-artifactory.com/artifactory/moderne-ingest/ \
  -e PUBLISH_USER=your-username \
  -e PUBLISH_PASSWORD=your-password \
  mass-ingest:quickstart
```

### Self-signed certificates

If your artifact repository or source control uses self-signed certificates:

```dockerfile
COPY mycert.crt /root/mycert.crt
RUN /usr/lib/jvm/temurin-21-jdk/bin/keytool -import -file /root/mycert.crt \
    -keystore /usr/lib/jvm/temurin-21-jdk/lib/security/cacerts
RUN mod config http trust-store edit java-home
```

### Maven settings

If your projects require custom Maven settings:

```dockerfile
COPY maven/settings.xml /root/.m2/settings.xml
RUN mod config build maven settings edit /root/.m2/settings.xml
```

### Additional language support

The Dockerfile includes commented sections for:
- Gradle installation
- Maven installation
- Android SDK
- Bazel
- Node.js
- Python
- .NET

Uncomment the relevant sections based on your needs.

## Storage requirements

The `/var/moderne` directory stores:
- Cloned repositories
- Build artifacts
- Build logs

Recommended storage:
- **Minimum**: 32 GB
- **1000+ repositories**: 64-128 GB

Mount a volume for persistent storage:
```bash
docker run -v /path/to/storage:/var/moderne mass-ingest:quickstart
```

## Build timeout

Builds automatically timeout after 45 minutes to prevent hanging indefinitely. This is configured in the publish.sh script.

## Continuous operation

For continuous ingestion, configure your container orchestrator to restart the container on a schedule. The container runs once and exits.

Example with Docker restart policy:
```bash
docker run -d \
  --restart unless-stopped \
  -v $(pwd)/data:/var/moderne \
  mass-ingest:quickstart
```

## Troubleshooting

### Container exits immediately
Check logs: `docker logs <container-id>`
- Verify PUBLISH_URL, PUBLISH_USER, PUBLISH_PASSWORD environment variables are correctly set
- Ensure repos.csv exists and is properly formatted

### Build failures
- Check individual repository logs in `/var/moderne/log.zip`
- Verify required JDK versions are installed
- Check Maven/Gradle wrapper availability

### Out of memory
Increase JVM memory in `Dockerfile`:
```dockerfile
RUN mod config java options edit "-Xmx8g -Xss3m"
```

## Additional resources

- [Moderne CLI documentation](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro)
- [repos.csv reference](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv)

## Alternative deployment options

- **2-observability**: Add Docker Compose with Grafana/Prometheus for better monitoring
- **3-scalability**: Scale with parallel workers using Terraform/ECS
