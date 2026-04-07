# Configure Maven settings for custom repositories, mirrors, or profiles
COPY {{SETTINGS_FILE}} /root/.m2/settings.xml
RUN mod config build maven settings edit /root/.m2/settings.xml
