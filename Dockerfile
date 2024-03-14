FROM eclipse-temurin:8-jammy AS jdk8
FROM eclipse-temurin:11-jammy AS jdk11
FROM eclipse-temurin:17-jammy AS jdk17
FROM eclipse-temurin:21-jammy AS jdk21

# Import Grafana and Prometheus
# Comment out the following lines if you don't need Grafana and Prometheus
FROM grafana/grafana as grafana
FROM prom/prometheus as prometheus

FROM jdk21 AS dependencies
RUN apt-get update && apt-get install -y git supervisor

COPY --from=jdk8 /opt/java/openjdk /usr/lib/jvm/temurin-8-jdk
COPY --from=jdk11 /opt/java/openjdk /usr/lib/jvm/temurin-11-jdk
COPY --from=jdk17 /opt/java/openjdk /usr/lib/jvm/temurin-17-jdk
COPY --from=jdk21 /opt/java/openjdk /usr/lib/jvm/temurin-21-jdk

# Import Grafana and Prometheus into mass-ingest image
# Comment out the following lines if you don't need Grafana and Prometheus
COPY --from=grafana /usr/share/grafana /usr/share/grafana
COPY --from=grafana /etc/grafana /etc/grafana
COPY --from=prometheus /bin/prometheus /bin/prometheus
COPY --from=prometheus /etc/prometheus /etc/prometheus

ADD grafana-datasource.yml /etc/grafana/provisioning/datasources/grafana-datasource.yml
ADD grafana-dashboard.yml /etc/grafana/provisioning/dashboards/grafana-dashboard.yml
ADD grafana-build-dashboard.json /etc/grafana/dashboards/build.json
ADD grafana-run-dashboard.json /etc/grafana/dashboards/run.json
ADD prometheus.yml /etc/prometheus/prometheus.yml

FROM dependencies AS modcli
# Path to the trusted certificates file, which will replace the cacerts file in the configured JDKs if necessary
ARG TRUSTED_CERTIFICATES_PATH
ARG MODERNE_CLI_VERSION=2.8.9
ARG MODERNE_TENANT
# Personal access token for Moderne; can be created through https://<tenant>.moderne.io/settings/access-token
ARG MODERNE_TOKEN
ARG MODERNE_HOST
# We recommend a dedicated Artifactory Maven repository, allowing both releases & snapshots; supply the full URL here
ARG PUBLISH_URL
ARG PUBLISH_USER
ARG PUBLISH_PASSWORD


# Download the CLI and create a shell script to run the CLI
WORKDIR /usr/local/bin
RUN curl --insecure --request GET --url https://repo1.maven.org/maven2/io/moderne/moderne-cli/${MODERNE_CLI_VERSION}/moderne-cli-${MODERNE_CLI_VERSION}.jar --output mod.jar
RUN echo '#!/bin/sh' > mod && \
    echo 'java -jar /usr/local/bin/mod.jar "$@"' >> mod
RUN chmod +x mod

WORKDIR /app

# Conditionally configure the CLI to connect to your Moderne instance: DX or SaaS
RUN if [ -n "${MODERNE_HOST}" ]; then \
    mod config moderne edit --token=${MODERNE_TOKEN} --api=${MODERNE_HOST} ${MODERNE_HOST}; \
    else \
    mod config moderne edit --token=${MODERNE_TOKEN} https://${MODERNE_TENANT}.moderne.io; \
    fi

# Conditionally configure the CLI to publish artifacts to your Artifactory instance if all the arguments are provided
RUN if [ -n "${PUBLISH_URL}" ] && [ -n "${PUBLISH_USER}" ] && [ -n "${PUBLISH_PASSWORD}" ]; then \
    mod config lsts artifacts artifactory edit ${PUBLISH_URL} --user ${PUBLISH_USER} --password ${PUBLISH_PASSWORD}; \
    fi

# Configure Maven Settings if they are required to build
# ADD maven/settings.xml /root/.m2/settings.xml
# RUN mod config build maven settings edit /root/.m2/settings.xml
# RUN mod config recipes

# Install Maven if some projects do not use the wrapper
# wget https://dlcdn.apache.org/maven/maven-3/3.9.6/binaries/apache-maven-3.9.6-bin.zip && unzip apache-maven-3.9.6-bin.zip
# COPY apache-maven-3.9.6 /opt/apache-maven-3.9.6
# RUN ln -s /opt/apache-maven-3.9.6/bin/mvn /usr/local/bin/mvn

# Configure git credentials if they are required to clone; ensure this lines up with your use of https:// or ssh://
# .git-credentials each line defines credentilas for a host in the format: https://username:password@host
# ADD .git-credentials /root/.git-credentials
# RUN git config --global credential.helper store --file=/root/.git-credentials
# RUN git config --global http.sslVerify false

# Configure trust store if self-signed certificates are in use for artifact repository, source control, or moderne tenant
# COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-8-jdk/jre/lib/security/cacerts
# COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-11-jdk/lib/security/cacerts
# COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts
# COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-21-jdk/lib/security/cacerts
# RUN mod config http trust-store edit java-home

FROM modcli AS runner
# We recommend a dedicated Artifactory Maven repository, allowing both releases & snapshots; supply the full URL here
ARG PUBLISH_URL
ARG PUBLISH_USER
ARG PUBLISH_PASSWORD

# Set env to make available to entrypoint
ENV PUBLISH_URL=${PUBLISH_URL}
ENV PUBLISH_USER=${PUBLISH_USER}
ENV PUBLISH_PASSWORD=${PUBLISH_PASSWORD}

ADD supervisord.conf /etc/supervisord.conf

# Uncomment for ingesting repositories
ADD docker-entrypoint-publish.sh /usr/local/bin/docker-entrypoint.sh

# Uncomment for running recipes
# ADD docker-entrypoint-recipe-runner.sh /usr/local/bin/docker-entrypoint.sh

WORKDIR /app
ADD repos.csv ./repos.csv

# Expose the ports for Grafana, Prometheus, and the `mod monitor`
EXPOSE 3000 9090 8080
ENTRYPOINT ["docker-entrypoint.sh"]
