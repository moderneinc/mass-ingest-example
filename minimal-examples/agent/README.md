# Moderne agent deployment

## Quick start

1. Download the Moderne agent JAR:
```bash
# Check https://github.com/moderneinc/moderne-agent/releases/latest for the latest stable release
# Replace VERSION with the actual version number
curl -o moderne-agent-VERSION.jar https://repo1.maven.org/maven2/io/moderne/moderne-agent/VERSION/moderne-agent-VERSION.jar
```

2. Build the image:
```bash
docker build -t moderne-agent .
```

3. Run with environment variables:
```bash
docker run -d \
  -p 8080:8080 \
  -e MODERNE_AGENT_TOKEN=your-token \
  -e MODERNE_AGENT_CRYPTO_SYMMETRICKEY=your-key \
  -e MODERNE_AGENT_NICKNAME=my-agent \
  -e MODERNE_AGENT_APIGATEWAYRSOCKETURI=https://api.app.moderne.io \
  moderne-agent
```

Or use an environment file (see `.env.example`):
```bash
docker run -d -p 8080:8080 --env-file .env moderne-agent
```

4. Verify:
```bash
curl http://localhost:8080/actuator/health
```

## Endpoints

All endpoints are available on port `8080`.

### Health probes

- `GET /actuator/health` - Overall health status
- `GET /actuator/health/liveness` - Liveness probe
- `GET /actuator/health/readiness` - Readiness probe

The liveness and readiness endpoints require `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true` (already configured in Dockerfile).

### Metrics

- `GET /actuator/prometheus` - Prometheus metrics endpoint

## Prometheus integration

Add this scrape configuration to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'moderne-agent'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets: ['<agent-host>:8080']
```

## Grafana dashboards

We do not provide pre-built Grafana dashboards at this time. You can create custom dashboards using metrics from the `/actuator/prometheus` endpoint.

## Remote repository loading

Set the environment variable to load repositories from an HTTP(S) endpoint:

```
MODERNE_AGENT_ORGANIZATION_REPOSCSV=https://example.com/repos.csv
```

### repos.csv format

```csv
cloneUrl,branch,origin,path,org1,org2,org3
https://github.com/org/repo,main,github.com,org/repo,Team,Department,ALL
```

Required columns: `cloneUrl`, `branch`, `origin`, `path`
Optional columns: `org1`, `org2`, `org3` (organizational hierarchy, left is child of right)

## Scaling

Multiple agents can run concurrently. Each agent must have a unique `MODERNE_AGENT_NICKNAME`. The agent is ephemeral and does not require persistent storage. The agent only needs to be accessible for monitoring endpoints, so any port can be used.

Example running multiple agents:
```bash
docker run -d -p 8080:8080 --env-file .env -e MODERNE_AGENT_NICKNAME=agent-1 moderne-agent
docker run -d -p 8081:8080 --env-file .env -e MODERNE_AGENT_NICKNAME=agent-2 moderne-agent
```

## Configuration reference

See `.env.example` for all available configuration options including:
- SCM integrations (GitHub, GitLab, Bitbucket)
- Artifact repositories (Artifactory, Maven)
- Performance tuning options
- Security and policy settings
