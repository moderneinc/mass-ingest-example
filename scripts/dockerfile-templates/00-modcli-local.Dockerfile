# Use locally provided Moderne CLI JAR
FROM dependencies AS modcli
WORKDIR /app
COPY {{CLI_JAR_PATH}} /usr/local/bin/mod.jar

# Create a shell script 'mod' that runs the moderne-cli JAR file
RUN printf '#!/bin/sh\njava -jar /usr/local/bin/mod.jar "$@"\n' > /usr/local/bin/mod

# Make the 'mod' script executable
RUN chmod +x /usr/local/bin/mod

# Credential configuration has been moved to runtime (publish.sh/publish.ps1) to avoid
# baking sensitive credentials into Docker image layers. Credentials are now passed as
# environment variables and configured when the container starts.


FROM modcli AS language-support

