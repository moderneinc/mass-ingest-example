# AWS CodeArtifact

CodeArtifact is a standard Basic-auth Maven repository whose password is a token minted with `aws codeartifact get-authorization-token` and valid for at most 12 hours. The scripts mint it at startup and refresh it in the background at three quarters of its lifetime for as long as the ingest runs. A changed environment variable cannot reach the running CLI, so each refresh rewrites what is read from disk instead: the CLI's publish configuration, a rendered `~/.m2/settings-codeartifact.xml` for Maven and `~/.codeartifact-token` for the Gradle init script. After the run, every uploaded package version is moved to `Published`: CodeArtifact keeps versions uploaded without a `maven-metadata.xml` as `Unfinished`, and its Maven endpoint answers 404 for those, which would hide the LSTs and the catalog from the platform.

## Authentication

Use an IAM role attached to the compute (a Batch job role, ECS task role or EC2 instance profile); the AWS CLI in the container picks it up. Static keys work through `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` if you must. The principal needs

* `codeartifact:GetAuthorizationToken`
* `codeartifact:ListPackages`
* `codeartifact:ListPackageVersions`
* `codeartifact:PublishPackageVersion`
* `codeartifact:PutPackageMetadata`
* `codeartifact:ReadFromRepository`
* `codeartifact:UpdatePackageVersionsStatus`
* `sts:GetServiceBearerToken`

## Image setup

In the `Dockerfile`, uncomment the AWS CLI install block, then in the "AWS CodeArtifact" section the lines for the build tools your repositories use:

- **Maven**: `COPY maven/settings-codeartifact.xml /app/maven/settings-codeartifact.xml`. publish.sh renders it with the current token and registers the copy only on a CodeArtifact run, so the same image still builds Maven projects in S3/Artifactory runs. It ships with a catch-all mirror (`<mirrorOf>*</mirrorOf>`), so everything resolves through CodeArtifact and anything it cannot reach fails the build; narrow the mirror to let other repositories resolve directly. A `/home/moderne/.m2/settings.xml` you supply yourself is left untouched, so merge the `<server>` and `<mirror>` into it.
- **Gradle**: `COPY gradle/init-codeartifact.gradle /app/gradle/init-codeartifact.gradle` plus the `mod config build gradle arguments edit` line. The init script adds CodeArtifact as an additional repository and no-ops when CodeArtifact is not in use, so Gradle builds keep their own repositories and are not forced through CodeArtifact.

Gradle ignores `settings.xml`, so configure every build tool your portfolio uses; an unconfigured tool resolves entirely from public repositories, and publish.sh warns when neither is set up.

Both tools resolve only what CodeArtifact serves: `PUBLISH_URL` plus its upstream chain. Public repositories must come from CodeArtifact's fixed list of external connections (Maven Central, Google Android, Gradle Plugin Portal, CommonsWare, Clojars); an arbitrary remote cannot be proxied. The token is domain-scoped, so a different domain or account is out of reach.

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `PUBLISH_URL` | yes | CodeArtifact Maven HTTPS endpoint, e.g. `https://my-domain-111122223333.d.codeartifact.us-east-1.amazonaws.com/maven/my-repo/` |
| `CODEARTIFACT_DOMAIN` | yes | Domain name; setting it selects the CodeArtifact path. |
| `CODEARTIFACT_DOMAIN_OWNER` | optional | Account ID owning the domain; derived from `PUBLISH_URL` when unset. |
| `CODEARTIFACT_REGION` | optional | Region of the domain; derived from `PUBLISH_URL` when unset. |
| `CODEARTIFACT_TOKEN_DURATION` | optional | Token lifetime in seconds (default 12h). `0` ties it to the role session; the refresher then assumes the 15 minute minimum. |

Do not set `PUBLISH_USER` / `PUBLISH_PASSWORD`; the script authenticates the publish target with `aws` and the current token.

```bash
docker run --rm -p 8080:8080 -v "$(pwd)/data:/var/moderne" \
  -e PUBLISH_URL=https://my-domain-111122223333.d.codeartifact.us-east-1.amazonaws.com/maven/my-repo/ \
  -e CODEARTIFACT_DOMAIN=my-domain \
  mass-ingest
```

## Known limitations

- **Assets are immutable.** `repos.csv` and `repos-lock.csv` live at fixed Maven coordinates (`io/moderne/organization/sources/{repos,repos-lock}/1.0.0/`), and CodeArtifact returns HTTP 409 for every upload after the first, including the periodic lock flushes. LST jars use unique coordinates and are unaffected. To change `repos.csv` or rebuild the catalog, delete the `repos` or `repos-lock` version first (`aws codeartifact delete-package-versions`).
- **The platform must read the published catalog rather than poll.** CodeArtifact offers neither a Maven index nor an Artifactory-style query API, so the tenant's artifact source must be configured without a `poll:` block ("lock mode").
- `publish.ps1` implements the same path on Windows; it looks for `maven/settings-codeartifact.xml` and `gradle/init-codeartifact.gradle` next to itself and renders into `%USERPROFILE%\.m2\settings-codeartifact.xml` and `%USERPROFILE%\.codeartifact-token`.
