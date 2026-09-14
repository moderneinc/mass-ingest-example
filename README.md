# Mass ingest

Mass ingest is the pipeline that builds a [Lossless Semantic Tree (LST)](https://docs.moderne.io/user-documentation/recipes/authoring-recipes/concepts/lossless-semantic-trees) for every repository you give it and publishes each one to an artifact repository you control, where Moderne reads them. It usually runs once a day. Building LSTs on a schedule rather than in CI keeps every repository current, including the ones that rarely build and the ones whose code hasn't changed but whose dependencies have; [Mass ingest vs CI builds](https://docs.moderne.io/administrator-documentation/moderne-platform/references/mass-ingest-vs-ci) explains why.

This repository packages mass ingest as a container image, and running it takes three steps.

## 1. List your repositories

Put a `repos.csv` at the root of the artifact repository your LSTs will go to:

```csv
cloneUrl,branch,origin,path,org1
https://github.com/acme/billing,main,github.com,acme/billing,Payments
https://github.com/acme/claims-api,,github.com,acme/claims-api,Claims
```

Every row needs a `cloneUrl`, `origin` and `path`. A blank `branch` means the default branch, and the optional `org1`, `org2`, ... columns place the repository in your organization. [repository-fetchers](https://github.com/moderneinc/repository-fetchers) can generate this file from GitHub, GitLab or Bitbucket, and the [repos.csv reference](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv) describes the other columns.

## 2. Build the image

```bash
docker build -t registry.example.com/mass-ingest .
docker push registry.example.com/mass-ingest
```

The image contains the toolchains your builds might need, from JDKs 8 through 25 to Node.js, Python, .NET and Go, and it installs the newest [Moderne CLI](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro) each time it starts. [Customizing the image](docs/image.md) covers pinning the CLI version, internal mirrors and certificates.

## 3. Run it

A run is configured entirely with environment variables. Tell it where to publish, with the variables for [S3](docs/s3.md) or [Artifactory](docs/artifactory.md), and how to reach Moderne: SaaS customers set `MOD_TENANT_HOST` and `MOD_TENANT_AUTHORIZATION` for their tenant, and Moderne DX customers set their license key in `MOD_LICENSE_KEY` (an air-gapped installation also [installs the CLI into the image](docs/image.md#air-gapped-installations)). For private repositories, mount a `.git-credentials` file at `/home/moderne/.git-credentials`.

Start with `mod doctor`, which checks that everything is in place without changing anything and suggests a fix for anything that isn't:

```bash
docker run --rm \
  -e MOD_LSTS_ARTIFACTS_S3_URL=s3://your-bucket \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_REGION \
  -v "$HOME/.git-credentials:/home/moderne/.git-credentials:ro" \
  registry.example.com/mass-ingest mod doctor /var/moderne --sync-csv
```

<img src="docs/doctor.png" alt="mod doctor output: host resources, CLI configuration and toolchains, each with a pass, warning or info mark" width="640">

Once it passes, run the same command without the `mod doctor ...` arguments. The image runs `mod publish --sync-csv`, which works through `repos.csv` one repository at a time, publishes each LST and records it in a `repos-lock.csv` next to the list. The next run skips every repository that hasn't changed.

## Running every day

A large list finishes sooner split into shards, with each container running `mod publish /var/moderne/ws --sync-csv --shard i/M` for its own `i`. Any scheduler that runs containers can do this. [Running on one machine](docs/docker.md) does it with a short shell script on a single large VM, and [Running on Kubernetes](docs/kubernetes.md) does it with a Kubernetes Job; both cover sizing and what happens when a build fails.

## Support

The [Moderne CLI documentation](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro) covers the commands used here in more depth, and problems with this example belong in its [issues](https://github.com/moderneinc/mass-ingest-example/issues).

This example code is provided as-is for use with Moderne products.
