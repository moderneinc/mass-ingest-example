# Building the image

```bash
docker build -t mass-ingest .                                     # latest CLI release
docker build -t mass-ingest --build-arg MODERNE_CLI_VERSION=4.9.0 .
docker build -f Dockerfile.fips -t mass-ingest:fips .             # FIPS variant
```

## Build arguments

Both Dockerfiles take:

| Argument | Default | Description |
|---|---|---|
| `MODERNE_CLI_VERSION` | *(latest release)* | CLI version to install |
| `MODERNE_CLI_STAGE` | `release` | `snapshot` for the latest snapshot; snapshots re-resolve on every run |
| `MODERNE_CLI_RELEASES_REPO` | `https://artifacts.codegenomeproject.org/maven` | Maven repository for release CLI artifacts |
| `MODERNE_CLI_SNAPSHOTS_REPO` | `https://artifacts.codegenomeproject.org/maven` | Maven repository for snapshot CLI artifacts |
| `MAVEN_REPO_URL` | `https://repo1.maven.org/maven2` | Where the Maven distribution is downloaded from |
| `GRADLE_DIST_URL` | `https://services.gradle.org/distributions` | Where Gradle distributions are downloaded from |
| `GRADLE_VERSION` | `8.14` | Primary Gradle version |
| `GRADLE_EXTRA_VERSIONS` | *(empty)* | Comma-separated extra Gradle versions (e.g. `6.9.4,5.6.4`), selected per repository with the `gradleVersion` column |
| `MAVEN_VERSION` | `3.9.11` | Maven version |

The CLI comes from the [Code Genome Project](https://docs.moderne.io/administrator-documentation/moderne-platform/how-to-guides/accessing-the-code-genome-project/) (CGP), which serves it anonymously: both the `modw` wrapper and the distribution it installs. The build resolves a concrete version and pins it with its download URL in `moderne-wrapper.properties`, so the running container never re-resolves the CLI; rebuild to pick up a new release. CGP serves only `org.openrewrite` and `io.moderne`; the Maven and Gradle distributions and the dependencies of the repositories you ingest come from their own upstreams.

### Internal mirrors

In an egress-blocked environment, mirror `io.moderne:moderne-cli` and the `moderne-cli-linux-{x64,aarch64}` distributions into your repository manager and point every download there:

```bash
docker build \
  --build-arg GRADLE_DIST_URL=https://artifactory.internal/artifactory/data-local/gradle \
  --build-arg MAVEN_REPO_URL=https://artifactory.internal/artifactory/maven-central \
  --build-arg MODERNE_CLI_RELEASES_REPO=https://artifactory.internal/artifactory/moderne \
  -t mass-ingest .
```

`GRADLE_DIST_URL` is used as `${GRADLE_DIST_URL}/gradle-<version>-bin.zip` and `MAVEN_REPO_URL` as `${MAVEN_REPO_URL}/org/apache/maven/apache-maven/<version>/apache-maven-<version>-bin.tar.gz`. The base images (`eclipse-temurin`, or `registry.access.redhat.com/ubi9/ubi` for FIPS) are pulled by the Docker daemon; mirror those through your registry configuration.

## Customizing the Dockerfile

The Dockerfile is organized as commented sections to uncomment:

- **Language support**: Node.js, Python, .NET, Bazel, the Android SDK. `moderne.yml` (copied by the "Custom build steps" line) adds the JavaScript and Python build steps.
- **Self-signed certificates**: a `certs/` directory imported into every JDK trust store. The import runs as root, so it stays above the `USER 1000` switch; the matching `mod config http trust-store edit java-home` runs below it.
- **Maven settings**: `COPY maven/settings.xml /home/moderne/.m2/settings.xml` plus `mod config build maven settings edit`, in the CLI CONFIGURATION section so it lands in the non-root user's home. `npm/.npmrc` and `python/pip.conf` follow the same pattern.
- **JVM options**: `mod config java options edit "-Xmx4g -Xss3m"`; raise `-Xmx` if builds run out of memory.
- **GCP Batch**: `COPY 3-scalability/gcp-batch/task.sh task.sh`.

## FIPS image

`Dockerfile.fips` builds on Red Hat UBI 9 with the FIPS crypto policy enabled, restricting all cryptography (OpenSSL, Java) to FIPS-approved algorithms; the host kernel must also run in FIPS mode for full compliance. Same build arguments, same `docker run` invocations.

Public download servers may not negotiate FIPS-compliant TLS, so the Dockerfile downloads in a separate non-FIPS stage, except that `modw` fetches the CLI distribution from the FIPS-enabled stage. With internal mirrors that support FIPS-compliant TLS you can fold the `downloader` stage into `base` (after the `dnf install` that provides `curl`) to make the whole build FIPS-compliant.

RHEL 9 backported TLS 1.3 into JDK 8 and 11 with a `P11AEADCipher` bug that fails AES-GCM decryption under NSS in FIPS mode (`CKR_ENCRYPTED_DATA_INVALID`), so the Dockerfile disables TLS 1.3 for those two JDKs; JDK 17+ is unaffected. Certificates go into the system trust store (`update-ca-trust`) rather than per-JDK keytool imports.

| | `Dockerfile` | `Dockerfile.fips` |
|---|---|---|
| Base image | Eclipse Temurin (Ubuntu) | Red Hat UBI 9 |
| JDKs | Temurin 8, 11, 17, 21, 25 | Red Hat OpenJDK 8, 11, 17, 21, 25 |
| Crypto policy | default | FIPS |
| Certificates | per-JDK keytool | system trust store |

## Non-root user

Both images run as `moderne` (UID 1000, GID 0), so `runAsNonRoot: true` pod policies need no extra configuration, and the writable directories (`/home/moderne`, `/var/moderne`, `/app`) are group-writable by GID 0 so the images also work where an arbitrary UID is assigned at runtime (OpenShift). Two consequences:

- A host directory bind-mounted at `/var/moderne` must be writable by UID 1000: create it as your regular user (`mkdir data`) before `docker run`, or Docker creates it as root.
- Credential files mounted into `/home/moderne` must be readable by UID 1000; SSH keys at mode 600 must therefore be owned by UID 1000 on the host.

## Disk

`/var/moderne` holds one repository at a time plus the CLI's trace csvs and its type-table store (symlinked from the CLI home so hard links land on the same filesystem). 32 GB covers most portfolios; the largest single repository sets the floor.
