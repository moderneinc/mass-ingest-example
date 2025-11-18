# Install Maven if some projects do not use the wrapper
# NOTE: This version may be out of date as new versions are continually released. Check here for the latest version: https://repo1.maven.org/maven2/org/apache/maven/apache-maven/
ENV MAVEN_VERSION=3.9.11
RUN wget --no-check-certificate https://repo1.maven.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz && tar xzvf apache-maven-${MAVEN_VERSION}-bin.tar.gz && rm apache-maven-${MAVEN_VERSION}-bin.tar.gz
RUN mv apache-maven-${MAVEN_VERSION} /opt/apache-maven-${MAVEN_VERSION}
RUN ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn

# Install a Maven wrapper external to projects
RUN /usr/local/bin/mvn -N wrapper:wrapper
RUN mkdir -p /opt/maven-wrapper/bin
RUN mv mvnw mvnw.cmd .mvn /opt/maven-wrapper/bin/
ENV PATH="${PATH}:/opt/maven-wrapper/bin"
