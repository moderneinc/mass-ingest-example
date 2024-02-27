FROM eclipse-temurin:8-jammy AS jdk8
FROM eclipse-temurin:11-jammy AS jdk11
FROM eclipse-temurin:17-jammy AS jdk17
FROM eclipse-temurin:21-jammy AS jdk21
# Import Grafana and Prometheus
# Comment out the following lines if you don't need Grafana and Prometheus
FROM grafana/grafana as grafana
FROM prom/prometheus as prometheus

# Install dependencies for `mod` cli
FROM jdk21 AS dependencies
RUN apt-get update && apt-get install -y git supervisor

# Gather various JDK versions
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

# Copy configs for prometheus and grafana
# Comment out the following lines if you don't need Grafana and Prometheus
ADD grafana-datasource.yml /etc/grafana/provisioning/datasources/grafana-datasource.yml
ADD grafana-dashboard.yml /etc/grafana/provisioning/dashboards/grafana-dashboard.yml
ADD grafana-build-dashboard.json /etc/grafana/dashboards/build.json
ADD grafana-run-dashboard.json /etc/grafana/dashboards/run.json
ADD prometheus.yml /etc/prometheus/prometheus.yml

FROM dependencies AS modcli
ARG MODERNE_CLI_VERSION=2.7.6
ARG MODERNE_TENANT=app
ARG MODERNE_TOKEN
ARG PUBLISH_URL=https://artifactory.moderne.ninja/artifactory/moderne-ingest
ARG PUBLISH_USER
ARG PUBLISH_PASSWORD
ARG TRUSTED_CERTIFICATES_PATH

WORKDIR /app
# Download the CLI and connect it to your instance of Moderne, and your own Artifactory
RUN curl --insecure --request GET --url https://repo1.maven.org/maven2/io/moderne/moderne-cli/${MODERNE_CLI_VERSION}/moderne-cli-${MODERNE_CLI_VERSION}.jar --output mod.jar
RUN java -jar mod.jar config moderne edit --token=${MODERNE_TOKEN} https://${MODERNE_TENANT}.moderne.io
RUN java -jar mod.jar config lsts artifacts artifactory edit ${PUBLISH_URL} --user ${PUBLISH_USER} --password ${PUBLISH_PASSWORD}

# Configure Maven Settings if they are required to build
ADD maven/settings.xml /root/.m2/settings.xml
RUN java -jar mod.jar config build maven settings edit /root/.m2/settings.xml

# Configure git credentials if they are required to clone
# .git-credentials each line defines credentilas for a host in the format: https://username:password@host
ADD .git-credentials /root/.git-credentials
RUN git config --global credential.helper store --file=/root/.git-credentials
RUN git config --global http.sslVerify false

# Configure trust store if self-signed certificates are in use for artifact repository, source control, or moderne tenant
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-8-jdk/jre/lib/security/cacerts
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-11-jdk/lib/security/cacerts
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts
RUN java -jar mod.jar config http trust-store edit java-home

FROM modcli AS runner
EXPOSE 8080
ADD supervisord.conf /etc/supervisord.conf

WORKDIR /app
ADD publish.sh publish.sh
RUN chmod +x publish.sh

# Optional: mount from host
ADD repos.csv repos.csv

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
