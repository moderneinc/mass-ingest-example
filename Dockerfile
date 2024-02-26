FROM eclipse-temurin:8-jammy AS jdk8
FROM eclipse-temurin:11-jammy AS jdk11
FROM eclipse-temurin:17-jammy AS jdk17

# Install dependencies for `mod` cli
FROM jdk17 AS dependencies
RUN apt-get update && apt-get install -y git supervisor

# Gather various JDK versions
COPY --from=jdk8 /opt/java/openjdk /usr/lib/jvm/temurin-8-jdk
COPY --from=jdk11 /opt/java/openjdk /usr/lib/jvm/temurin-11-jdk
COPY --from=jdk17 /opt/java/openjdk /usr/lib/jvm/temurin-17-jdk

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
ADD ~/.m2/settings.xml /root/.m2/settings.xml
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
