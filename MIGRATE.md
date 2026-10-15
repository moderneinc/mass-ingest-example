# Migrating from publish.sh

Earlier versions of this repository ran mass ingest through `publish.sh`, a script that cloned, built and published repositories in batches, with the CLI configured by `mod config` commands. Today the image runs a single command, `mod publish /var/moderne/ws --sync-csv`, which reads `repos.csv` from your artifact store, publishes one repository at a time, and records each result in `repos-lock.csv`. Configuration comes from environment variables.

Your artifact store, the LSTs already in it, `repos-lock.csv` and the connector all stay as they are. Follow the steps in order: until [step 10](#10-stop-the-old-mass-ingest), nothing changes your current mass ingest, which keeps running while you prepare. Your copy of the old script may be older than the last `publish.sh` in this repository or have changes of your own, so each step describes what you may have configured, not a specific version of the script. The [README](README.md) remains the reference for the new setup.

1. [Check that your setup is supported](#1-check-that-your-setup-is-supported)
2. [Put the complete repos.csv in your artifact store](#2-put-the-complete-reposcsv-in-your-artifact-store)
3. [Build the new image](#3-build-the-new-image)
4. [Configure the artifact store](#4-configure-the-artifact-store)
5. [Connect to your tenant](#5-connect-to-your-tenant)
6. [Give it access to your Git repositories](#6-give-it-access-to-your-git-repositories)
7. [Carry over CLI settings](#7-carry-over-cli-settings)
8. [Set up how it runs](#8-set-up-how-it-runs)
9. [Check the configuration](#9-check-the-configuration)
10. [Stop the old mass ingest](#10-stop-the-old-mass-ingest)
11. [Run the new mass ingest](#11-run-the-new-mass-ingest)
12. [Check the results](#12-check-the-results)
13. [Schedule it](#13-schedule-it)
14. [Point the connector at repos-lock.csv](#14-point-the-connector-at-repos-lockcsv)

## 1. Check that your setup is supported

The new example covers less than the old one did. If you use any of these, [communicate with us](mailto:support@moderne.io) before going further:

- Windows (`publish.ps1`). The new image is Linux only.
- The FIPS image (`Dockerfile.fips`).
- OpenShift, or any platform that runs containers under an arbitrary user ID. The new image doesn't run there yet ([#99](https://github.com/moderneinc/mass-ingest-example/issues/99)).

Two other parts of the old example have no direct replacement, but don't block the migration. Observability (`2-observability/`, `mod monitor`) is no longer needed, since SaaS tenants show every clone, build and publish. AWS Batch and GCP Batch (`3-scalability/`) are replaced by the Kubernetes Job or the single-machine script, set up in [step 8](#8-set-up-how-it-runs).

## 2. Put the complete repos.csv in your artifact store

The new flow reads the list only from the artifact store, and the store type (S3, Artifactory, or Maven) decides where: `repos.csv` and `repos-lock.csv` sit side by side, at a location that depends on the type. You'll need to configure the same type in [step 4](#4-configure-the-artifact-store), so that the new mass ingest keeps updating the same `repos-lock.csv`.

1. Find your current `repos-lock.csv` in the store. Its location tells you the type:

   | Store type | Location of `repos.csv` and `repos-lock.csv` |
   |---|---|
   | S3 | `s3://<bucket>/repos.csv` |
   | Artifactory | `<repository URL>/repos.csv` |
   | Maven (Nexus, GitLab, or Artifactory configured as a plain Maven store) | `<repository URL>/io/moderne/organization/sources/repos/1.0.0/repos-1.0.0.csv`, with the lock under `.../repos-lock/1.0.0/repos-lock-1.0.0.csv` |

   If there is no `repos-lock.csv` yet, pick the type that matches your store: S3 for a bucket, Artifactory for an Artifactory repository, Maven for Nexus or any other Maven repository. Then upload `repos.csv` to the location the table gives for that type.

2. Upload your complete `repos.csv` next to it, if it isn't there already.

From now on, this `repos.csv` is the single source of truth: it decides which repositories are ingested and, once the connector reads `repos-lock.csv` ([step 14](#14-point-the-connector-at-repos-lockcsv)), which repositories and organizations your tenant shows. Make every change to the list there. A copy built into the old image goes away in [step 3](#3-build-the-new-image); a separate CSV your connector reads goes away in step 14.

Never delete `repos-lock.csv`. If your connector is configured to read it, that's how it decides which LSTs your tenant has, and the new mass ingest takes over the existing file.

## 3. Build the new image

Start from this repository's [Dockerfile](Dockerfile) rather than editing your old one. The new image builds as root up to `USER moderne`, then runs as UID 1000 with its home in `/home/moderne`, so anything your old image copied into `/root/...` goes to the same path under `/home/moderne`, copied after `USER moderne` or with `--chown=moderne`.

1. **Leave out** everything the new flow replaces:
   - `publish.sh`, `publish.ps1` and the `diagnostics/` directory
   - `COPY repos.csv`
   - every `mod config` line (steps 4 to 7 cover what replaces them)
   - credentials passed as `ARG` or `ENV`, and `COPY .git-credentials`
   - `mod monitor`, supervisord, Grafana and Prometheus
   - the download of the CLI jar (the image installs the `modw` wrapper instead)

2. Carry over your customizations:

   | Old image | New image |
   |---|---|
   | `maven/settings.xml` + `mod config build maven settings edit` | Replace the content of `maven/settings.xml`. The image copies it to `/home/moderne/.m2/settings.xml`, and `cli/moderne.yml` points the CLI at it. If its passwords are encrypted, also copy your `settings-security.xml` to `/home/moderne/.m2/`. |
   | A `moderne.yml` copied into the CLI's configuration directory, with custom build steps for example | Its settings as environment variables, as [step 7](#7-carry-over-cli-settings) describes: `build.steps[0].type` is `MOD_BUILD_STEPS_0_TYPE`. Leave the image's own [`cli/moderne.yml`](cli/moderne.yml) as it is. |
   | `npm/.npmrc`, `python/pip.conf`, `nuget/nuget.config` | Copy them in next to the Maven settings, as [Private package registries](docs/image.md#private-package-registries) shows. |
   | Certificates imported with `keytool` into each JDK, `mod config http trust-store edit java-home`, `git config http.sslVerify false` | The block in [Self-signed certificates](docs/image.md#self-signed-certificates). It covers git, every JDK in the image, the CLI, Maven, Gradle and Node.js, so none of the old lines are needed. |
   | `MODERNE_CLI_VERSION` build argument | `MODERNE_WRAPPER_VERSION` environment variable, read when the container starts. Left unset, each container uses the newest release; if you pin it, migrate on the latest release rather than the version your old image had. See [The CLI version](docs/image.md#the-cli-version). |
   | CLI downloaded from an internal mirror | [Air-gapped installations](docs/image.md#air-gapped-installations). |
   | Several Node.js, Gradle or Maven versions | The image has one Node.js (22), one Gradle (8.14) and one Maven (3.9) for builds without a wrapper. If your repositories need others, add them and list them in `MOD_NODE_INSTALLATIONS_0`, `MOD_GRADLE_INSTALLATIONS_0`, and so on. |

3. Build the image and push it to your registry.

4. Rotate any credentials your old image had baked in. They are still in every copy of that image in your registry, and sometimes in the repository that built it.

## 4. Configure the artifact store

The CLI finds the store through environment variables, which replace whatever set it up before: `PUBLISH_URL` with `PUBLISH_USER`, `PUBLISH_PASSWORD` or `PUBLISH_TOKEN`, the `S3_*` variables, or a `mod config lsts artifacts <type> edit` command in your Dockerfile or script. Use the type you identified in [step 2](#2-put-the-complete-reposcsv-in-your-artifact-store).

1. Set the variables for that type:

   | Store type | Variables |
   |---|---|
   | S3 | `MOD_LSTS_ARTIFACTS_S3_URL=s3://<bucket>`, plus `MOD_LSTS_ARTIFACTS_S3_REGION`, `MOD_LSTS_ARTIFACTS_S3_ENDPOINTURL` or `MOD_LSTS_ARTIFACTS_S3_PROFILE` when needed |
   | Artifactory | `MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_URL`, with `MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_JFROGAPITOKEN`, or `MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_USERNAME` and `MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_PASSWORD` |
   | Maven | `MOD_LSTS_ARTIFACTS_MAVEN_0_URL`, with `MOD_LSTS_ARTIFACTS_MAVEN_0_USERNAME` and `MOD_LSTS_ARTIFACTS_MAVEN_0_PASSWORD` |

2. For Artifactory and Maven, any other credential goes in `_AUTHORIZATION` instead, set to the whole `Authorization` header value, such as `Bearer <access token>`. An Artifactory API key goes in `_JFROGAPITOKEN` for the Artifactory type, or in `_PASSWORD` with its user name for the Maven type.

The credentials need to overwrite files in the store, since every run replaces `repos-lock.csv`. [Publishing to S3](docs/s3.md) and [Publishing to Artifactory](docs/artifactory.md) cover credentials and permissions in more detail.

## 5. Connect to your tenant

The CLI obtains the license it needs to build private repositories from your tenant. The connection used to be set up with `mod config moderne edit` or the `MODERNE_TENANT` and `MODERNE_TOKEN` variables the script read.

1. Set the tenant variables:
   - `MOD_TENANT_HOST=https://<tenant>.moderne.io`
   - `MOD_TENANT_AUTHORIZATION=<token>`

   On Moderne DX, set `MOD_LICENSE_KEY` instead, which replaces `mod config license edit`.

## 6. Give it access to your Git repositories

Private repositories need credentials to clone. They used to come from the `GIT_CREDENTIALS` or `GIT_SSH_CREDENTIALS` variables, or from files copied into the image; they now come from files you mount into the container.

1. For HTTPS clone URLs, mount a `.git-credentials` file read-only at `/home/moderne/.git-credentials`, with one `https://<user>:<token>@<host>` line per host. It replaces the `GIT_CREDENTIALS` variable or a `.git-credentials` copied into the image; if `GIT_CREDENTIALS` held several, separated by `\n`, write each on its own line. The image already reads the file, so no `git config credential.helper` is needed.

2. For SSH clone URLs such as `git@github.com:acme/billing.git`, which used `GIT_SSH_CREDENTIALS` or a key copied into `/root/.ssh`:
   - Mount the private key read-only at `/home/moderne/.ssh/id_ed25519` (or `id_rsa`).
   - Mount your Git host's keys read-only at `/home/moderne/.ssh/known_hosts`. GitHub lists them at `https://api.github.com/meta`; for a self-hosted server, get them from its administrator or with `ssh-keyscan`, checking the fingerprints. Setting `GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=accept-new` instead works too, as the last `publish.sh` did, but since every run starts without a `known_hosts`, it accepts whatever host key it is shown each time.

   In Kubernetes, put both files in a secret:

   ```bash
   kubectl -n mass-ingest create secret generic mass-ingest-ssh \
     --from-file=id_ed25519=<path to the private key> \
     --from-file=known_hosts=<path to known_hosts>
   ```

   Then mount each one the way [`k8s/job.yaml`](k8s/job.yaml) mounts `.git-credentials`. Add these entries to the container's `volumeMounts` list, after the `git-credentials` one:

   ```yaml
               - name: ssh
                 mountPath: /home/moderne/.ssh/id_ed25519
                 subPath: id_ed25519
                 readOnly: true
               - name: ssh
                 mountPath: /home/moderne/.ssh/known_hosts
                 subPath: known_hosts
                 readOnly: true
   ```

   And this one to the pod's `volumes` list, after the `git-credentials` one:

   ```yaml
           - name: ssh
             secret:
               secretName: mass-ingest-ssh
               defaultMode: 0444
   ```

   With the single-machine script, add the two files as read-only `-v` mounts to the `docker run` line in [`docker/run.sh`](docker/run.sh), next to the `.git-credentials` one.

## 7. Carry over CLI settings

Every `mod config` setting is a property in the CLI's `moderne.yml`, and every property can be set with an environment variable instead: `java.options[0]` is `MOD_JAVA_OPTIONS_0`, `lsts.artifacts.s3.url` is `MOD_LSTS_ARTIFACTS_S3_URL`. Set them all as environment variables, and leave the image's [`cli/moderne.yml`](cli/moderne.yml) as it is.

Carry over the ones you had. The table lists the settings the old example set or suggested that earlier steps don't already cover; any other `mod config` line you added becomes a variable the same way.

| Old | New |
|---|---|
| `mod config java options edit "-Xmx4g -Xss3m"` | `MOD_JAVA_OPTIONS_0=-Xmx4g`, `MOD_JAVA_OPTIONS_1=-Xss3m` |
| `mod config features no-maven-central` | A mirror of `central,sonatype-central` in `maven/settings.xml`. |
| `BUILD_TIMEOUT` or the script's `--timeout <seconds>` (default 2700, for each repository's whole `mod build`) | A timeout per build tool, as an ISO 8601 duration between 10 minutes and a day: `MOD_MAVEN_BUILD_TIMEOUT=PT2H`, `MOD_GRADLE_BUILD_TIMEOUT`, `MOD_NODE_BUILD_TIMEOUT`, and so on. Each defaults to one hour (12 hours for Bazel), longer than the old 45 minutes, so set one only if you had raised the old timeout past an hour. |

## 8. Set up how it runs

Each container now runs `mod publish /var/moderne/ws --sync-csv`, works through the list one repository at a time, and exits. Parallelism comes from running several containers, each on one shard of the same list.

1. Pick where it runs: a [Kubernetes Job](docs/kubernetes.md), or [one machine with Docker](docs/docker.md). With Docker, every variable from steps 4 to 7 goes in the env file. In Kubernetes, the Job only reads the `mass-ingest-store` and `mass-ingest-moderne` secrets: the step 4 variables go in the first, the step 5 ones in the second, and `GIT_SSH_COMMAND` and the step 7 settings in either, unless you add your own secret to the Job's `envFrom`.

2. Size each container. It builds one repository at a time, so it needs less disk than a batch did: plan for your largest repository. Give it a memory limit equal to its request (12 GiB in the example). The CLI keeps each build below that limit, so a build that runs out of memory fails that one repository rather than the container.

Some old script options have no counterpart: `BATCH_SIZE` (the CLI keeps one repository on disk at a time), `DIAGNOSE=true` and `DIAGNOSE_ON_START=true` (replaced by `mod doctor` in the next step), and uploading build and sync logs to the store (read the container logs instead; `repos-lock.csv` records each repository's result).

## 9. Check the configuration

`mod doctor` reads the configuration and changes nothing, so you can run it while the old mass ingest is still running.

1. Run `mod doctor /var/moderne/ws --sync-csv` as the container's command, with the variables and files from steps 4 to 7. It reports the artifact store, the tenant connection, the trust store, the toolchains, and whether it can read `repos.csv`. With Docker, use the `docker run` in the README's [Configure and run it](README.md#3-configure-and-run-it). In Kubernetes, change the container's `args` in [`k8s/job.yaml`](k8s/job.yaml) to `['exec mod doctor /var/moderne/ws --sync-csv']`, create the Job with `SHARDS=1 CONCURRENCY=1` as [Running on Kubernetes](docs/kubernetes.md) shows, read its output with `kubectl logs -n mass-ingest job/<run>`, then put `args` back. When a check fails, the Job retries the pod twice, so the same report may appear three times.
2. Fix anything it fails on, and run it again.

## 10. Stop the old mass ingest

As long as the old mass ingest keeps running, the new one can't skip unchanged repositories and rebuilds everything on each run.

1. Stop the old one, including any `while true` loop or container that restarts it.
2. Make sure no run of it is still in progress.

## 11. Run the new mass ingest

The first run rebuilds every repository, because a row of `repos-lock.csv` is only skipped when the same CLI version produced it. Expect it to take as long as a full run of the old script.

1. Optionally, try part of the list first by adding `--organization <name>` to the `mod publish` command: in the `args` of [`k8s/job.yaml`](k8s/job.yaml), on the `docker run` line of [`docker/run.sh`](docker/run.sh), or, in a single `docker run`, as the whole command after the image name: `mod publish /var/moderne/ws --sync-csv --organization <name>`. It replaces the script option of the same name. A run on part of the list only updates the rows of the repositories it built; the other rows of `repos-lock.csv` stay as they are.
2. Run the whole list, without `--organization`.

## 12. Check the results

A run where some repositories fail still exits successfully, so the exit status alone doesn't tell you how it went.

1. Read the end of the container logs. They end with a summary such as `Published 1 LST; skipped 0 unchanged; 1 failed`, with a `✗` line above it for each repository that failed. When most of them fail, look at your Git credentials, build settings or store permissions rather than the repositories.
2. If the logs say `Failed to update the central repos-lock.csv`, the run exits with an error and needs to run again.
3. Check `repos-lock.csv`. It has a row for every repository in `repos.csv`. A successful build records where its LST was published, the commit it was built from and the CLI version. A failed build leaves its row as it was, still pointing to the last successful LST, and a repository that has never built has none of those three.
4. Check the connector's logs for warnings starting with `Enrichment`, `Failed to list artifacts` or `Listing failed`, which it logs when it can't read `repos-lock.csv`, list the artifact store, or read an LST. New LSTs appear in your tenant once the connector's next cycle picks them up.

## 13. Schedule it

The old script often ran in a loop or in a container that restarted it. The new command finishes when it has worked through the list, so something has to start the next run.

1. Schedule it with a Kubernetes CronJob or a scheduled Job (see [Running on Kubernetes](docs/kubernetes.md)), or with cron on a VM (see [Running on one machine](docs/docker.md#every-day)). A Kubernetes Deployment doesn't fit, since it restarts the pod as soon as it exits.
2. Retire the old image. If you run a periodic LST cleanup job, keep it: the new flow never deletes LSTs it published before.

## 14. Point the connector at repos-lock.csv

The connector can find LSTs in two ways: by reading `repos-lock.csv`, which records where each one was published, or by listing the artifact store (an organization source with a `poll` section). Reading the lock is the much preferred mode: the connector fetches each LST from the location recorded for it instead of searching the store, which is faster and stops it from re-reading LSTs it has already seen. Now that the new mass ingest keeps `repos-lock.csv` complete, switch to it if your connector still polls.

1. Make sure a full run has completed, so every repository has a row with a publish location.
2. Compare the organization columns of the `repos.csv` in your store with the hierarchy your tenant shows today. The lock carries those columns, so they become your tenant's organizations once the connector reads it.
3. Change the connector's organization source to the location of `repos-lock.csv` from [step 2](#2-put-the-complete-reposcsv-in-your-artifact-store), and remove its `poll` section. [Configure the Connector to find your repositories and their LSTs](https://docs.moderne.io/administrator-documentation/moderne-platform/how-to-guides/connector-configuration/connector-config/#step-5-configure-the-connector-to-find-your-repositories-and-their-lsts) covers the settings.
4. Check the connector's logs as in [step 12](#12-check-the-results).
