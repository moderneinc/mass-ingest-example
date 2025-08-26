FROM eclipse-temurin:8-jammy AS jdk8
FROM eclipse-temurin:11-jammy AS jdk11
FROM eclipse-temurin:17-jammy AS jdk17
FROM eclipse-temurin:21-jammy AS jdk21
# FROM eclipse-temurin:22-jammy AS jdk22

# Import Grafana and Prometheus
FROM grafana/grafana AS grafana
FROM prom/prometheus AS prometheus

# Install dependencies for `mod` cli
FROM jdk21 AS dependencies
RUN apt-get -y update && apt-get install -y git git-lfs jq libxml2-utils unzip zip supervisor vim && git lfs install

# Gather various JDK versions
COPY --from=jdk8 /opt/java/openjdk /usr/lib/jvm/temurin-8-jdk
COPY --from=jdk11 /opt/java/openjdk /usr/lib/jvm/temurin-11-jdk
COPY --from=jdk17 /opt/java/openjdk /usr/lib/jvm/temurin-17-jdk
COPY --from=jdk21 /opt/java/openjdk /usr/lib/jvm/temurin-21-jdk
# COPY --from=jdk22 /opt/java/openjdk /usr/lib/jvm/temurin-22-jdk

# Import Grafana and Prometheus into mass-ingest image
COPY --from=grafana /usr/share/grafana /usr/share/grafana
COPY --from=grafana /etc/grafana /etc/grafana
COPY --from=prometheus /bin/prometheus /bin/prometheus
COPY --from=prometheus /etc/prometheus /etc/prometheus

# Copy configs for prometheus and grafana
COPY observability/ /etc/.

FROM dependencies AS modcli
ARG MODERNE_CLI_STAGE=stable
ARG MODERNE_CLI_VERSION
ARG MODERNE_TENANT
ARG MODERNE_DX_HOST
# Personal access token for Moderne; can be created through https://<tenant>.moderne.io/settings/access-token
ARG MODERNE_TOKEN

# We recommend a dedicated Artifactory Maven repository, allowing both releases & snapshots; supply the full URL here
ARG PUBLISH_URL
ARG PUBLISH_USER
ARG PUBLISH_PASSWORD
ARG PUBLISH_TOKEN

# Moderne CLI installation
# Set the working directory to /usr/local/bin
WORKDIR /usr/local/bin

# Download the specified version of moderne-cli JAR file if MODERNE_CLI_VERSION is provided,
# otherwise download the latest version
RUN if [ -n "${MODERNE_CLI_VERSION}" ]; then \
        echo "Downloading version: ${MODERNE_CLI_VERSION}"; \
        curl -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/${MODERNE_CLI_VERSION}/moderne-cli-${MODERNE_CLI_VERSION}.jar" --output mod.jar; \
    elif [ "${MODERNE_CLI_STAGE}" == "staging" ]; then \
        LATEST_VERSION=$(curl -s --insecure --request GET --url "https://api.github.com/repos/moderneinc/moderne-cli-releases/releases" | jq '.[0].tag_name' -r | sed "s/^v//"); \
        if [ -z "${LATEST_VERSION}" ]; then \
            echo "Failed to get latest staging version"; \
            exit 1; \
        fi; \
        echo "Downloading latest staging version: ${LATEST_VERSION}"; \
        curl -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/${LATEST_VERSION}/moderne-cli-${LATEST_VERESION}.jar" --output mod.jar; \
    else \
        LATEST_VERSION=$(curl -s --insecure --request GET --url "https://api.github.com/repos/moderneinc/moderne-cli-releases/releases/latest" | jq '.tag_name' -r | sed "s/^v//"); \
        if [ -z "${LATEST_VERSION}" ]; then \
            echo "Failed to get latest stable version"; \
            exit 1; \
        fi; \
        echo "Downloading latest stable version: ${LATEST_VERSION}"; \
        curl -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/${LATEST_VERSION}/moderne-cli-${LATEST_VERSION}.jar" --output mod.jar; \
    fi

# Create a shell script 'mod' that runs the moderne-cli JAR file
RUN echo '#!/bin/sh' > mod && \
    echo 'java -jar /usr/local/bin/mod.jar "$@"' >> mod

# Make the 'mod' script executable
RUN chmod +x mod

WORKDIR /app

RUN if [ -n "${MODERNE_TOKEN}" ]; then \
        mod config moderne edit --token=${MODERNE_TOKEN} https://${MODERNE_TENANT}.moderne.io; \
        mod config scm moderne sync; \
    else \
        echo "MODERNE_TOKEN not supplied, skipping configuration."; \
    fi

# Note, artifact repositories such as GitLab's Maven API will accept an access token's name and the
# access token for PUBLISH_USER and PUBLISH_PASSWORD respectively.
RUN if [ -n "${PUBLISH_URL}" ] && [ -n "${PUBLISH_USER}" ] && [ -n "${PUBLISH_PASSWORD}" ]; then \
        mod config lsts artifacts maven edit ${PUBLISH_URL} --user ${PUBLISH_USER} --password ${PUBLISH_PASSWORD}; \
    elif [ -n "${PUBLISH_URL}" ] && [ -n "${PUBLISH_TOKEN}" ]; then \
        mod config lsts artifacts artifactory edit ${PUBLISH_URL} --jfrog-api-token ${PUBLISH_TOKEN}; \
    else \
        echo "PUBLISH_URL and either PUBLISH_USER and PUBLISH_PASSWORD or PUBLISH_TOKEN must be supplied."; \
    fi


FROM modcli AS language-support
# Gradle support
# RUN wget --no-check-certificate https://services.gradle.org/distributions/gradle-8.14-bin.zip
# RUN mkdir /opt/gradle
# RUN unzip -d /opt/gradle gradle-8.14-bin.zip
# ENV PATH="${PATH}:/opt/gradle/gradle-8.14/bin"

# Install Maven if some projects do not use the wrapper
# ENV MAVEN_VERSION=3.9.10
# RUN wget --no-check-certificate https://repo1.maven.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz && tar xzvf apache-maven-${MAVEN_VERSION}-bin.tar.gz && rm apache-maven-${MAVEN_VERSION}-bin.tar.gz
# RUN mv apache-maven-${MAVEN_VERSION} /opt/apache-maven-${MAVEN_VERSION}
# RUN ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn

# Install a Maven wrapper external to projects
# RUN /usr/local/bin/mvn -N wrapper:wrapper
# RUN mkdir -p /opt/maven-wrapper/bin
# RUN mv mvnw mvnw.cmd .mvn /opt/maven-wrapper/bin/
# ENV PATH="${PATH}:/opt/maven-wrapper/bin"

# UNCOMMENT for Android support
# RUN wget --no-check-certificate https://dl.google.com/android/repository/commandlinetools-linux-8512546_latest.zip
# RUN unzip commandlinetools-linux-8512546_latest.zip
# RUN mkdir -p /usr/lib/android-sdk/cmdline-tools/latest/
# RUN cp -R cmdline-tools/* /usr/lib/android-sdk/cmdline-tools/latest/
# RUN yes | /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager --licenses
# RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-33"
# RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-32"
# RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-31"
# RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-30"
# RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-29"
# RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-28"
# RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-27"
# RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-26"
# RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-25"
# ENV ANDROID_HOME=/usr/lib/android-sdk/cmdline-tools/latest
# ENV ANDROID_SDK_ROOT=${ANDROID_HOME}

# UNCOMMENT for Bazel support
# RUN wget --no-check-certificate https://github.com/bazelbuild/bazelisk/releases/download/v1.20.0/bazelisk-linux-amd64
# RUN cp bazelisk-linux-amd64 /usr/local/bin/bazel
# RUN chmod +x /usr/local/bin/bazel

# UNCOMMENT for Node support
# RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
#     apt-get install -y --no-install-recommends nodejs

# UNCOMMENT for Python support
# Install prerequisites and COPY the deadsnakes PPA
# RUN apt-get update && apt-get install -y \
#     software-properties-common \
#     && add-apt-repository ppa:deadsnakes/ppa \
#     && apt-get update
    
# # Install Python 3.11 and pip
# RUN apt-get install -y \
#     python3.11 \
#     python3.11-venv \
#     python3.11-dev \
#     python3.11-distutils \
#     && apt-get -y autoremove \
#     && apt-get clean

# # Set Python 3.11 as the default
# RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 && \
#    update-alternatives --config python3

# # Install pip for Python 3.11 using the bundled `ensurepip` and upgrade it
# RUN python3.11 -m ensurepip --upgrade

# # Update pip to the latest version for the installed Python 3.11
# RUN python3.11 -m pip install --upgrade pip

# RUN python3.11 -m pip install more-itertools cbor2

# UNCOMMENT for .NET
# RUN apt-get install -y dotnet-sdk-6.0
# RUN apt-get install -y dotnet-sdk-8.0

FROM language-support AS runner

# ==============================================================================
# CREDENTIAL CONFIGURATION 
# Credentials are configured at container startup using environment variables.
# This ensures secrets are not embedded in the image and can be securely managed
# by your container orchestration platform (Kubernetes, Docker Swarm, etc.).
# ==============================================================================

# Supported environment variables (see init-credentials.sh and .env.example):
# - GIT_CREDENTIALS: Git credentials in format "https://user:token@host" (one per line)
# - SSH_PRIVATE_KEY: SSH private key content
# - SSH_KNOWN_HOSTS: SSH known hosts content  
# - MAVEN_SETTINGS_XML: Complete Maven settings.xml content
# - MAVEN_SETTINGS_SECURITY_XML: Maven settings security for encrypted passwords
# - GRADLE_PROPERTIES: Gradle properties content
# - CUSTOM_CA_CERT: Custom CA certificate content
# - NPM_REGISTRY & NPM_AUTH_TOKEN: NPM configuration
# - PIP_INDEX_URL & PIP_TRUSTED_HOST: Python pip configuration

# Credentials are injected at runtime via the init-credentials.sh script

# Customize JVM options
RUN mod config java options edit "-Xmx4g -Xss3m"

# Available ports
# 8080 - mod CLI monitor
# 3000 - Grafana
# 9090 - Prometheus
EXPOSE 8080 3000 9090
COPY supervisord.conf /etc/supervisord.conf

WORKDIR /app
# Set as environment variables for `publish.sh`
ENV PUBLISH_URL=${PUBLISH_URL}
ENV PUBLISH_USER=${PUBLISH_USER}
ENV PUBLISH_PASSWORD=${PUBLISH_PASSWORD}
ENV PUBLISH_TOKEN=${PUBLISH_TOKEN}

# Disables extra formating in the logs
ENV CUSTOM_CI=true

# Set the data directory for the publish script
ENV DATA_DIR=/var/moderne

# Copy initialization and execution scripts
COPY --chmod=755 init-credentials.sh init-credentials.sh
COPY --chmod=755 publish.sh publish.sh

COPY repos.csv repos.csv

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]