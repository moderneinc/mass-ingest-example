
FROM language-support AS runner

# Customize JVM options
RUN mod config java options edit "{{JAVA_OPTIONS}}"

# Available ports
# 8080 - mod CLI monitor
EXPOSE 8080

# Disables extra formatting in the logs
ENV CUSTOM_CI=true

# Set the data directory for the publish script
ENV DATA_DIR={{DATA_DIR}}

# Copy scripts
COPY --chmod=755 publish.sh publish.sh

# Optional: mount from host
COPY repos.csv repos.csv

CMD ["./publish.sh", "repos.csv"]
