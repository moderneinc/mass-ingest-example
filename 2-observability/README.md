# Observability: Add monitoring and visibility

Docker Compose deployment with integrated Grafana and Prometheus monitoring.

**Best for:**
- Production deployments requiring monitoring and visibility
- When you need to track build metrics and performance
- Small to medium repository counts (< 1,000 repos single worker, < 10,000 repos with manual scaling)
- Teams that want pre-configured dashboards and alerting capabilities

## Overview

This example adds comprehensive observability to mass-ingest using:
- **Prometheus** - Metrics collection and storage
- **Grafana** - Visualization dashboards
- **Docker Compose** - Orchestrated deployment

## Prerequisites

- Docker and Docker Compose installed
- Access to an artifact repository (Artifactory, Nexus, etc.)
- A `repos.csv` file listing repositories to ingest

## Quick start

### 1. Configure environment variables

Copy the example environment file:

```bash
cp .env.example .env
```

Edit `.env` with your credentials:

```bash
PUBLISH_URL=https://your-artifactory.com/artifactory/moderne-ingest/
PUBLISH_USER=your-username
PUBLISH_PASSWORD=your-password
```

### 2. Prepare your repository list

Edit `../repos.csv` with your repositories:

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

### 3. Start all services

```bash
docker compose up -d
```

This starts:
- **mass-ingest** on port 8080 (metrics)
- **Prometheus** on port 9090
- **Grafana** on port 3000

### 4. Access monitoring

**Grafana dashboards:**
- URL: http://localhost:3000
- Username: `admin`
- Password: `admin`

**Prometheus:**
- URL: http://localhost:9090

**Raw metrics:**
```bash
curl http://localhost:8080/prometheus
```

### 5. View logs

```bash
docker compose logs -f mass-ingest
```

### 6. Stop services

```bash
docker compose down
```

To also remove the data volume:
```bash
docker compose down -v
```

## Configuration

### Build arguments

You can customize the CLI version as a build argument in `docker-compose.yml`:

```yaml
build:
  context: ..
  args:
    MODERNE_CLI_VERSION: 3.50.0  # Specific version
```

Credentials are configured at runtime via environment variables (not baked into the image). These are already configured in your `.env` file and passed through in `docker-compose.yml`.

### Repository authentication

Git authentication is already configured in the image. If your repositories require authentication, uncomment the volume mount in `docker-compose.yml`.

Create `.git-credentials`:
```
https://username:token@github.com
https://username:token@gitlab.com
```

Uncomment in `docker-compose.yml`:
```yaml
services:
  mass-ingest:
    volumes:
      - data:/var/moderne
      - ../repos.csv:/app/repos.csv
      - ./.git-credentials:/root/.git-credentials:ro  # Uncomment this line
```

Alternatively, use SSH keys by uncommenting the SSH volume mount:
```yaml
services:
  mass-ingest:
    volumes:
      - data:/var/moderne
      - ../repos.csv:/app/repos.csv
      - ./.ssh:/root/.ssh:ro  # Uncomment this line
```

### Custom repos.csv location

Update the volume mount in `docker-compose.yml`:

```yaml
volumes:
  - ./my-repos.csv:/app/repos.csv
```

### Storage configuration

The Docker volume `data` persists:
- Cloned repositories
- Build artifacts
- Build logs

Inspect volume usage:
```bash
docker system df -v | grep data
```

## Grafana dashboards

Two pre-configured dashboards are included:

### Build Dashboard
- Build success/failure rates
- Build duration trends
- Repository-level metrics
- Error rates

### Run Dashboard
- Overall ingestion progress
- Active builds
- Queue depth
- System resource usage

Access at: http://localhost:3000/dashboards

## Prometheus metrics

Key metrics available:

- `mod_build_duration_seconds` - Build duration per repository
- `mod_build_total` - Total builds (success/failure)
- `mod_publish_total` - LST publish count
- `mod_clone_duration_seconds` - Clone time per repository
- `jvm_*` - JVM metrics (heap, GC, threads)
- `process_*` - Process metrics (CPU, memory)

Query in Prometheus at: http://localhost:9090/graph

## Continuous operation

The mass-ingest service is configured with `restart: unless-stopped`, so it will:
1. Run through all repositories
2. Exit when complete
3. Automatically restart and run again

To run on a schedule instead, remove `restart: unless-stopped` and use cron or a scheduler.

## Scaling

### Single worker (default)

The default configuration runs one mass-ingest container that processes all repositories sequentially. This works well for < 1,000 repositories.

### Manual scaling with multiple workers

For 1,000-10,000 repositories, you can manually scale by running multiple containers in parallel, each processing a partition of your repository list.

**How it works:**
- Use `--start` and `--end` parameters to specify which rows each container should process
- Each worker processes a different range of repositories from repos.csv
- All workers run simultaneously, sharing the same Grafana/Prometheus monitoring

**Example: 3 workers processing 3,000 repositories**

Edit `docker-compose.yml` to add multiple workers:

```yaml
services:
  mass-ingest-worker-1:
    build:
      context: ..
      args:
        MODERNE_CLI_VERSION: ${MODERNE_CLI_VERSION}
    environment:
      - PUBLISH_URL=${PUBLISH_URL}
      - PUBLISH_USER=${PUBLISH_USER}
      - PUBLISH_PASSWORD=${PUBLISH_PASSWORD}
      - PUBLISH_TOKEN=${PUBLISH_TOKEN}
      - MODERNE_TENANT=${MODERNE_TENANT}
      - MODERNE_TOKEN=${MODERNE_TOKEN}
    command: ["./publish.sh", "repos.csv", "--start", "1", "--end", "1000"]
    restart: unless-stopped
    ports:
      - "8081:8080"
    volumes:
      - data1:/var/moderne
      - ../repos.csv:/app/repos.csv
    networks:
      - monitoring

  mass-ingest-worker-2:
    build:
      context: ..
      args:
        MODERNE_CLI_VERSION: ${MODERNE_CLI_VERSION}
    environment:
      - PUBLISH_URL=${PUBLISH_URL}
      - PUBLISH_USER=${PUBLISH_USER}
      - PUBLISH_PASSWORD=${PUBLISH_PASSWORD}
      - PUBLISH_TOKEN=${PUBLISH_TOKEN}
      - MODERNE_TENANT=${MODERNE_TENANT}
      - MODERNE_TOKEN=${MODERNE_TOKEN}
    command: ["./publish.sh", "repos.csv", "--start", "1001", "--end", "2000"]
    restart: unless-stopped
    ports:
      - "8082:8080"
    volumes:
      - data2:/var/moderne
      - ../repos.csv:/app/repos.csv
    networks:
      - monitoring

  mass-ingest-worker-3:
    build:
      context: ..
      args:
        MODERNE_CLI_VERSION: ${MODERNE_CLI_VERSION}
    environment:
      - PUBLISH_URL=${PUBLISH_URL}
      - PUBLISH_USER=${PUBLISH_USER}
      - PUBLISH_PASSWORD=${PUBLISH_PASSWORD}
      - PUBLISH_TOKEN=${PUBLISH_TOKEN}
      - MODERNE_TENANT=${MODERNE_TENANT}
      - MODERNE_TOKEN=${MODERNE_TOKEN}
    command: ["./publish.sh", "repos.csv", "--start", "2001", "--end", "3000"]
    restart: unless-stopped
    ports:
      - "8083:8080"
    volumes:
      - data3:/var/moderne
      - ../repos.csv:/app/repos.csv
    networks:
      - monitoring

  # Keep prometheus and grafana as-is
  prometheus:
    # ... existing config ...

  grafana:
    # ... existing config ...

volumes:
  data1:
  data2:
  data3:
```

Update Prometheus configuration (`observability/prometheus/prometheus.yml`) to scrape all workers:

```yaml
scrape_configs:
  - job_name: 'mass-ingest'
    static_configs:
      - targets: ['mass-ingest-worker-1:8080', 'mass-ingest-worker-2:8080', 'mass-ingest-worker-3:8080']
```

**Key points:**
- Each worker gets a unique port (8081, 8082, 8083)
- Each worker gets its own data volume to avoid conflicts
- `--start` is inclusive, `--end` is exclusive (0-1000 processes rows 0-999)
- All workers share the same repos.csv file
- Grafana dashboards automatically aggregate metrics from all workers

### Automatic scaling for larger workloads

For > 10,000 repositories or fully automated parallel processing, see **3-scalability** which uses AWS Batch for automatic scaling and partitioning.

## Troubleshooting

### Services won't start
```bash
docker compose logs
```

Check:
- `.env` file exists with valid credentials
- `../repos.csv` exists
- Ports 3000, 8080, 9090 are available

### Grafana dashboards not loading
- Wait 30 seconds for Prometheus to scrape first metrics
- Check Prometheus targets: http://localhost:9090/targets
- Verify `mass-ingest:8080` target is UP

### Out of disk space
Check volume usage:
```bash
docker volume inspect 2-observability_data
```

Increase storage or clean up:
```bash
docker compose down -v  # Removes data volume
```

### Build failures
View detailed logs:
```bash
docker compose exec mass-ingest ls /var/moderne/
docker compose exec mass-ingest cat /var/moderne/log.zip
```

## Resource requirements

Recommended per container:
- **mass-ingest**: 2 CPU, 16 GB RAM, 32+ GB disk
- **Prometheus**: 1 CPU, 2 GB RAM, 10 GB disk
- **Grafana**: 1 CPU, 512 MB RAM, 1 GB disk

Adjust in docker-compose.yml:
```yaml
deploy:
  resources:
    limits:
      cpus: '2'
      memory: 16G
```

## Alternative deployment options

- **3-scalability**: Scale with parallel workers using Terraform/ECS for large repository counts

## Additional resources

- [Prometheus Query Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Grafana Dashboards](https://grafana.com/docs/grafana/latest/dashboards/)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
