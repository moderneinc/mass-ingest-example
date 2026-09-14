# Customizing the image

The [Dockerfile](../Dockerfile) is mostly a list of toolchains, each copied from its official image in a `FROM ... AS` stage. If your repositories never need one of them, delete its stage and its `COPY --from` lines; nothing else in the image refers to them.

## The CLI version

The image holds the `modw` wrapper rather than the CLI. Each container asks for the newest CLI release when it starts, so a run always has the latest fixes. It also means a new release rebuilds every repository once, because a `repos-lock.csv` row is only skipped when the same CLI version published it. To decide for yourself when that happens, pin the version in the Job's `env`:

```yaml
- name: MODERNE_WRAPPER_VERSION
  value: "4.8.3"
```

## Air-gapped installations

A Moderne DX installation without internet access can't let `modw` fetch the CLI when a container starts, so the image has to carry the CLI with it. Mirror the `io.moderne` artifacts from the [Code Genome Project](https://artifacts.codegenomeproject.org/maven) into your repository manager, then replace the Dockerfile's `curl https://app.moderne.io/cli` line with an install from that mirror at a pinned version:

```dockerfile
ARG MODERNE_CLI_VERSION
ARG MODERNE_MIRROR=https://repo.example.com/artifactory/moderne
ENV MODERNE_WRAPPER_VERSION=$MODERNE_CLI_VERSION \
    MODERNE_WRAPPER_DISTRIBUTION_URL=$MODERNE_MIRROR/io/moderne/moderne-cli-linux-x64/$MODERNE_CLI_VERSION/moderne-cli-linux-x64-$MODERNE_CLI_VERSION.sh
RUN mkdir -p /home/moderne/.moderne/cli/bin && \
    curl -fsSL -o /home/moderne/.moderne/cli/bin/modw \
      "$MODERNE_MIRROR/io/moderne/moderne-cli/$MODERNE_CLI_VERSION/moderne-cli-$MODERNE_CLI_VERSION-modw.sh" && \
    chmod +x /home/moderne/.moderne/cli/bin/modw && \
    ln -s modw /home/moderne/.moderne/cli/bin/mod && \
    mod --version
```

Build it with `--build-arg MODERNE_CLI_VERSION=<version>`. The `mod --version` at the end makes the wrapper download that version into the image, and because a container starts with the same version already installed, it never looks for a newer one. If the mirror requires credentials, `modw` reads them from `MODERNE_WRAPPER_DISTRIBUTION_USERNAME` and `MODERNE_WRAPPER_DISTRIBUTION_PASSWORD`, or `MODERNE_WRAPPER_DISTRIBUTION_TOKEN`.

The CLI is only the first download. The base images come from Docker Hub, Microsoft and GitHub's registry, the Android SDK from Google and Bazelisk from GitHub, so each of those `FROM` and `curl` lines needs to point at your own registry or mirror too. The builds themselves resolve dependencies at run time, which the next section covers.

## Private package registries

Builds resolve dependencies the way each tool normally would, so pointing them at an internal repository manager means giving each tool its usual configuration file. Keep credentials out of those files by having them read environment variables, and put the variables in a secret the Job passes to the container.

Maven already reads [`maven/settings.xml`](../maven/settings.xml), which has a commented mirror that takes its username and password from `${env.MAVEN_MIRROR_USERNAME}` and `${env.MAVEN_MIRROR_PASSWORD}`. Gradle reads init scripts from `~/.gradle/init.d/`, and any environment variable named `ORG_GRADLE_PROJECT_<name>` becomes the project property `<name>`, which is how most build files expect repository credentials. npm, yarn and pnpm read `~/.npmrc`, which can refer to `${NPM_TOKEN}`. Python needs no file at all, since pip reads `PIP_INDEX_URL` and uv reads `UV_DEFAULT_INDEX`. NuGet reads `~/.nuget/NuGet/NuGet.Config`, where `%NAME%` in `<packageSourceCredentials>` expands an environment variable.

Copy any of those files in next to the `maven/settings.xml` line, after `USER moderne`, so they belong to the user the builds run as:

```dockerfile
COPY --chown=moderne npm/.npmrc /home/moderne/.npmrc
```

## Self-signed certificates

A repository manager or Git host with a certificate from your own certificate authority has to be trusted in several places, because git and Python use the system store, the CLI, Maven and Gradle use each JDK's `cacerts`, and Node.js uses neither. Put the `.crt` files in a `certs/` directory and add this above `USER moderne`, where the image still builds as root:

```dockerfile
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates && \
    for store in $(find /opt/java/openjdk /usr/lib/jvm -name cacerts); do \
      for cert in /usr/local/share/ca-certificates/*.crt; do \
        keytool -importcert -noprompt -storepass changeit -alias "$(basename "$cert")" -file "$cert" -keystore "$store"; \
      done; \
    done
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
```

`mod doctor` reports which trust store the CLI loaded, and fails if it can't load it.
