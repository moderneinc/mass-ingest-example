# Observability

Docker Compose runs the ingest container next to Prometheus and Grafana, with dashboards for build throughput and failures.

## Run

```bash
cp ../.env.example .env   # fill in PUBLISH_URL and credentials
docker compose up -d
docker compose logs -f mass-ingest
```

- Grafana: http://localhost:3000 (`admin` / `admin`), dashboards under *Dashboards*
- Raw metrics: `curl http://localhost:8080/prometheus`
- Prometheus UI: uncomment its `ports` in `docker-compose.yml`, then http://localhost:9090

The `mass-ingest` service restarts when it exits (`restart: unless-stopped`), so it keeps re-reading the store's `repos.csv` and re-publishing whatever changed. For a schedule instead, remove that line and run `docker compose up mass-ingest` from cron. `docker compose down -v` also removes the data volume.

Private repositories: uncomment the `.git-credentials` or `.ssh` mount in `docker-compose.yml`, or set `GIT_CREDENTIALS` / `GIT_SSH_CREDENTIALS` in `.env`. `MODERNE_CLI_VERSION` and the other build arguments in `.env` are passed to the image build.

## One service per organization

Spread a large `repos.csv` over several containers by giving each an `ORGANIZATION`; each needs its own host port and data volume:

```yaml
services:
  payments:
    build: { context: .. }
    env_file: [.env]
    environment: { ORGANIZATION: Payments }
    ports: ["8081:8080"]
    volumes: [payments:/var/moderne]
    networks: [monitoring]
  claims:
    build: { context: .. }
    env_file: [.env]
    environment: { ORGANIZATION: Claims }
    ports: ["8082:8080"]
    volumes: [claims:/var/moderne]
    networks: [monitoring]
  platform:
    build: { context: .. }
    env_file: [.env]
    environment: { ORGANIZATION: Platform }
    ports: ["8083:8080"]
    volumes: [platform:/var/moderne]
    networks: [monitoring]

volumes:
  payments:
  claims:
  platform:
```

and scrape all of them in `observability/prometheus/prometheus.yml`:

```yaml
scrape_configs:
  - job_name: "mod_monitor"
    metrics_path: "/prometheus"
    static_configs:
      - targets: ["payments:8080", "claims:8080", "platform:8080"]
```

The dashboards aggregate across targets. Each container flushes its organization's rows into the shared `repos-lock.csv` with a compare-and-swap, so they run side by side.

## Metrics

- `moderne_cli_build_seconds_{count,sum,max}`: build duration per repository, tagged by `build_tool` and `outcome`
- `moderne_cli_buildstep_seconds_{count,sum,max}`: duration per build step, tagged by `build_tool_name` and `outcome`
- `jvm_*`, `process_*`: JVM and process metrics

Recommended resources: 2 CPU and 16 GB for each ingest container, 1 CPU and 2 GB for Prometheus, 512 MB for Grafana.
