# Configure trust store for self-signed certificates
COPY {{CERT_FILE}} /root/{{CERT_FILE}}
RUN /usr/lib/jvm/temurin-8-jdk/bin/keytool -import -noprompt -file /root/{{CERT_FILE}} -keystore /usr/lib/jvm/temurin-8-jdk/jre/lib/security/cacerts -storepass changeit
RUN /usr/lib/jvm/temurin-11-jdk/bin/keytool -import -noprompt -file /root/{{CERT_FILE}} -keystore /usr/lib/jvm/temurin-11-jdk/lib/security/cacerts -storepass changeit
RUN /usr/lib/jvm/temurin-17-jdk/bin/keytool -import -noprompt -file /root/{{CERT_FILE}} -keystore /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts -storepass changeit
RUN /usr/lib/jvm/temurin-21-jdk/bin/keytool -import -noprompt -file /root/{{CERT_FILE}} -keystore /usr/lib/jvm/temurin-21-jdk/lib/security/cacerts -storepass changeit
RUN /usr/lib/jvm/temurin-25-jdk/bin/keytool -import -noprompt -file /root/{{CERT_FILE}} -keystore /usr/lib/jvm/temurin-25-jdk/lib/security/cacerts -storepass changeit
RUN mod config http trust-store edit java-home

# mvnw scripts in maven projects may attempt to download maven-wrapper jars using wget.
RUN echo "ca_certificate = /root/{{CERT_FILE}}" > /root/.wgetrc
