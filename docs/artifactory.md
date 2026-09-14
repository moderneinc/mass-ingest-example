# Publishing to Artifactory

An Artifactory repository takes its URL and an API token:

```bash
MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_URL=https://artifactory.example.com/artifactory/moderne-lsts
MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_JFROGAPITOKEN=<api token>
```

The `0` is there because the CLI's configuration holds a list of artifact stores, and a mass ingest only needs the first. The CLI sends the token in Artifactory's `X-JFrog-Art-Api` header. If you authenticate with an access token or a username and password instead, leave the API token out and set `MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_AUTHORIZATION` to the whole `Authorization` header value, either `Bearer <access token>` or `Basic ` followed by the output of `printf '<user>:<password>' | base64`.

`repos.csv` goes at the root of the repository, and the CLI writes `repos-lock.csv` next to it. A repository configured with a strict Maven layout rejects files at its root, so either give the LSTs a repository with a simple layout or configure the strict one as a plain Maven repository, below.

The token needs to read, deploy and overwrite in that repository. Overwrite, Artifactory's Delete/Overwrite permission, is the one that's easy to miss: every run replaces `repos-lock.csv`, so without it the first run records its results and every later run fails to.

In Kubernetes, both variables go in the `mass-ingest-store` secret:

```bash
kubectl -n mass-ingest create secret generic mass-ingest-store \
  --from-literal=MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_URL=https://artifactory.example.com/artifactory/moderne-lsts \
  --from-literal=MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_JFROGAPITOKEN=<api token>
```

An Artifactory served with a certificate from your own certificate authority needs that certificate in the image; see [Self-signed certificates](image.md#self-signed-certificates).

## Nexus and other Maven repositories

Any other Maven repository works through the CLI's plain Maven store, which authenticates with an `Authorization` header:

```bash
MOD_LSTS_ARTIFACTS_MAVEN_0_URL=https://nexus.example.com/repository/moderne-lsts
MOD_LSTS_ARTIFACTS_MAVEN_0_AUTHORIZATION=Basic <base64 of user:password>
```

Repositories like Nexus's hosted Maven 2 format only accept files at a Maven coordinate, so for this store `repos.csv` goes at `io/moderne/organization/sources/repos/1.0.0/repos-1.0.0.csv`, and the CLI writes the lock at `io/moderne/organization/sources/repos-lock/1.0.0/repos-lock-1.0.0.csv`. Overwriting matters here for the same reason as in Artifactory, which in Nexus means a deployment policy that allows redeploy.
