# Download Moderne CLI from Maven Central
FROM dependencies AS modcli
ARG MODERNE_CLI_STAGE={{CLI_STAGE}}
ARG MODERNE_CLI_VERSION={{CLI_VERSION}}
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


FROM modcli AS language-support

