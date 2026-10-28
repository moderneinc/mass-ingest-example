# Artifact stores

- [S3](#s3)
- [Google Cloud Storage](#google-cloud-storage)
- [Azure Blob Storage](#azure-blob-storage)
- [Artifactory](#artifactory)
- [Nexus and other Maven repositories](#nexus-and-other-maven-repositories)

The container learns where to publish from the environment variables of one store below. In Kubernetes they go in the `mass-ingest-store` secret, and with Docker in the [`mass-ingest.env`](docker.md) file that `docker/run.sh` gives every container. The Artifactory and Maven variables carry a `0` because the CLI keeps those stores in numbered lists; keep it at `0`. If several stores are set, the CLI publishes to the first of Maven, Artifactory, S3, Google Cloud Storage and Azure Blob Storage.

The CLI reads `repos.csv` from the root of the store and writes `repos-lock.csv` next to it. For S3, Google Cloud Storage and Azure Blob Storage, the URL stops at the bucket or container: `s3://your-bucket` works, `s3://your-bucket/lsts` is rejected. Every run replaces `repos-lock.csv`, so the credentials need to read, write and overwrite. Without overwrite, the first run records its results and every later run fails to.

## S3

```bash
MOD_LSTS_ARTIFACTS_S3_URL=s3://your-bucket
```

The CLI finds credentials wherever the AWS SDK looks for them. That principal needs `s3:GetObject` and `s3:PutObject` on the bucket's objects and `s3:ListBucket` on the bucket.

On EKS, associate an IAM role with the `mass-ingest` service account through [Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) (or IRSA), and no key is needed:

```bash
aws eks create-pod-identity-association --cluster-name <cluster> \
  --namespace mass-ingest --service-account mass-ingest --role-arn <role-arn>
```

Elsewhere, set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_REGION`, or use the output of `aws configure export-credentials --format env`.

A container run straight on an EC2 instance can't reach the instance role by default: Docker's bridge network puts it one hop further from the metadata service than IMDSv2 allows, and `mod publish` fails with `Unable to contact EC2 metadata service`. Raise the hop limit to 2:

```bash
aws ec2 modify-instance-metadata-options --instance-id <instance-id> --http-put-response-hop-limit 2
```

`MOD_LSTS_ARTIFACTS_S3_REGION` sets the region when the bucket isn't in the credentials' default region. `MOD_LSTS_ARTIFACTS_S3_ENDPOINTURL` points the CLI at an S3-compatible store such as MinIO, usually with static keys.

## Google Cloud Storage

```bash
MOD_LSTS_ARTIFACTS_GCS_URL=gs://your-bucket
```

The CLI uses Application Default Credentials. On GKE, grant the `mass-ingest` service account access through [Workload Identity Federation](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) and no key is needed. Elsewhere, mount a service account key and set `MOD_LSTS_ARTIFACTS_GCS_CREDENTIALSFILE` to its path.

That identity needs Storage Object User (`roles/storage.objectUser`) on the bucket. Storage Object Creator is not enough, because Cloud Storage only lets an identity replace an object it is allowed to delete.

`MOD_LSTS_ARTIFACTS_GCS_PROJECT` sets the project billed for a requester-pays bucket. `MOD_LSTS_ARTIFACTS_GCS_ENDPOINTURL` replaces `storage.googleapis.com`, for a Private Service Connect endpoint for example.

## Azure Blob Storage

```bash
MOD_LSTS_ARTIFACTS_AZUREBLOB_URL=https://youraccount.blob.core.windows.net/your-container
```

By default the CLI authenticates with Microsoft Entra ID, using whatever identity the environment provides: a managed identity on an Azure VM or a service principal in `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_CLIENT_SECRET`. That identity needs Storage Blob Data Contributor on the container, for reading and writing its blobs.

Without an Entra ID identity, set `MOD_LSTS_ARTIFACTS_AZUREBLOB_SASTOKEN` to a container SAS with the same access (Read, Write and List permissions), or `MOD_LSTS_ARTIFACTS_AZUREBLOB_CONNECTIONSTRING` to the storage account's connection string, which grants access to every container in the account.

## Artifactory

```bash
MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_URL=https://artifactory.example.com/artifactory/moderne-lsts
MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_JFROGAPITOKEN=<api token>
```

The CLI sends the token in Artifactory's `X-JFrog-Art-Api` header. To authenticate with a username and password instead, set `MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_USERNAME` and `MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_PASSWORD` (CLI 4.9.1 or later). With an access token, set `MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_AUTHORIZATION` to `Bearer <access token>`.

Overwrite is Artifactory's Delete/Overwrite permission, the one that's easy to miss. A repository configured with a strict Maven layout rejects files at its root, so either give the LSTs a repository with a simple layout or configure the strict one as a plain Maven repository, below. An Artifactory served with a certificate from your own certificate authority needs that certificate in the image; see [Self-signed certificates](image.md#self-signed-certificates).

## Nexus and other Maven repositories

```bash
MOD_LSTS_ARTIFACTS_MAVEN_0_URL=https://nexus.example.com/repository/moderne-lsts
MOD_LSTS_ARTIFACTS_MAVEN_0_USERNAME=<user>
MOD_LSTS_ARTIFACTS_MAVEN_0_PASSWORD=<password>
```

The username and password need CLI 4.9.1 or later. Any other credential goes in `MOD_LSTS_ARTIFACTS_MAVEN_0_AUTHORIZATION`, set to the whole `Authorization` header value, such as `Bearer <token>`.

Repositories like Nexus's hosted Maven 2 format only accept files at a Maven coordinate, so for this store `repos.csv` goes at `io/moderne/organization/sources/repos/1.0.0/repos-1.0.0.csv`, and the CLI writes the lock at `io/moderne/organization/sources/repos-lock/1.0.0/repos-lock-1.0.0.csv`. Overwriting needs a deployment policy that allows redeploy.
