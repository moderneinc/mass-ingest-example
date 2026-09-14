# Running on one machine

Mass ingest doesn't need a cluster. On a single large VM with Docker, [`docker/run.sh`](../docker/run.sh) starts a container for each shard, waits for all of them, and prints how each one finished.

## Configuration

The script hands every container the same env file, which holds the artifact store and your connection to Moderne as the [README](../README.md#3-run-it) describes. For a SaaS tenant publishing to S3, it looks like this:

```bash
# mass-ingest.env
MOD_LSTS_ARTIFACTS_S3_URL=s3://your-bucket
MOD_TENANT_HOST=https://<tenant>.moderne.io
MOD_TENANT_AUTHORIZATION=<token>
```

On Moderne DX, `MOD_LICENSE_KEY=<license key>` takes the place of the two tenant lines. If the VM reaches S3 through an EC2 instance role, raise the metadata service's hop limit as [Publishing to S3](s3.md#credentials) explains, since each container sits one network hop further from it than the VM does.

The script mounts `~/.git-credentials` read-only into every container for cloning private repositories. The file has to exist even when every repository is public, so create an empty one with `touch ~/.git-credentials` if you don't need it.

## Running

```bash
SHARDS=16 IMAGE=registry.example.com/mass-ingest ./docker/run.sh
```

Each container runs `mod publish /var/moderne/ws --sync-csv --shard i/16` for its own `i`, and when the last one finishes the script prints a line such as `shard 3 exited 0` for each. A shard exits 0 even when some of its repositories failed to build, because those failures are recorded in `repos-lock.csv`. A non-zero exit means the shard didn't get to record everything it did, and the fix is to run the script again: every repository already recorded is skipped, so the second run only redoes what the first one left unfinished.

To stop a run early, stop its containers. Each one gets two minutes to write the lock before Docker kills it.

```bash
docker stop $(docker ps -q --filter name=mass-ingest-)
```

## Sizing

Every shard is a container building one repository at a time, so `SHARDS` is also the number of builds running at once. Give each about 4 vCPUs and 16 GiB of the machine; a 64 vCPU, 256 GiB VM runs 16 shards. The script caps each container at 12 GiB of memory, and that limit is worth keeping, because the CLI holds each build below it so that a build running out of memory fails that repository instead of the whole shard. Each container also keeps one repository on disk at a time, so plan for your largest repository times `SHARDS`, plus room for the image.

## Every day

A cron entry is enough to schedule it:

```
0 1 * * * cd /opt/mass-ingest-example && SHARDS=16 IMAGE=registry.example.com/mass-ingest ./docker/run.sh >> /var/log/mass-ingest.log 2>&1
```

A run that is still going when the next one is due keeps going, and the new one fails right away because the container names are taken. If the machine restarts in the middle of a run, the stopped containers keep those names too, so remove them before the next run:

```bash
docker rm $(docker ps -aq --filter name=mass-ingest-)
```
