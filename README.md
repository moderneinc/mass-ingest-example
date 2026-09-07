# Mass ingest

Ingest a large number of repositories into Moderne with the [Moderne CLI](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro). One container works through a list of repositories: clone, build the LST, publish it to your artifact store, record the result, delete the clone, next.

## 1. Put `repos.csv` in the artifact store

Upload the list of repositories to the artifact store the LSTs will go to: `repos.csv` at the bucket or repository root for S3 and Artifactory, or at the Maven coordinate `io/moderne/organization/sources/repos/1.0.0/repos-1.0.0.csv` for Nexus and other Maven repositories that enforce a strict layout.

```csv
cloneUrl,branch,origin,path,org1
https://github.com/acme/billing,main,github.com,acme/billing,Payments
https://github.com/acme/claims-api,,github.com,acme/claims-api,Claims
```

`cloneUrl`, `origin` and `path` are required; `branch` defaults to the remote's default branch; `org1`, `org2`, ... place the repository in an organization, innermost first. The [repos.csv reference](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv) lists the other columns, and [repository-fetchers](https://github.com/moderneinc/repository-fetchers) generates the file from GitHub, GitLab, Bitbucket and more.

The store holds two files. `repos.csv` is the input: whatever produces it overwrites the whole file whenever membership changes and never touches `repos-lock.csv`. `repos-lock.csv` is the output: `mod publish` rebuilds it from `repos.csv`, decorating every row with what was published, and nothing else writes it.

## 2. Build the image

```bash
docker build -t mass-ingest .
```

The image ships JDKs 8 to 25, Maven, Gradle and the latest CLI release. [Building the image](docs/image.md) covers pinning the CLI version, internal mirrors, other languages, self-signed certificates and the FIPS variant.

## 3. Run it

```bash
mkdir -p data
docker run --rm -p 8080:8080 -v "$(pwd)/data:/var/moderne" \
  -e PUBLISH_URL=https://artifactory.example.com/artifactory/moderne-ingest/ \
  -e PUBLISH_USER=svc-moderne -e PUBLISH_PASSWORD=... \
  mass-ingest
```

The container runs `mod publish /var/moderne --sync-csv`. For every row it compares the remote HEAD with the row's `repos-lock.csv` entry: a repository already published from that commit, by this CLI version, from a reproducible build is skipped; anything else is cloned, built, published and recorded, and its clone is deleted before the next one starts. Disk use stays at one repository, a rerun only touches what changed, and the lock is flushed to the store when the container is stopped and, while it runs, at its own 15-second turn in a round shared with the other containers, a minute for a handful of them and longer as their number grows, so they never queue on the file.

| Variable | |
|---|---|
| `PUBLISH_URL` | The artifact store: an `https://` Maven repository or Artifactory, or `s3://bucket` ([S3 rules](docs/s3.md)). |
| `PUBLISH_USER` + `PUBLISH_PASSWORD` | Maven repository credentials; `PUBLISH_TOKEN` instead for an Artifactory API token. |
| `ORGANIZATION` | Ingest one organization from `repos.csv`. One container per organization spreads the work. |
| `PARALLEL` | Repositories in flight inside one container (default 1). |
| `MODERNE_TENANT` + `MODERNE_TOKEN` | Optional: the Moderne tenant to register with the CLI. |
| `GIT_CREDENTIALS` / `GIT_SSH_CREDENTIALS` | Inline credentials for private repositories (see below). |

### Private repositories

Mount a `.git-credentials` file (one `https://user:token@host` line per host) or an `.ssh` directory into `/home/moderne`, readable by UID 1000, or pass the same content inline:

```bash
docker run --rm -v "$(pwd)/.git-credentials:/home/moderne/.git-credentials:ro" ... mass-ingest
docker run --rm -e GIT_SSH_CREDENTIALS="$(cat ~/.ssh/id_ed25519)" ... mass-ingest
```

### Check it worked

- `docker run --rm -e DIAGNOSE=true ... mass-ingest` runs `mod doctor` instead of the ingest: host resources, toolchains, git credentials, the store, the tenant and every SCM origin in `repos.csv`, read-only, with a fix suggested for each failing row and a non-zero exit when anything fails. `DIAGNOSE_ON_START=true` runs it and then ingests regardless.
- The store's `repos-lock.csv` has a row per repository with the published LST's location, `changeset`, `cliVersion` and `reproducible`.
- `data/.moderne/{sync,build,publish}/<command id>/trace.csv` record every clone, build and publish, and `data/.moderne/publish/<command id>/publish.log` keeps the failure stack traces. Nothing else survives in `data`.
- `curl localhost:8080/prometheus` while it runs; [2-observability](2-observability/) puts that in Grafana.

## Going further

- [Publishing to S3](docs/s3.md): credential providers, the IMDSv2 hop limit on EC2, S3-compatible stores.
- [2-observability](2-observability/): Docker Compose with Prometheus and Grafana, one service per organization.
- [3-scalability](3-scalability/): AWS Batch or GCP Batch from Terraform, one scheduled job per organization.
- [Windows](docs/windows.md): `publish.ps1` runs the same flow on a Windows host without Docker, .NET builds included.
- [Troubleshooting](3-scalability/TROUBLESHOOTING.md).
- [Building the image](docs/image.md): build arguments, internal mirrors, the FIPS image, the non-root user.

## Support

- [Moderne CLI documentation](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro)
- [Report issues](https://github.com/moderneinc/mass-ingest-example/issues)

This example code is provided as-is for use with Moderne products.
