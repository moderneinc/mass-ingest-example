# Running on Kubernetes

[`k8s/job.yaml`](../k8s/job.yaml) runs one ingest as an [indexed Job](https://kubernetes.io/docs/concepts/workloads/controllers/job/#completion-mode). Kubernetes creates a pod for each index from 0 to `SHARDS - 1` and sets `JOB_COMPLETION_INDEX` in each one. Every pod runs:

```
mod publish /var/moderne/ws --sync-csv --shard $(JOB_COMPLETION_INDEX)/SHARDS
```

`CONCURRENCY` caps how many of those pods run at the same time. When one finishes, Kubernetes starts the next index, until every shard has run. 

**Note:** You'll need Kubernetes 1.29 or later. This is because the manifest relies on per-index retries, which older versions don't support.

## Setting up the namespace

The namespace enforces the restricted pod security standard. The image already meets it, since it runs as an unprivileged user.

```bash
kubectl apply -f k8s/namespace.yaml -f k8s/serviceaccount.yaml
```

The Job reads its configuration from two secrets: `mass-ingest-store` and `mass-ingest-moderne`. Every key in them becomes an environment variable in the container. This keeps the manifest the same no matter which artifact store you publish to or how you connect to Moderne.

If you're publishing to S3, create the store secret with:

```bash
kubectl -n mass-ingest create secret generic mass-ingest-store \
  --from-literal=MOD_LSTS_ARTIFACTS_S3_URL=s3://your-bucket
```

[Publishing to S3](s3.md) has more on S3 credentials and regions. If you're publishing to Artifactory, Nexus, or another Maven repository, [Publishing to Artifactory](artifactory.md) lists what goes in the secret instead.

If you're a SaaS customer, put your tenant and an access token in `mass-ingest-moderne`. If you're a DX customer, put your license key there instead. Nothing in a DX run contacts Moderne.

```bash
# Moderne SaaS
kubectl -n mass-ingest create secret generic mass-ingest-moderne \
  --from-literal=MOD_TENANT_HOST=https://<tenant>.moderne.io \
  --from-literal=MOD_TENANT_AUTHORIZATION=<token>

# Moderne DX
kubectl -n mass-ingest create secret generic mass-ingest-moderne \
  --from-literal=MOD_LICENSE_KEY=<license key>
```

If any of your repositories are private, you'll need one more secret that holds your `.git-credentials` file. The Job mounts it read-only at `/home/moderne/.git-credentials`:

```bash
kubectl -n mass-ingest create secret generic mass-ingest-git \
  --from-file=credentials=.git-credentials
```

The Moderne and git secrets are both optional. If you're just trying mass ingest out on public repositories, the store secret is all you need.

## Starting a run

Fill in the manifest's variables and create the Job:

```bash
RUN_NAME=ingest-$(date -u +%Y%m%d-%H%M) IMAGE=registry.example.com/mass-ingest \
  SHARDS=32 CONCURRENCY=8 \
  envsubst '$RUN_NAME $IMAGE $SHARDS $CONCURRENCY' \
  < k8s/job.yaml | kubectl create -f -
```

The quoted `'$RUN_NAME $IMAGE $SHARDS $CONCURRENCY'` argument tells `envsubst` to replace only those four placeholders and nothing else. Kubernetes fills in `$(JOB_COMPLETION_INDEX)` itself when each pod starts. If you only want to ingest a single organization from `repos.csv`, add `"--organization", "<name>"` to the container's `args` before creating the Job.

To keep your LSTs current, create a Job like this every night from CI or a CronJob.

## When things fail

Most failures in a mass ingest are individual repositories that don't build. These don't fail the Job. The CLI records the failure in that repository's row of `repos-lock.csv` and moves on. Once it has worked through its shard, it exits successfully.

When a pod itself fails, Kubernetes retries its index up to two more times, for three attempts in total. The retry skips what the earlier attempt already recorded (following the [rule in the README](../README.md#skipping-unchanged-repositories)), so it mostly repeats the build that was in progress. A pod lost to a reclaimed spot instance or a drained node doesn't count against those retries. A stopping pod gets two minutes after `SIGTERM` for the CLI to write the lock.

If a Job ends as `Failed` with most of its indexes complete, some index ran out of retries. Everything the other indexes built is already recorded in `repos-lock.csv`, so the next run only has to redo the repositories the failed index didn't get to.

## Watching a run

```bash
kubectl get job,pods -n mass-ingest
kubectl logs -n mass-ingest job/<run> --tail=50
kubectl get job -n mass-ingest <run> -o jsonpath='{.status.completedIndexes} / {.status.failedIndexes}'
kubectl exec -n mass-ingest -it <pod> -- bash
```

The pod logs are where you'll find out why a build failed. They disappear with the pod, so make sure to read them while the run is going.

If you want to know what a past run did, look at the `repos-lock.csv` file instead. The CLI writes it next to your `repos.csv` in the artifact store and updates it as each repository finishes. Every repository gets a row that records where its LST was published, the commit it was built from, the CLI version, and whether the build was reproducible. A failed build shows up as a row with no publish location. If you're a SaaS customer, you can also see your tenant's record of every clone, build, and publish.

If a build hangs, a shell in the running pod is the quickest way in. `mod doctor /var/moderne/ws --sync-csv` works there too.

## Sizing

There are two parts to sizing a run: how the work is split across pods, and how much CPU, memory, and disk each pod gets.

To configure how work is split across pods, you'll need to specify the `SHARDS` and `CONCURRENCY` variables when you start a run.

Set `CONCURRENCY` to the number of pods you want running at once. Since each pod builds one repository at a time, it's also how many builds run in parallel. That's the main thing that drives what a run costs.

Set `SHARDS` to the number of pieces you want the repository list split into. More shards mean each pod runs for less time, and a pod that dies has less to redo. A good rule of thumb is about four shards per concurrent pod - which keeps each pod to a few hours. You can change both numbers between runs, because the lock tracks each repository rather than the shard it ran in.

Each pod requests 3.5 CPUs, 12 GiB of memory, and 150 GiB of ephemeral storage. That fits a 4 vCPU, 16 GiB node. Keep the memory limit equal to the request. The CLI holds each build below the container's memory limit, so a build that runs out of memory fails that one repository instead of getting the pod killed. It can only do that when there is a limit to hold it under. The one side effect is that `mod doctor` in a pod warns that memory is below 16 GiB. That warning is expected.

Your largest repository decides how much disk you need. If nothing you build comes close to 150 GiB, lower the storage request. A Job still running after 18 hours is stopped by `activeDeadlineSeconds`, which puts a bound on the cost of builds that hang.

Plan for a full rebuild after every CLI release, since a lock row is only skipped when the same CLI version produced it. [Pinning the CLI version](image.md#the-cli-version) lets you choose when that happens.

## Amazon EKS

[`k8s/eks/`](../k8s/eks) is an [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html) node pool shaped for this workload. It adds one 4 vCPU spot instance per index, general purpose or memory optimized depending on price, and scales to zero when the run ends. Spot capacity is a good fit here, because a reclaimed instance only costs the progress its index hadn't yet recorded. Burstable instance types are left out, since a two-hour build would run through its CPU credits.

Tag your cluster's private subnets with `karpenter.sh/discovery=<cluster>`, then create the node class and pool:

```bash
CLUSTER_NAME=<cluster> NODE_ROLE=<cluster node role name> \
  envsubst '$CLUSTER_NAME $NODE_ROLE' < k8s/eks/nodeclass.yaml | kubectl apply -f -
kubectl apply -f k8s/eks/nodepool.yaml
```

Then uncomment the `nodeSelector` in [`k8s/job.yaml`](../k8s/job.yaml) so the Job's pods land on that pool. Rather than putting AWS keys in the store secret, give the `mass-ingest` service account an IAM role through [Pod Identity](s3.md#credentials).
