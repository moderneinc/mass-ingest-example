FROM eclipse-temurin:21-jdk-noble

RUN apt-get update && apt-get install -y \
    git \
    git-lfs \
    jq \
    curl \
    && git lfs install \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ARG PUBLISH_URL
ARG PUBLISH_USER
ARG PUBLISH_PASSWORD

WORKDIR /usr/local/bin

COPY moderne-cli-*.jar mod.jar

RUN echo '#!/bin/sh' > mod && \
    echo 'java -jar /usr/local/bin/mod.jar "$@"' >> mod && \
    chmod +x mod

WORKDIR /app

RUN mod config lsts artifacts maven edit ${PUBLISH_URL} --user ${PUBLISH_USER} --password ${PUBLISH_PASSWORD};

EXPOSE 8080

ENV CUSTOM_CI=true
ENV DATA_DIR=/var/moderne

COPY --chmod=755 publish.sh publish.sh
COPY repos.csv repos.csv

CMD ["./publish.sh", "repos.csv"]
