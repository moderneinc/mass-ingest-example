# The toolchains the CLI builds repositories with. Nothing run-specific lives here:
# the store, the tenant and the shard are environment the Job sets.
FROM eclipse-temurin:8-noble AS jdk8
FROM eclipse-temurin:11-noble AS jdk11
FROM eclipse-temurin:17-noble AS jdk17
FROM eclipse-temurin:21-noble AS jdk21
FROM gradle:8.14.4-jdk21-noble AS gradle
FROM maven:3.9-eclipse-temurin-25-noble AS maven
FROM node:22-bookworm AS node
FROM golang:1.25-bookworm AS go
FROM ghcr.io/astral-sh/uv:latest AS uv
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS dotnet8
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS dotnet9
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS dotnet10

# The CLI runs on this JDK.
FROM eclipse-temurin:25-noble
RUN apt-get update && apt-get install -y curl git unzip

# JVM
COPY --from=jdk8 /opt/java/openjdk /usr/lib/jvm/temurin-8-jdk
COPY --from=jdk11 /opt/java/openjdk /usr/lib/jvm/temurin-11-jdk
COPY --from=jdk17 /opt/java/openjdk /usr/lib/jvm/temurin-17-jdk
COPY --from=jdk21 /opt/java/openjdk /usr/lib/jvm/temurin-21-jdk
COPY --from=gradle /opt/gradle /opt/gradle
COPY --from=maven /usr/share/maven /usr/share/maven
# For builds that run bare gradle or mvn rather than a wrapper.
ENV GRADLE_HOME=/opt/gradle MAVEN_HOME=/usr/share/maven
ENV PATH=$GRADLE_HOME/bin:$MAVEN_HOME/bin:$PATH

# Android
ENV ANDROID_HOME=/opt/android-sdk
RUN curl -fsSL -o /tmp/cmdline-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-12700392_latest.zip && \
    unzip -q /tmp/cmdline-tools.zip -d /tmp && \
    yes | /tmp/cmdline-tools/bin/sdkmanager --sdk_root=$ANDROID_HOME --licenses > /dev/null && \
    /tmp/cmdline-tools/bin/sdkmanager --sdk_root=$ANDROID_HOME "cmdline-tools;latest" $(seq -f 'platforms;android-%g' 25 35) && \
    rm -rf /tmp/cmdline-tools /tmp/cmdline-tools.zip

# Bazel
RUN curl -fsSL -o /usr/local/bin/bazel https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64 && \
    chmod +x /usr/local/bin/bazel

# JavaScript. The copied yarn symlinks dangle; corepack provides yarn instead.
COPY --from=node /usr/local /opt/node
ENV PATH=/opt/node/bin:$PATH
RUN rm -f /opt/node/bin/yarn /opt/node/bin/yarnpkg && corepack enable

# Python. Noble's interpreter ships without venv and pip; node-gyp wants `python`.
RUN apt-get update && apt-get install -y \
    python3 python3-venv python3-dev python3-pip python3-setuptools python-is-python3
COPY --from=uv /uv /usr/local/bin/uv

# .NET
COPY --from=dotnet8 /usr/share/dotnet /usr/share/dotnet
COPY --from=dotnet9 /usr/share/dotnet /usr/share/dotnet
COPY --from=dotnet10 /usr/share/dotnet /usr/share/dotnet
ENV DOTNET_ROOT=/usr/share/dotnet PATH=/usr/share/dotnet:$PATH

# Go
COPY --from=go /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH

# UID 1000, which noble gives to `ubuntu`. AGP writes missing platforms back to the SDK.
RUN userdel -r ubuntu 2>/dev/null; \
    useradd --uid 1000 --create-home moderne && \
    install -d -o moderne /var/moderne && \
    chown -R moderne /opt/android-sdk
USER moderne
ENV HOME=/home/moderne

# Installs the modw wrapper. The CLI version it downloads when a container starts is set by
# the MODERNE_WRAPPER_VERSION environment variable in that container. If you don't set it,
# it defaults to the latest version.
RUN curl -fsSL https://app.moderne.io/cli | bash
ENV PATH=/home/moderne/.moderne/cli/bin:$PATH

COPY --chown=moderne cli/moderne.yml /home/moderne/.moderne/cli/moderne.yml
COPY --chown=moderne maven/settings.xml /home/moderne/.m2/settings.xml

WORKDIR /var/moderne

CMD ["mod", "publish", "/var/moderne/ws", "--sync-csv"]
