# Moderne mass-ingest deployment

## Quick start

1. Download the Moderne CLI:
```bash
# Check https://github.com/moderneinc/moderne-cli/releases/latest for the latest stable release
# Replace VERSION with the actual version number (e.g., 3.26.5)
curl -o moderne-cli.jar https://repo1.maven.org/maven2/io/moderne/moderne-cli/VERSION/moderne-cli-VERSION.jar
```

2. Configure environment variables:
```bash
cp .env.example .env
```

Edit `.env` and set:
- `PUBLISH_URL`
- `PUBLISH_USER`
- `PUBLISH_PASSWORD`

3. Start the mass-ingest service:
```bash
docker compose up -d
```

4. Monitor metrics:
```bash
curl http://localhost:8080/prometheus
```

## Architecture

The deployment runs a single container that:
1. Downloads repos.csv (if `REPOS_CSV_URL` is set)
2. Starts `mod monitor` in the background on port 8080
3. Clones, builds, and publishes LSTs from repositories
4. Uploads build logs to artifact repository
5. Stops monitoring and exits

The script runs once and exits. For continuous ingestion, configure your container orchestrator to restart the container on a schedule.

## Endpoints

- Port `8080` - Prometheus metrics endpoint (`/prometheus`)

## Health monitoring

Mass-ingest runs as a batch job that executes once and exits. Unlike long-running services, it does not provide health probe endpoints (liveness, readiness, startup).

Monitor the ingestion process using the metrics endpoint while the container is running:
```bash
curl http://localhost:8080/prometheus
```

The container is configured with `restart: unless-stopped` in docker-compose.yml, so it will automatically restart and process repositories again after completion.

## Build tool requirements

### JDK versions

The minimal Dockerfile includes JDK 21 only. If your projects require other JDK versions (8, 11, 17, 25), extend the Dockerfile to install them. See the [full example](https://github.com/moderneinc/mass-ingest-example) for multi-JDK installation.

### Maven and Gradle

The minimal setup assumes Maven and Gradle wrappers (`mvnw`, `gradlew`) are checked into repositories. If wrappers are not present, install Maven and/or Gradle in the Dockerfile. See the [full example](https://github.com/moderneinc/mass-ingest-example) for installation instructions.

## Repository configuration

### Local repos.csv

Edit `repos.csv` to specify repositories to ingest:

```csv
cloneUrl,branch,origin,path,org1,org2,org3
https://github.com/org/repo,main,github.com,org/repo,Team,Department,ALL
```

Required columns: `cloneUrl`, `branch`, `origin`, `path`
Optional columns: `org1`, `org2` ... `orgN` (organizational hierarchy)

### Remote repos.csv

Load repos.csv from an HTTP(S) URL by setting the `REPOS_CSV_URL` environment variable:

```bash
REPOS_CSV_URL=https://example.com/repos.csv
```

Add to `.env` file or pass as environment variable in docker-compose. If set, the container will download repos.csv from the URL at startup.

## Scaling

### Manual partitioning with --start/--end

Scale ingestion by running multiple containers that process different ranges of repositories using `--start` and `--end` parameters:

```yaml
services:
  mass-ingest-1:
    build:
      context: .
      args:
        PUBLISH_URL: ${PUBLISH_URL}
        PUBLISH_USER: ${PUBLISH_USER}
        PUBLISH_PASSWORD: ${PUBLISH_PASSWORD}
    command: ./publish.sh repos.csv --start 1 --end 100
    ports:
      - "8081:8080"
    volumes:
      - data-1:/var/moderne
    restart: unless-stopped

  mass-ingest-2:
    build:
      context: .
      args:
        PUBLISH_URL: ${PUBLISH_URL}
        PUBLISH_USER: ${PUBLISH_USER}
        PUBLISH_PASSWORD: ${PUBLISH_PASSWORD}
    command: ./publish.sh repos.csv --start 101 --end 200
    ports:
      - "8082:8080"
    volumes:
      - data-2:/var/moderne
    restart: unless-stopped

volumes:
  data-1:
  data-2:
```

Each container processes its assigned range of repository lines (excluding the header).

### Remote partition files

Alternatively, use remote URLs for different partition files:

```yaml
services:
  mass-ingest-1:
    build:
      context: .
      args:
        PUBLISH_URL: ${PUBLISH_URL}
        PUBLISH_USER: ${PUBLISH_USER}
        PUBLISH_PASSWORD: ${PUBLISH_PASSWORD}
    environment:
      - REPOS_CSV_URL=https://example.com/repos-partition-1.csv
    ports:
      - "8081:8080"
    volumes:
      - data-1:/var/moderne

  mass-ingest-2:
    build:
      context: .
      args:
        PUBLISH_URL: ${PUBLISH_URL}
        PUBLISH_USER: ${PUBLISH_USER}
        PUBLISH_PASSWORD: ${PUBLISH_PASSWORD}
    environment:
      - REPOS_CSV_URL=https://example.com/repos-partition-2.csv
    ports:
      - "8082:8080"
    volumes:
      - data-2:/var/moderne

volumes:
  data-1:
  data-2:
```

## Build timeout

Builds are automatically terminated after 45 minutes to prevent indefinitely hanging builds.

## Storage requirements

The `data` volume stores cloned repositories and build artifacts:
- Minimum: 32 GB
- 1000+ repositories: 64-128 GB recommended

## Configuration reference

### Build arguments

Required:
- `PUBLISH_URL` - Artifact repository URL for LST publishing
- `PUBLISH_USER` - Artifact repository username
- `PUBLISH_PASSWORD` - Artifact repository password

### Runtime requirements

- Minimum per container: 2 CPU cores, 16 GB RAM, 32 GB storage
- JDK: JDK 21 included, install additional versions if needed
- Build tools: Maven/Gradle wrappers must be checked into repositories
- Git authentication: Configure `.git-credentials` or SSH keys if repositories require authentication

### Environment variables

- `REPOS_CSV_URL` - Optional URL to download repos.csv at startup
- `DATA_DIR` - Data directory (defaults to `/var/moderne`)
- `CUSTOM_CI` - Disables extra formatting in logs (set automatically)
