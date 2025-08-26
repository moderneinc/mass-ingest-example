# Mass Ingest

This example demonstrates how to use the [Moderne CLI](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro) to ingest a large number of repositories into a Moderne platform.

## Step 1: Create a `repos.csv` file

The first step needed to integrate private code is to come up with a list of repositories that should be ingested (`repos.csv`). This list should be in a CSV format with the first row composed of headers for the columns.

At the very least, you must include two columns: `cloneUrl` and `branch`. However, you can also include additional optional columns if additional information is needed to build your repositories. 

For a list of all of the columns and configuration options, please check out our [creating a repos.csv reference doc](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv).

> [!TIP]
> We offer scripts to assist you in generating your repos.csv file. You can find them in the [repo-fetchers](https://github.com/moderneinc/repository-fetchers) repository.

## Step 2: Customize the Docker image

Begin by copying the [provided Dockerfile](/Dockerfile) to your ingestion repository.

From there, we will modify it depending on your organizational needs. Please note that the ingestion process requires access to several of your internal systems to function correctly. This includes your source control system, your artifact repository, and your Moderne tenant or DX instance.

### Self-Signed Certificates

If your internal services use self-signed certificates, provide your custom CA certificate via the `CUSTOM_CA_CERT` environment variable:

```bash
CUSTOM_CA_CERT="-----BEGIN CERTIFICATE-----
[your certificate content]
-----END CERTIFICATE-----"
```

This will automatically configure the CLI and all JVMs within the Docker image to trust your organization's certificate. The certificate will be imported into the Java trust stores and configured for use by the mod CLI at container startup.

### Artifact repository

The CLI needs access to artifact repositories to publish the LSTs produced during the ingestion process. This is configured via the `PUBLISH_URL`, `PUBLISH_USER`, and `PUBLISH_PASSWORD` [arguments in the Dockerfile](/Dockerfile#L18-L20).

We recommend configuring a repository specifically for LSTs. This avoids intermixing LSTs with other kinds of artifacts – which has several benefits. For instance, updates and improvements to Moderne's parsers can make publishing LSTs based on the same commit desirable. However, doing so could cause problems with version number collisions if you've configured it in another way. 

Keeping LSTs separate also simplifies the cleanup of old LSTs which are no longer relevant – a policy you would not wish to accidentally apply to your other artifacts. 

Lastly, LSTs must be published to Maven-formatted artifact repositories, but repositories with non-JVM code likely publish artifacts to repositories of other types.

### Source Control Credentials

Most source control systems require authentication to access their repositories. Credentials are provided via environment variables at container runtime, allowing your container orchestration platform (Kubernetes, Docker Swarm, etc.) to securely inject secrets without embedding them in the image.

For HTTPS authentication, set the `GIT_CREDENTIALS` environment variable:
```bash
GIT_CREDENTIALS="https://username:token@github.com
https://username:password@gitlab.com"
```

For SSH authentication, use:
```bash
SSH_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
[your private key content]
-----END RSA PRIVATE KEY-----"

SSH_KNOWN_HOSTS="github.com ssh-rsa AAAAB3NzaC1yc2E..."
```

See [.env.example](.env.example) for a complete list of supported environment variables.

### Maven Settings

If your organization **uses** the Maven build tool, provide your Maven settings via the `MAVEN_SETTINGS_XML` environment variable:

```bash
MAVEN_SETTINGS_XML='<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <servers>
    <server>
      <id>my-repo</id>
      <username>maven-user</username>
      <password>maven-password</password>
    </server>
  </servers>
  <!-- ... rest of settings.xml ... -->
</settings>'
```

If your organization uses Maven, you likely have shared configurations in a `settings.xml` file that is required to build most repositories. This file is typically located at `~/.m2/settings.xml` on developer machines. 

## Step 3: Build the Docker image

Once you've customized the `Dockerfile` as needed, you can build the image with the following command, filling in your organization's specific values for the build arguments:


### Option 1: Without connecting to the Moderne Platform

To start you can build an image that does not connect to the Moderne platform. This is useful for bootstrapping the ingestion process to start publishing the LSTs your Artifactory/Nexus repository.

Using a username and password for authentication:
```bash
docker build -t moderne-mass-ingest:latest \
    --build-arg PUBLISH_URL=<> \
    --build-arg PUBLISH_USER=<> \
    --build-arg PUBLISH_PASSWORD=<> \
    .
```

Using an API token for authentication:
```bash
docker build -t moderne-mass-ingest:latest \
    --build-arg PUBLISH_URL=<> \
    --build-arg PUBLISH_TOKEN=<>
    .
```

### Option 2: Connecting to the Moderne Platform

```bash
docker build -t moderne-mass-ingest:latest \
    --build-arg PUBLISH_URL=<> \
    --build-arg PUBLISH_USER=<> \
    --build-arg PUBLISH_PASSWORD=<> \
    --build-arg MODERNE_TENANT=<> \
    --build-arg MODERNE_TOKEN=<> \
    .
```

### Build Arguments

| Argument | Description | Required |
|---|---|---|
| `PUBLISH_URL` | The URL of the artifact repository where the LSTs will be published. | Yes |
| `PUBLISH_USER` | The username for the artifact repository. | Yes |
| `PUBLISH_PASSWORD` | The password for the artifact repository. | Yes |
| `MODERNE_TENANT` | The URL of the Moderne tenant. | No |
| `MODERNE_DX_HOST` | The URL of the Moderne DX application. | No |
| `MODERNE_TOKEN` | The token for the Moderne tenant. | No |
| `MODERNE_CLI_VERSION` | The version of the Moderne CLI to use. Will download the latest from Maven Central if not defined.| No |
| `TRUSTED_CERTIFICATES_PATH` | The path to the cacerts file that contains the self-signed certificates. | No |


## Step 4: Deploy and run the image

Now that you have a Docker image built, you will need to deploy it to the container management platform of your choice and have it run on a schedule. 

### Running with Environment Variables

When deploying the container, you can provide credentials via environment variables instead of embedding them in the image. This is the recommended approach for production deployments.

#### Using Docker Run

```bash
docker run -it --rm \
    -p 3000:3000 -p 8080:8080 -p 9090:9090 \
    --env-file .env \
    -v $(pwd)/data:/var/moderne \
    -v $(pwd)/repos.csv:/app/repos.csv:ro \
    moderne-mass-ingest:latest
```

#### Using Docker Compose

See [docker-compose.env.yml](docker-compose.env.yml) for an example configuration using environment variables.

```bash
# Copy and customize the environment file
cp .env.example .env
# Edit .env with your credentials

# Run with docker-compose
docker-compose -f docker-compose.env.yml up
```

#### Supported Environment Variables

See [.env.example](.env.example) for a complete list of supported environment variables, including:
- `GIT_CREDENTIALS` - Git HTTPS credentials
- `SSH_PRIVATE_KEY` - SSH private key for Git access
- `MAVEN_SETTINGS_XML` - Complete Maven settings.xml content
- `GRADLE_PROPERTIES` - Gradle properties
- `CUSTOM_CA_CERT` - Custom CA certificate for self-signed certs
- And many more...

### Resource Requirements

**At a minimum**, we recommend that you run this image on a system with at least 2 CPU cores, 16 GB of memory, and 32 GB of disk space. Depending on your repo sizes and desired mass ingest cycle time, you may choose to increase these specs.

For example, if you have 1000+ repositories, we recommend using 64-128 GB of storage space.

It's your responsibility to monitor this and adjust as needed. See the [next step](#step-5-monitor-the-ingestion-process) for monitoring instructions.

> [!NOTE]
> We recommend attaching a volume mount to the container at `/var/moderne` to ensure that cloned repositories are stored outside of the guest. 


## Step 5: Monitor the ingestion process

By default, the example Docker image will run the `mod monitor` command that will create a scrape target that can be consumed by Prometheus.

You can scrape the metrics from the `/prometheus` endpoint.

The example Docker image provided in this repo will also run a Prometheus server that will scrape the scrape target. You can access the Prometheus server at `http://localhost:9090` and the Grafana server at `http://localhost:3000`. The default username and password for Grafana is `admin` and `admin`.

## Step 6: Troubleshooting

If you want to verify that the image works as expected locally, you can spin it up with the following command:
```bash
docker run -it --rm \
    -p 3000:3000 \
    -p 8080:8080 \
    -p 9090:9090 \
    --env-file .env \
    moderne-mass-ingest:latest 
```

In case you wish to debug the image, you can suffix the above with `bash`, and from there run `./publish.sh` to see the ingestion process in action.
