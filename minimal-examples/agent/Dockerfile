FROM eclipse-temurin:17-jre-jammy

RUN groupadd -r app && useradd --no-log-init -r -m -g app app

WORKDIR /app

COPY --chown=app:app moderne-agent-*.jar /app/moderne-agent.jar

USER app

EXPOSE 8080

CMD java \
    -XX:-OmitStackTraceInFastThrow \
    -XX:MaxRAMPercentage=65.0 \
    -XX:MaxDirectMemorySize=2G \
    -XX:+HeapDumpOnOutOfMemoryError \
    -XX:+UseStringDeduplication \
    -Dmanagement.endpoint.health.probes.enabled=true \
    -jar moderne-agent.jar
