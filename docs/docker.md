# Running on one machine

Mass ingest doesn't need a cluster. On a single large VM with Docker, [`docker/run.sh`](../docker/run.sh) starts a container for each shard, waits for all of them to finish, and then prints how each one did.

## Configuration

The script hands every container the same env file. This file holds the artifact store settings and your connection to Moderne (more details about the connection can be found in the [README](../README.md#3-configure-and-run-it)). For a SaaS tenant publishing to S3, it looks like this:

```bash
# mass-ingest.env
MOD_LSTS_ARTIFACTS_S3_URL=s3://your-bucket
MOD_TENANT_HOST=https://<tenant>.moderne.io
MOD_TENANT_AUTHORIZATION=<token>
```

If you're on Moderne DX, replace the two tenant lines with `MOD_LICENSE_KEY=<license key>`.

If the VM reaches S3 through an EC2 instance role, you'll need to raise the metadata service's hop limit. Each container sits one network hop further from it than the VM does. Read [publishing to S3](s3.md#credentials) for an explanation of how to configure this.

The script mounts `~/.git-credentials` read-only into every container so it can clone private repositories. The file has to exist even if all of your repositories are public. If you don't need it, create an empty one with `touch ~/.git-credentials`.

## Running

```bash
SHARDS=16 IMAGE=registry.example.com/mass-ingest ./docker/run.sh
```

Each container runs `mod publish /var/moderne/ws --sync-csv --shard i/16` for its own `i`. When the last one finishes, the script prints a line like `shard 3 exited 0` for each. A shard exits 0 even if some of its repositories failed to build, because those failures are recorded in `repos-lock.csv`. A non-zero exit code means the shard stopped before it recorded everything it did. If you run the script again, it will skip what the first run recorded (following the [rule in the README](../README.md#skipping-unchanged-repositories)) before continuing on with the rest.

To stop a run early, stop its containers. Each one gets two minutes to write the lock before Docker kills it.

```bash
docker stop $(docker ps -q --filter name=mass-ingest-)
```

## Sizing

To size a run on one machine, you'll need to decide how many shards to run and how much of the machine to give each one.

Set `SHARDS` to the number of pieces you want the repository list split into. Since every shard is a container that builds one repository at a time, that means that `SHARDS` also defines how many builds run at once.

Give each shard about 4 vCPUs and 16 GiB of the machine. A 64 vCPU, 256 GiB VM runs 16 shards.

The script caps each container at 12 GiB of memory. That limit is worth keeping. The CLI holds each build below it, so a build that runs out of memory fails that one repository instead of the whole shard.

Each container keeps one repository on disk at a time. Plan for your largest repository times `SHARDS`, plus room for the image.

## Every day

A cron entry is enough to schedule it:

```
0 1 * * * cd /opt/mass-ingest-example && SHARDS=16 IMAGE=registry.example.com/mass-ingest ./docker/run.sh >> /var/log/mass-ingest.log 2>&1
```

If a run is still going when the next one is due, it keeps going. The new one fails right away because the container names are taken. If the machine restarts in the middle of a run, the stopped containers keep those names too. Remove them before the next run:

```bash
docker rm $(docker ps -aq --filter name=mass-ingest-)
```
