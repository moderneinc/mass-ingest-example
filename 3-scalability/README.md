# Scalability

A cloud batch service runs one ingest container per organization on a schedule: the scheduler submits a job for each name in `organizations`, every job runs `publish.sh` with its `ORGANIZATION`, the jobs work through their slice of the store's `repos.csv` side by side and flush their rows into the shared `repos-lock.csv`, and the compute scales back to zero when they finish. Nothing partitions by row count and nothing counts the csv: the CLI skips what is already published, so a daily run costs what changed.

| Cloud provider | Service | Compute | Guide |
|---|---|---|---|
| **AWS** | [AWS Batch](https://aws.amazon.com/batch/) | EC2 instances | [aws-batch/](./aws-batch/) |
| **GCP** | [Google Cloud Batch](https://cloud.google.com/batch) | Compute Engine VMs | [gcp-batch/](./gcp-batch/) |

Both use the root `Dockerfile` and `publish.sh`; only the Terraform differs. [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) covers both.

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
