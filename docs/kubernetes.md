# Running on Kubernetes

[`k8s/job.yaml`](../k8s/job.yaml) runs one ingest as an [indexed Job](https://kubernetes.io/docs/concepts/workloads/controllers/job/#completion-mode). Kubernetes creates a pod for each index from 0 to `SHARDS - 1` and sets `JOB_COMPLETION_INDEX` in it, and each pod runs

```
mod publish /var/moderne/ws --sync-csv --shard $(JOB_COMPLETION_INDEX)/SHARDS
```

with at most `CONCURRENCY` of them running at once. The manifest relies on per-index retries, which need Kubernetes 1.29 or later.

## Setting up the namespace

The namespace enforces the restricted pod security standard, which the image already meets by running as an unprivileged user.

```bash
kubectl apply -f k8s/namespace.yaml -f k8s/serviceaccount.yaml
```

A Job reads its configuration from secrets, and every key in `mass-ingest-store` and `mass-ingest-moderne` becomes an environment variable in the container. That keeps the manifest the same whichever artifact store you publish to and however you connect to Moderne. For an S3 bucket the store secret looks like this, and [Publishing to S3](s3.md) and [Publishing to Artifactory](artifactory.md) show the others:

```bash
kubectl -n mass-ingest create secret generic mass-ingest-store \
  --from-literal=MOD_LSTS_ARTIFACTS_S3_URL=s3://your-bucket
```

A SaaS customer puts their tenant and an access token in `mass-ingest-moderne`. A DX customer puts the license key there instead, and nothing in the run contacts Moderne.

```bash
# Moderne SaaS
kubectl -n mass-ingest create secret generic mass-ingest-moderne \
  --from-literal=MOD_TENANT_HOST=https://<tenant>.moderne.io \
  --from-literal=MOD_TENANT_AUTHORIZATION=<token>

# Moderne DX
kubectl -n mass-ingest create secret generic mass-ingest-moderne \
  --from-literal=MOD_LICENSE_KEY=<license key>
```

Private repositories need one more secret holding the `.git-credentials` file, which the Job mounts read-only at `/home/moderne/.git-credentials`:

```bash
kubectl -n mass-ingest create secret generic mass-ingest-git \
  --from-file=credentials=.git-credentials
```

The Moderne and git secrets are both optional, so a trial over public repositories needs only the store.

## Starting a run

Fill in the manifest's variables and create the Job:

```bash
RUN_NAME=ingest-$(date -u +%Y%m%d-%H%M) IMAGE=registry.example.com/mass-ingest \
  SHARDS=32 CONCURRENCY=8 \
  envsubst '$RUN_NAME $IMAGE $SHARDS $CONCURRENCY' \
  < k8s/job.yaml | kubectl create -f -
```

`envsubst` gets the variable names spelled out so that it leaves `$(JOB_COMPLETION_INDEX)` alone for Kubernetes to fill in. To ingest a single organization from `repos.csv`, add `"--organization", "<name>"` to the container's `args` before creating the Job. Keeping LSTs current is then a matter of creating a Job like this every night, from CI or a CronJob.

## When things fail

Most failures in a mass ingest are individual repositories that don't build, and they don't fail the Job. The CLI records the failure in that repository's row of `repos-lock.csv`, moves on, and exits successfully once it has worked through its shard.

When a pod itself fails, Kubernetes runs its index again, up to twice. The retry skips every repository the earlier attempt recorded, so it only repeats the build that was in progress. A pod lost to a reclaimed spot instance or a drained node doesn't count against those two tries, and a stopping pod gets two minutes after `SIGTERM` for the CLI to write the lock. So a Job that ends `Failed` with most of its indexes complete had some index run out of tries, and the work of every other index is already in the lock for the next run to build on.

## Watching a run

```bash
kubectl get job,pods -n mass-ingest
kubectl logs -n mass-ingest job/<run> --tail=50
kubectl get job -n mass-ingest <run> -o jsonpath='{.status.completedIndexes} / {.status.failedIndexes}'
kubectl exec -n mass-ingest -it <pod> -- bash
```

A pod's logs disappear with the pod, so read them while the run is going. What lasts is `repos-lock.csv`, whose row for each repository records the published LST, the commit it was built from, the CLI version and whether the build was reproducible. SaaS customers also have the CLI's record of every clone, build and publish in their tenant. A shell in a running pod is the quickest way into a build that hangs, and `mod doctor /var/moderne --sync-csv` works there too.

## Sizing

An index builds one repository at a time, so `CONCURRENCY` is the number of builds running at once and, in practice, the cost of the ingest. `SHARDS` sets how long each index runs, which limits how much a lost pod has to redo; about four shards per unit of concurrency keeps an index to a few hours. The lock records each repository's state rather than its shard, so both numbers can change between runs.

Each pod requests 3.5 CPUs, 12 GiB of memory and 150 GiB of ephemeral storage, which fits a 4 vCPU, 16 GiB node. Keep the memory limit equal to the request. The CLI holds each build below the container's memory limit, so a build that runs out fails that one repository instead of getting the pod killed, but it can only do that when there is a limit to hold it under. Your largest repository decides how much disk you need, so lower the storage request if nothing you build comes close to 150 GiB. A Job still running after 18 hours is stopped (`activeDeadlineSeconds`), which bounds the cost of builds that hang.

Plan for a full rebuild after every CLI release, since a lock row is only skipped when the same CLI version produced it. [Pinning the CLI version](image.md#the-cli-version) lets you choose when that happens.

## Amazon EKS

[`k8s/eks/`](../k8s/eks) is an [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html) node pool shaped for this workload: one 4 vCPU spot instance per index, general purpose or memory optimized depending on price, scaled to zero when the run ends. Spot capacity suits it because a reclaimed instance costs only the progress its index hadn't yet recorded. Burstable instance types are left out, since a two-hour build would run through its CPU credits.

Tag your cluster's private subnets `karpenter.sh/discovery=<cluster>`, then create the node class and pool:

```bash
CLUSTER_NAME=<cluster> NODE_ROLE=<cluster node role name> \
  envsubst '$CLUSTER_NAME $NODE_ROLE' < k8s/eks/nodeclass.yaml | kubectl apply -f -
kubectl apply -f k8s/eks/nodepool.yaml
```

Uncomment the `nodeSelector` in [`k8s/job.yaml`](../k8s/job.yaml) so the Job's pods land on that pool, and give the `mass-ingest` service account an IAM role through [Pod Identity](s3.md#credentials) rather than putting AWS keys in the store secret.
