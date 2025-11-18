# Gradle support
RUN wget --no-check-certificate https://services.gradle.org/distributions/gradle-8.14-bin.zip
RUN mkdir /opt/gradle
RUN unzip -d /opt/gradle gradle-8.14-bin.zip
ENV PATH="${PATH}:/opt/gradle/gradle-8.14/bin"
