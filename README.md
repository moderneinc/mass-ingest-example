# Mass Ingest

This example demonstrates how to use the [Moderne CLI](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro) to ingest a large number of repositories into a Moderne platform.

## Step 1: Create a `repos.csv` file

The first step needed to integrate private code is to come up with a list of repositories that should be ingested (`repos.csv`). This list should be in a CSV format with the first row composed of headers for the columns.

At the very least, you must include two columns: `cloneUrl` and `branch`. However, you can also include additional optional columns if additional information is needed to build your repositories. These optional columns are: `changeset`, `java`, `jvmOpts`, `mavenArgs`, `gradleArgs`, and `bazelRule` (see the [mod git clone csv documentation](https://docs.moderne.io/user-documentation/moderne-cli/cli-reference#mod-git-clone-csv) for more information).

If you use GitHub, you may find it useful to use the GitHub CLI to generate a list of repositories for your organization. For instance, the following command would generate a `repos.csv` file for the `spring-projects` GitHub organization:

```bash
echo "cloneUrl,branch" > repos.csv
gh repo list spring-projects --source --no-archived --limit 1000 --json sshUrl,defaultBranchRef --template "{{range .}}{{.sshUrl}},{{.defaultBranchRef.name}}{{\"\n\"}}{{end}}" >> repos.csv
```

For other source code managers, we've created scripts that can help you create your `repos.csv` file. These can be found in the [repo-fetchers](/repo-fetchers/README.md) section of this repository.

## Step 2: Customize the Docker image

Begin by copying the [provided Dockerfile](/Dockerfile) to your ingestion repository.

From there, we will modify it depending on your organizational needs. Please note that the ingestion process requires access to several of your internal systems to function correctly. This includes your source control system, your artifact repository, and your Moderne tenant or DX instance.

### Self-Signed Certificates

If your internal services (artifact repository, source control, or the Moderne tenant) are accessed:

* Over HTTPS and they require [SSL/TLS](https://en.wikipedia.org/wiki/Transport_Layer_Security), but have certificates signed by a trusted-by-default root Certificate Authority.
* Over HTTP (never requiring SSL/TLS)

Please comment out the following lines from your Dockerfile: 

```Dockerfile
# Configure trust store if self-signed certificates are in use for artifact repository, source control, or moderne tenant
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-8-jdk/jre/lib/security/cacerts
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-11-jdk/lib/security/cacerts
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts
```

If your internal services, instead, use self-signed certs, you will need to configure the CLI and JVMs installed within the Docker image to trust your organization's self-signed certificate:

When invoking, Docker, supply the `TRUSTED_CERTIFICATES_PATH` argument pointing to an appropriate [cacerts file](https://www.ibm.com/docs/en/sdk-java-technology/8?topic=certificate-cacerts-certificates-file).

If you are not sure where to get a suitable cacerts file, you can check out your local machine as you probably have one there. On JDK 8, you can find your cacerts file within its installation directory under `jre/lib/security/cacerts`. On newer JDK versions, you can find your cacerts file within is installation directory under `lib/security/cacerts`.

### Artifact repository

The CLI needs access to artifact repositories to publish the LSTs produced during the ingestion process. This is configured via the `PUBLISH_URL`, `PUBLISH_USER`, and `PUBLISH_PASSWORD` [arguments in the Dockerfile](/Dockerfile#L18-L20).

We recommend configuring a repository specifically for LSTs. This avoids intermixing LSTs with other kinds of artifacts – which has several benefits. For instance, updates and improvements to Moderne's parsers can make publishing LSTs based on the same commit desirable. However, doing so could cause problems with version number collisions if you've configured it in another way. 

Keeping LSTs separate also simplifies the cleanup of old LSTs which are no longer relevant – a policy you would not wish to accidentally apply to your other artifacts. 

Lastly, LSTs must be published to Maven-formatted artifact repositories, but repositories with non-JVM code likely publish artifacts to repositories of other types.

### Source Control Credentials

Most source control systems require authentication to access their repositories. If your source control **does not** require authentication to `git clone` repositories, comment out the [following lines](/Dockerfile#L35-L36):

```Dockerfile
ADD .git-credentials /root/.git-credentials
RUN git config --global credential.helper store --file=/root/.git-credentials
```

In the more common scenario that your source control does require authentication, you will need to create and include a `.git-credentials` file. You will want to supply the credentials for a service account with access to all repositories.

Each line of the `.git-credentials` file specifies the `username` and plaintext `password` for a particular `host` in the format:

```
https://username:password@host
```

For example:

```
https://sambsnyd:likescats@github.com
```

### Maven Settings

If your organization **does not** use the Maven build tool, comment out the [following lines](/Dockerfile#L30-L31):

```Dockerfile
ADD maven/settings.xml /root/.m2/settings.xml
RUN java -jar mod.jar config build maven settings edit /root/.m2/settings.xml
```

If your organization does use Maven, you more than likely have shared configurations in a `settings.xml` file. This configuration file is usually required to build most repositories. You'll want to ensure that the Docker image points to the appropriate file. `settings.xml` is typically located at `~/.m2/settings.xml`, but your configuration may differ.

### Moderne Tenant or DX instance

Connection to a Moderne tenant allows the CLI to determine when it is unnecessary to re-build an LST (as the LST could be downloaded instead to save time). The `MODERNE_TENANT` and `MODERNE_TOKEN` arguments are required to connect to a Moderne tenant.

If you are connecting to a Moderne DX instance, you will need to provide the token it was configured to accept on startup. If you are connecting to a Moderne tenant, you will need to create and use a [Moderne personal access token](https://docs.moderne.io/user-documentation/moderne-platform/how-to-guides/create-api-access-tokens). 

## Step 3: Build the Docker image

Once you've customized the `Dockerfile` as needed, you can build the image with the following command, filling in your organization's specific values for the build arguments:

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

## Step 4: Deploy and run the image

Now that you have a Docker image built, you will need to deploy it to the container management platform of your choice and have it run on a schedule. We will leave this as an exercise for the reader as there are many platforms and options for running this. 

<!--
## Step 5: Monitor the ingestion process

TODO: Explain how to access grafana, and where the logs are published.

## Step 6: Troubleshooting

If you want to verify that the image works as expected locally, you can spin it up with the following command:
```bash
docker run -it --rm moderne-mass-ingest:latest -p 3000:3000 -p 8080:8080 -p 9090:9090
```

In case you wish to debug the image, you can suffix the above with `bash`, and from there run `./publish.sh` to see the ingestion process in action.
-->
