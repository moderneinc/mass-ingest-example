# Scalability: scale to production

Production-scale deployment using cloud-native batch services for parallel repository processing. Choose the example that matches your cloud provider.

## Choose your platform

| Cloud provider | Service | Compute | Guide |
|---|---|---|---|
| **AWS** | [AWS Batch](https://aws.amazon.com/batch/) | EC2 instances | [aws-batch/](./aws-batch/) |
| **GCP** | [Google Cloud Batch](https://cloud.google.com/batch) | Compute Engine VMs | [gcp-batch/](./gcp-batch/) |

Both examples implement the same architecture — only the infrastructure-as-code and cloud-specific tooling differ.

## Architecture

All platforms follow the same pattern:

1. **Scheduled trigger** (daily/weekly cron) starts the orchestration
2. **Orchestrator** determines partitions from the repo list and creates N parallel tasks
3. **Tasks** each process a slice of the CSV (`--start N --end M`) using the shared `publish.sh` script
4. **Workers shut down** when their slice is complete — compute scales to zero
5. **Next trigger** repeats the cycle

> [!NOTE]
> The exact orchestration differs by platform. AWS uses a separate chunk job that submits processor jobs. GCP uses a Cloud Workflow that computes task count and creates a single Batch job with N parallel tasks.

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│  Scheduler  │────>│ Orchestrator │────>│ Processor #1 │──> publish.sh --start 1  --end 10
│  (cron)     │     │              │     │ Processor #2 │──> publish.sh --start 11 --end 20
└─────────────┘     └──────────────┘     │ Processor #3 │──> publish.sh --start 21 --end 30
                                         │     ...      │
                                         │ Processor #N │──> publish.sh --start X  --end Y
                                         └──────────────┘
```

### Shared components

These files are shared across all platforms and live at the repository root:

- `publish.sh` — main ingestion script, already supports `--start`/`--end` for partitioning
- `Dockerfile` / `Dockerfile.fips` — container image definition
- `repos.csv` — repository list (can be baked into the image or hosted at a URL)
- `diagnostics/` — pre-ingestion validation

## Why VM-based batch services (not Kubernetes)

We recommend VM-based batch services (AWS Batch, GCP Batch) over Kubernetes for mass ingestion. This recommendation is based on real-world experience across multiple customer deployments.

**LST builds are resource-intensive.** Building Lossless Semantic Trees involves cloning repositories, resolving dependencies, and running full Java builds. This requires dedicated CPU and memory — the kind of workload where resource contention causes hard-to-diagnose failures.

### Issues observed with Kubernetes deployments

- **Unreliable resource guarantees** — Kubernetes does not always give pods the CPU and memory they request. Under resource pressure, LST builds get throttled or evicted, causing flaky ingestion that appears to work sometimes and fail unpredictably.
- **Debugging derailment** — Kubernetes deployments tend to derail into debugging K8s infrastructure (scheduling, networking, storage) instead of getting value from Moderne. The operational overhead is significant.
- **Cost inefficiency** — Kubernetes clusters are often reported to consume only a fraction of available CPU. In one case, moving a comparable workload from a 2-node K8s cluster to a single large VM reduced costs by an order of magnitude.
- **Out-of-memory incidents** — Customers have run out of memory running mass ingestion on K8s with as few as 400 projects, even with resource requests configured.
- **Mysterious build hangs** — Repositories that build successfully on a developer machine can hang indefinitely in a K8s pod due to memory pressure that is invisible to the build process.
- **Container environment quirks** — Random uid/gid assignment in some K8s setups breaks filesystem operations. JDKs 8–18 have a `user.home` bug in containerized environments that causes directories named `?`.

### Why VM-based batch works better

- **Dedicated resources** — each job gets a full VM with guaranteed CPU and memory
- **No scheduling surprises** — no pod eviction, no CPU throttling, no noisy neighbors
- **Scale to zero** — batch services tear down VMs when jobs complete
- **Same container image** — you still use Docker containers, just on dedicated VMs
- **Simpler debugging** — when something goes wrong, you debug your build, not your orchestration platform

> [!NOTE]
> Some customers have successfully deployed mass ingestion on Kubernetes, but it required significant effort to tune resource limits, node affinity, and scheduling policies. If you must use Kubernetes, ensure each pod gets a dedicated node or use guaranteed QoS with generous resource limits.
