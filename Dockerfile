FROM eclipse-temurin:8-jammy AS jdk8
FROM eclipse-temurin:11-jammy AS jdk11
FROM eclipse-temurin:17-jammy AS jdk17
FROM eclipse-temurin:21-jammy AS jdk21
# FROM eclipse-temurin:23-jammy AS jdk23

# Import Grafana and Prometheus
# Comment out the following lines if you don't need Grafana and Prometheus
FROM grafana/grafana AS grafana
FROM prom/prometheus AS prometheus

# Install dependencies for `mod` cli
FROM jdk21 AS dependencies
RUN apt-get -y update && apt-get install -y git git-lfs jq libxml2-utils unzip zip supervisor && git lfs install 

# Gather various JDK versions
COPY --from=jdk8 /opt/java/openjdk /usr/lib/jvm/temurin-8-jdk
COPY --from=jdk11 /opt/java/openjdk /usr/lib/jvm/temurin-11-jdk
COPY --from=jdk17 /opt/java/openjdk /usr/lib/jvm/temurin-17-jdk
COPY --from=jdk21 /opt/java/openjdk /usr/lib/jvm/temurin-21-jdk
# COPY --from=jdk23 /opt/java/openjdk /usr/lib/jvm/temurin-23-jdk

# Import Grafana and Prometheus into mass-ingest image
# Comment out the following lines if you don't need Grafana and Prometheus
COPY --from=grafana /usr/share/grafana /usr/share/grafana
COPY --from=grafana /etc/grafana /etc/grafana
COPY --from=prometheus /bin/prometheus /bin/prometheus
COPY --from=prometheus /etc/prometheus /etc/prometheus

# Copy configs for prometheus and grafana
# Comment out the following lines if you don't need Grafana and Prometheus
COPY observability/ /etc/.
# COPY grafana-datasource.yml /etc/grafana/provisioning/datasources/grafana-datasource.yml
# COPY grafana-dashboard.yml /etc/grafana/provisioning/dashboards/grafana-dashboard.yml
# COPY grafana-build-dashboard.json /etc/grafana/dashboards/build.json
# COPY grafana-run-dashboard.json /etc/grafana/dashboards/run.json
# COPY prometheus.yml /etc/prometheus/prometheus.yml

FROM dependencies AS modcli
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

# Set the environment variable MODERNE_CLI_VERSION
# ENV MODERNE_CLI_VERSION=3.25.0

# Download the specified version of moderne-cli JAR file if MODERNE_CLI_VERSION is provided,
# otherwise download the latest version
RUN if [ -n "${MODERNE_CLI_VERSION}" ]; then \
        echo "Downloading version: ${MODERNE_CLI_VERSION}"; \
        curl -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/${MODERNE_CLI_VERSION}/moderne-cli-${MODERNE_CLI_VERSION}.jar" --output mod.jar; \
    else \
        LATEST_VERSION=$(curl -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/maven-metadata.xml" | xmllint --xpath 'string(/metadata/versioning/latest)' -); \
        if [ -z "${LATEST_VERSION}" ]; then \
            echo "Failed to get latest version"; \
            exit 1; \
        fi; \
        echo "Downloading latest version: ${LATEST_VERSION}"; \
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
    else \
        echo "MODERNE_TOKEN not supplied, skipping configuration."; \
    fi

# Note, artifact repositories such as GitLab's Maven API will accept an access token's name and the
# access token for PUBLISH_USER and PUBLISH_PASSWORD respectively.
RUN if [ -n "${PUBLISH_URL}" ] && [ -n "${PUBLISH_USER}" ] && [ -n "${PUBLISH_PASSWORD}" ]; then \
        mod config lsts artifacts maven edit ${PUBLISH_URL} --user ${PUBLISH_USER} --password ${PUBLISH_PASSWORD}; \
    elif [ -n "${PUBLISH_URL}" ] && [ -n "${PUBLISH_TOKEN}" ]; then \
        mod config lsts artifacts maven edit ${PUBLISH_URL} --jfrog-api-token ${PUBLISH_TOKEN}; \
    else \
        echo "PUBLISH_URL and either PUBLISH_USER and PUBLISH_PASSWORD or PUBLISH_TOKEN must be supplied."; \
    fi


FROM modcli AS language-support
# Gradle support
# RUN wget https://services.gradle.org/distributions/gradle-8.10-bin.zip
# RUN mkdir /opt/gradle
# RUN unzip -d /opt/gradle gradle-8.10-bin.zip

# Maven support
# RUN wget https://dlcdn.apache.org/maven/maven-3/3.9.8/binaries/apache-maven-3.9.8-bin.zip && unzip apache-maven-3.9.8-bin.zip
# RUN mv apache-maven-3.9.8 /opt/apache-maven-3.9.8
# RUN ln -s /opt/apache-maven-3.9.8/bin/mvn /usr/local/bin/mvn

# Install a Maven wrapper external to projects
# RUN /opt/apache-maven-3.9.8/bin/mvn -N wrapper:wrapper
# RUN mkdir -p /opt/maven-wrapper/bin
# RUN mv mvnw mvnw.cmd .mvn /opt/maven-wrapper/bin/
# ENV PATH="${PATH}:/opt/maven-wrapper/bin"


# UNCOMMENT for Android support
# RUN wget https://dl.google.com/android/repository/commandlinetools-linux-8512546_latest.zip
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
# RUN wget https://github.com/bazelbuild/bazelisk/releases/download/v1.20.0/bazelisk-linux-amd64
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
    
# # Remove Python 3.10
# RUN apt-get remove -y python3.10 python3.10-minimal

# # Install Python 3.12 and pip
# RUN apt-get install -y \
#     python3.12 \
#     python3.12-venv \
#     python3.12-dev \
#     python3.12-distutils \
#     && apt-get -y autoremove \
#     && apt-get clean

# # Set Python 3.12 as the default
# RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1

# # Install pip for Python 3.12 using the bundled `ensurepip` and upgrade it
# RUN python3.12 -m ensurepip --upgrade

# # Update pip to the latest version for the installed Python 3.12
# RUN python3.12 -m pip install --upgrade pip

# RUN python3.12 -m pip install more-itertools cbor2

# UNCOMMENT for .NET
# RUN apt-get install -y dotnet-sdk-6.0
# RUN apt-get install -y dotnet-sdk-8.0
# RUN mod config build dotnet timeout edit PT5M


# UNCOMMENT for custom Maven settings
# Configure Maven Settings if they are required to build
# COPY maven/settings.xml /root/.m2/settings.xml
# RUN mod config build maven settings edit /root/.m2/settings.xml

# Install Maven if some projects do not use the wrapper
#RUN wget https://dlcdn.apache.org/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.zip && unzip apache-maven-3.9.9-bin.zip
#RUN mv apache-maven-3.9.9 /opt/apache-maven-3.9.9
#RUN ln -s /opt/apache-maven-3.9.9/bin/mvn /usr/local/bin/mvn

FROM language-support AS runner

# UNCOMMENT for authentication to git repositories
# Configure git credentials if they are required to clone; ensure this lines up with your use of https:// or ssh://
# .git-credentials each line defines credentilas for a host in the format: https://<username>:<password>@host or
# https://<token-name>:<token>@host
# COPY .git-credentials /root/.git-credentials
# RUN git config --global credential.helper store --file=/root/.git-credentials
# RUN git config --global http.sslVerify false

# Configure trust store if self-signed certificates are in use for artifact repository, source control, or moderne tenant
# Path to the trusted certificates file, which will replace the cacerts file in the configured JDKs if necessary
# ARG TRUSTED_CERTIFICATES_PATH
# COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-8-jdk/jre/lib/security/cacerts
# COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-11-jdk/lib/security/cacerts
# COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts
# COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-21-jdk/lib/security/cacerts
# COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-23-jdk/lib/security/cacerts
# RUN mod config http trust-store edit java-home


# OPTIONAL - Customize JVM options
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

COPY --chmod=755 publish.sh publish.sh

# Optional: mount from host
COPY repos.csv repos.csv

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
