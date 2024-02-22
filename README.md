# Mass Ingest

This example demonstrates how to use the `mod` CLI to ingest a large number of repositories into a Moderne platform.

See also:
https://docs.moderne.io/administrator-documentation/moderne-platform/how-to-guides/integrating-private-code

## Creating `repos.csv`

The input for the ingestion process is a CSV file of repositories to ingest, one per line.

If you're using GitHub the `gh` CLI is a convenient way to generate this list of repositories.
```bash
echo "cloneUrl,branch" > repos.csv
gh repo list openrewrite --source --no-archived --limit 1000 --json sshUrl,defaultBranchRef --template "{{range .}}{{.sshUrl}},{{.defaultBranchRef.name}}{{\"\n\"}}{{end}}" >> repos.csv
```

Additional columns can be provided as necessary, but the `cloneUrl` and `branch` columns are required.
Also see [`mod git clone csv` documentation](https://docs.moderne.io/user-documentation/moderne-cli/cli-reference#mod-git-clone-csv).

## Customizing the Docker image

The ingest process requires access to several of your internal systems to function correctly. 
This includes your source control system, artifact repository, and Moderne tenant or DX instance.

### Self-Signed Certificates

Some organizations configure their internal services with self-signed certificates.
Comment out the following lines from the `Dockerfile` if your services are accessed:
* Over https/require [SSL/TLS](https://en.wikipedia.org/wiki/Transport_Layer_Security) but have certificates signed by a trusted-by-default root Certificate Authority.
* Over http, never requiring SSL/TLS

```Dockerfile
# Configure trust store if self-signed certificates are in use for artifact repository, source control, or moderne tenant
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-8-jdk/jre/lib/security/cacerts
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-11-jdk/lib/security/cacerts
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts
```

If you access any of these services over https/SSL you will need to configure the CLI and JVMs installed within the Docker image
to trust your organization's self-signed certificates.

When invoking docker, supply the `TRUSTED_CERTIFICATES_PATH` argument pointing to an appropriate cacerts file

If you are not sure where to get a suitable cacerts file you probably have one on your local machine.
On JDK 8 you can find your cacerts file within its installation directory under `jre/lib/security/cacerts`.
On newer JDK versions you can find your cacerts file within its installation directory under `lib/security/cacerts`.

### Artifact repository

The CLI needs access to artifact repositories to publish the LSTs produced during ingest.
This is configured via the `PUBLISH_URL`, `PUBLISH_USER`, and `PUBLISH_PASSWORD` arguments to the `Dockerfile`. 

We recommend configuring a repository specifically for LSTs.
This avoids intermixing LSTs with other kinds of artifacts, which has several benefits. 
Updates and improvements to Moderne's parsers can make publishing LTSs based on the same commit desirable, 
which can cause problems with version number collisions in other arrangements.
Keeping LSTs separate also simplifies the cleanup of old LSTs which are no longer relevant, a policy you would not wish 
to accidentally apply to your other artifacts.
LSTs are must be published to maven-formatted artifact repositories, but repositories with non-JVM code likely publish artifacts to repositories of other types.

### Source Control Credentials

Most source control systems require authentication to access their repositories. 
If your source control does not require authentication to `git clone` repositories, comment out these lines:
```dockerfile
ADD .git-credentials /root/.git-credentials
RUN git config --global credential.helper store --file=/root/.git-credentials
```

In the more common scenario that your source control does require authentication, you will need to create and include a `.git-credentials` file.
You will want to supply the credentials for a service account with access to all repositories.

Each line of .gitcredentials specifies the `username` and plaintext `password` for a particular `host` in the format:
```
https://username:password@host
```
For example:
```
https://sambsnyd:likescats@github.com
```

### Maven Settings

If your organization does not use the Maven build tool comment out these lines:
```dockerfile
ADD ~/.m2/settings.xml /root/.m2/settings.xml
RUN java -jar mod.jar config build maven settings edit /root/.m2/settings.xml
```
Within organizations which use Maven it is common to put shared configuration for the build in a settings.xml file.
Often this configuration file is required to build most repositories.

settings.xml is typically located at `~/.m2/settings.xml`, but your configuration may differ.

### Moderne Tenant or DX instance

Connection to a Moderne tenant allows the CLI to determine when it is unnecessary to re-build an LST.
The `MODERNE_TENANT` and `MODERNE_TOKEN` arguments are required to connect to a Moderne tenant.

If you are connecting to a Moderne DX instance, you will need to provide the token it was configured to accept on startup.
If you are connecting to a Moderne tenant, you can create an access token from `settings/access-token`.

## Building the Docker image

`Dockerfile`, you can build the image with the following command, filling in your organization's specific values for the build arguments:
```bash
docker build -t moderne-mass-ingest:latest \
    --build-arg MODERNE_TENANT=<> \
    --build-arg MODERNE_TOKEN=<> \
    --build-arg TRUSTED_CERTIFICATES_PATH=<> \
    --build-arg PUBLISH_URL=<> \
    --build-arg PUBLISH_USER=<> \
    --build-arg PUBLISH_PASSWORD=<> \
    .
```

Also see [the complete list of configuration options](https://docs.moderne.io/user-documentation/moderne-cli/cli-reference),

