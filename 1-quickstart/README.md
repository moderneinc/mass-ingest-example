# Quickstart: Get started quickly

Single container deployment for ingesting repositories into Moderne.

**Best for:** < 1,000 repositories, development, testing, and learning how mass-ingest works.

## Overview

This example demonstrates the simplest way to run mass-ingest: a single Docker container that clones repositories, builds LSTs, and publishes them to your artifact repository.

## Prerequisites

- Docker installed
- Access to an artifact repository (Artifactory, Nexus, etc.) with Maven format support
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
docker build -t mass-ingest:basic ..
```

Optional build arguments:
- `MODERNE_CLI_VERSION` - Specific CLI version (optional, defaults to latest stable)

Example with specific CLI version:
```bash
docker build -t mass-ingest:basic --build-arg MODERNE_CLI_VERSION=3.50.0 ..
```

### 3. Run the container

Credentials are configured at runtime (not baked into the image):

```bash
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -e PUBLISH_URL=https://your-artifactory.com/artifactory/moderne-ingest/ \
  -e PUBLISH_USER=your-username \
  -e PUBLISH_PASSWORD=your-password \
  mass-ingest:basic
```

Required environment variables:
- `PUBLISH_URL` - Artifact repository URL
- `PUBLISH_USER` + `PUBLISH_PASSWORD` - Repository credentials (OR use PUBLISH_TOKEN)
- `PUBLISH_TOKEN` - Artifactory API token (alternative to user/password)

Optional environment variables:
- `MODERNE_TOKEN` - Moderne platform token
- `MODERNE_TENANT` - Moderne tenant name (e.g., "app" or "tenant-name")

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

If your repositories require authentication, uncomment and configure in `Dockerfile`:

```dockerfile
# For HTTPS authentication
COPY .git-credentials /root/.git-credentials
RUN git config --global credential.helper "store --file=/root/.git-credentials"
```

Create `.git-credentials` in the repository root:
```
https://username:token@github.com
https://username:token@gitlab.com
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
docker run -v /path/to/storage:/var/moderne mass-ingest:basic
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
  mass-ingest:basic
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

## Next steps

- **2-observability**: Add Docker Compose with Grafana/Prometheus for better monitoring
- **3-scalability**: Scale with parallel workers using Terraform/ECS

## Additional resources

- [Moderne CLI Documentation](https://docs.moderne.io/user-documentation/moderne-cli/)
- [repos.csv Format Reference](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv)
