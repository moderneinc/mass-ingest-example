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
ARG MODERNE_CLI_VERSION=3.19.4
ARG MODERNE_TENANT=app
# Personal access token for Moderne; can be created through https://<tenant>.moderne.io/settings/access-token
ARG MODERNE_TOKEN
# We recommend a dedicated Artifactory Maven repository, allowing both releases & snapshots; supply the full URL here
ARG PUBLISH_URL=https://artifactory.moderne.internal/artifactory/moderne-ingest
ARG PUBLISH_USER
ARG PUBLISH_PASSWORD
# Path to the trusted certificates file, which will replace the cacerts file in the configured JDKs if necessary
ARG TRUSTED_CERTIFICATES_PATH

WORKDIR /app
# Download the CLI and connect it to your instance of Moderne, and your own Artifactory
RUN curl --insecure --request GET --url https://repo1.maven.org/maven2/io/moderne/moderne-cli/${MODERNE_CLI_VERSION}/moderne-cli-${MODERNE_CLI_VERSION}.jar --output mod.jar
RUN java -jar mod.jar config moderne edit --token=${MODERNE_TOKEN} https://${MODERNE_TENANT}.moderne.io
RUN java -jar mod.jar config lsts artifacts artifactory edit ${PUBLISH_URL} --user ${PUBLISH_USER} --password ${PUBLISH_PASSWORD}

# Configure Maven Settings if they are required to build
ADD maven/settings.xml /root/.m2/settings.xml
RUN java -jar mod.jar config build maven settings edit /root/.m2/settings.xml

# Install Maven if some projects do not use the wrapper
# wget https://dlcdn.apache.org/maven/maven-3/3.9.6/binaries/apache-maven-3.9.6-bin.zip && unzip apache-maven-3.9.6-bin.zip
#COPY apache-maven-3.9.6 /opt/apache-maven-3.9.6
#RUN ln -s /opt/apache-maven-3.9.6/bin/mvn /usr/local/bin/mvn

# Configure git credentials if they are required to clone; ensure this lines up with your use of https:// or ssh://
# .git-credentials each line defines credentilas for a host in the format: https://username:password@host
ADD .git-credentials /root/.git-credentials
RUN git config --global credential.helper store --file=/root/.git-credentials
RUN git config --global http.sslVerify false

# Configure trust store if self-signed certificates are in use for artifact repository, source control, or moderne tenant
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-8-jdk/jre/lib/security/cacerts
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-11-jdk/lib/security/cacerts
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-21-jdk/lib/security/cacerts
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
