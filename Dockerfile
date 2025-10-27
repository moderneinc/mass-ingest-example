################################################################################
# CORE SETUP (Required for all stages)
################################################################################

FROM eclipse-temurin:8-jdk AS jdk8
FROM eclipse-temurin:11-jdk AS jdk11
FROM eclipse-temurin:17-jdk AS jdk17
FROM eclipse-temurin:21-jdk AS jdk21
FROM eclipse-temurin:25-jdk AS jdk25

# UNCOMMENT if you use a custom maven image with settings
# FROM <custom docker image> AS maven

# Install dependencies for `mod` cli
FROM jdk25 AS dependencies
RUN apt-get -y update && apt-get install -y curl git git-lfs jq libxml2-utils unzip wget zip vim && git lfs install

# Gather various JDK versions
COPY --from=jdk8 /opt/java/openjdk /usr/lib/jvm/temurin-8-jdk
COPY --from=jdk11 /opt/java/openjdk /usr/lib/jvm/temurin-11-jdk
COPY --from=jdk17 /opt/java/openjdk /usr/lib/jvm/temurin-17-jdk
COPY --from=jdk21 /opt/java/openjdk /usr/lib/jvm/temurin-21-jdk
COPY --from=jdk25 /opt/java/openjdk /usr/lib/jvm/temurin-25-jdk

################################################################################
# MODERNE CLI SETUP
################################################################################

FROM dependencies AS modcli
ARG MODERNE_CLI_STAGE=stable
ARG MODERNE_CLI_VERSION
# Set the environment variable MODERNE_CLI_VERSION
ENV MODERNE_CLI_VERSION=${MODERNE_CLI_VERSION}

WORKDIR /app

# Download the specified version of moderne-cli JAR file if MODERNE_CLI_VERSION is provided,
# otherwise download the latest version
RUN if [ -n "${MODERNE_CLI_VERSION}" ]; then \
        echo "Downloading version: ${MODERNE_CLI_VERSION}"; \
        curl -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/${MODERNE_CLI_VERSION}/moderne-cli-${MODERNE_CLI_VERSION}.jar" --output /usr/local/bin/mod.jar; \
    elif [ "${MODERNE_CLI_STAGE}" == "staging" ]; then \
        LATEST_VERSION=$(curl -s --insecure --request GET --url "https://api.github.com/repos/moderneinc/moderne-cli-releases/releases" | jq '.[0].tag_name' -r | sed "s/^v//"); \
        if [ -z "${LATEST_VERSION}" ]; then \
            echo "Failed to get latest staging version"; \
            exit 1; \
        fi; \
        echo "Downloading latest staging version: ${LATEST_VERSION}"; \
        curl -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/${LATEST_VERSION}/moderne-cli-${LATEST_VERSION}.jar" --output /usr/local/bin/mod.jar; \
    else \
        LATEST_VERSION=$(curl -s --insecure --request GET --url "https://api.github.com/repos/moderneinc/moderne-cli-releases/releases/latest" | jq '.tag_name' -r | sed "s/^v//"); \
        if [ -z "${LATEST_VERSION}" ]; then \
            echo "Failed to get latest stable version"; \
            exit 1; \
        fi; \
        echo "Downloading latest stable version: ${LATEST_VERSION}"; \
        curl -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/${LATEST_VERSION}/moderne-cli-${LATEST_VERSION}.jar" --output /usr/local/bin/mod.jar; \
    fi

# Create a shell script 'mod' that runs the moderne-cli JAR file
RUN echo -e '#!/bin/sh\njava -jar /usr/local/bin/mod.jar "$@"' > /usr/local/bin/mod

# Make the 'mod' script executable
RUN chmod +x /usr/local/bin/mod

# Credential configuration has been moved to runtime (publish.sh/publish.ps1) to avoid
# baking sensitive credentials into Docker image layers. Credentials are now passed as
# environment variables and configured when the container starts.

################################################################################
# OPTIONAL: Language Support (uncomment as needed)
################################################################################
# Most projects use Maven/Gradle wrappers and don't need these installations.
# Uncomment only if your repositories specifically require them.

FROM modcli AS language-support

# Gradle (uncomment if projects don't use Gradle wrapper)
# RUN wget --no-check-certificate https://services.gradle.org/distributions/gradle-8.14-bin.zip
# RUN mkdir /opt/gradle
# RUN unzip -d /opt/gradle gradle-8.14-bin.zip
# ENV PATH="${PATH}:/opt/gradle/gradle-8.14/bin"

# Maven (uncomment if projects don't use Maven wrapper)
# NOTE: This version may be out of date as new versions are continually released. Check here for the latest version: https://repo1.maven.org/maven2/org/apache/maven/apache-maven/
# ENV MAVEN_VERSION=3.9.11
# RUN wget --no-check-certificate https://repo1.maven.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz && tar xzvf apache-maven-${MAVEN_VERSION}-bin.tar.gz && rm apache-maven-${MAVEN_VERSION}-bin.tar.gz
# RUN mv apache-maven-${MAVEN_VERSION} /opt/apache-maven-${MAVEN_VERSION}
# RUN ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn

# Maven wrapper external to projects (uncomment if needed)
# RUN /usr/local/bin/mvn -N wrapper:wrapper
# RUN mkdir -p /opt/maven-wrapper/bin
# RUN mv mvnw mvnw.cmd .mvn /opt/maven-wrapper/bin/
# ENV PATH="${PATH}:/opt/maven-wrapper/bin"

# Android SDK (uncomment for Android projects)
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

# Bazel (uncomment for Bazel projects)
# RUN wget --no-check-certificate https://github.com/bazelbuild/bazelisk/releases/download/v1.20.0/bazelisk-linux-amd64
# RUN cp bazelisk-linux-amd64 /usr/local/bin/bazel
# RUN chmod +x /usr/local/bin/bazel

# Node.js (uncomment for JavaScript/TypeScript projects)
# RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
#     apt-get install -y --no-install-recommends nodejs

# Python 3.11 (uncomment for Python projects)
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

# .NET SDK (uncomment for .NET projects)
# RUN apt-get install -y dotnet-sdk-6.0
# RUN apt-get install -y dotnet-sdk-8.0

################################################################################
# OPTIONAL: Custom Maven Settings (uncomment if needed)
################################################################################
# Most projects don't need custom Maven settings. Only uncomment if your
# projects require specific Maven configuration.

# Configure Maven Settings if they are required to build (choose betwween a settings file withing this repo or the docker image variant):
# COPY maven/settings.xml /root/.m2/settings.xml
# RUN cp $MAVEN_CONFIG/settings.xml /root/.m2/settings.xml # For custom maven docker imagee
# COPY maven/settings-security.xml /root/.m2/settings-security.xml
# RUN mod config build maven settings edit /root/.m2/settings.xml

################################################################################
# RUNTIME CONFIGURATION
################################################################################

FROM language-support AS runner

# Git authentication configuration
# Git credentials are configured at runtime via volume mounts to avoid baking secrets into the image.
# Configure git to use the credential store that will be mounted at runtime
RUN git config --global credential.helper "store --file=/root/.git-credentials"
# Optionally disable SSL verification if needed
# RUN git config --global http.sslVerify false

# Mount git credentials at runtime with:
# docker run -v $(pwd)/.git-credentials:/root/.git-credentials:ro ...
#
# .git-credentials format (one line per host):
# https://<username>:<password>@github.com
# https://<token-name>:<token>@gitlab.com

# SSH keys for git authentication (if needed instead of https credentials)
# Mount at runtime to avoid baking secrets into the image:
# docker run -v $(pwd)/.ssh:/root/.ssh:ro ...
#
# Ensure your .ssh directory contains:
# - id_rsa (private key with 600 permissions)
# - known_hosts (with 644 permissions)

################################################################################
# OPTIONAL: Self-signed Certificates (uncomment if needed)
################################################################################
# Only needed if your artifact repository, source control, or Moderne tenant
# uses self-signed certificates.

# Configure trust store if self-signed certificates are in use for artifact repository, source control, or moderne tenant
# COPY mycert.crt /root/mycert.crt
# RUN /usr/lib/jvm/temurin-8-jdk/bin/keytool -import -file /root/mycert.crt -keystore /usr/lib/jvm/temurin-8-jdk/jre/lib/security/cacerts
# RUN /usr/lib/jvm/temurin-11-jdk/bin/keytool -import -file /root/mycert.crt -keystore /usr/lib/jvm/temurin-11-jdk/lib/security/cacerts
# RUN /usr/lib/jvm/temurin-17-jdk/bin/keytool -import -file /root/mycert.crt -keystore /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts
# RUN /usr/lib/jvm/temurin-21-jdk/bin/keytool -import -file /root/mycert.crt -keystore /usr/lib/jvm/temurin-21-jdk/lib/security/cacerts
# RUN /usr/lib/jvm/temurin-25-jdk/bin/keytool -import -file /root/mycert.crt -keystore /usr/lib/jvm/temurin-25-jdk/lib/security/cacerts
# RUN mod config http trust-store edit java-home

# mvnw scripts in maven projects may attempt to download maven-wrapper jars using wget.
# UNCOMMENT the following to set wget's CA certificate
# RUN echo "ca_certificate = /root/mycert.crt" > /root/.wgetrc

################################################################################
# OPTIONAL: 3-scalability (AWS Batch) setup
################################################################################

# AWS CLI for S3 repos.csv support (~300MB)
# Only needed if using S3 URLs for repos.csv in AWS Batch deployments.
# Also useful for 2-observability if fetching repos.csv from S3.
# HTTP/HTTPS URLs work without this. Comment out if not needed:
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install

# Chunk script for AWS Batch parallel processing
# Uncomment to include the chunk.sh script for 3-scalability:
# COPY --chmod=755 3-scalability/chunk.sh chunk.sh

################################################################################
# FINAL SETUP
################################################################################

# OPTIONAL - Customize JVM options
RUN mod config java options edit "-Xmx4g -Xss3m"

# Available ports
# 8080 - mod CLI monitor
EXPOSE 8080

# Disables extra formating in the logs
ENV CUSTOM_CI=true

# Set the data directory for the publish script
ENV DATA_DIR=/var/moderne

# Copy scripts
COPY --chmod=755 publish.sh publish.sh

# Optional: mount from host
COPY repos.csv repos.csv

CMD ["./publish.sh", "repos.csv"]
