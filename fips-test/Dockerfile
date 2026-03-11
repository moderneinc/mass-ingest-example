# FIPS integration test image: all LTS JDKs + mod CLI + test repos
#
# Builds a self-contained image that can run `mod build` against small Gradle
# test projects under kernel-level FIPS mode. Used by `make test` in this
# directory — see the Makefile for the full workflow.
#
# The only FIPS workaround needed is disabling TLS 1.3 for JDK 8 and 11.
# See Dockerfile.fips in the repo root for the production image.

FROM registry.access.redhat.com/ubi9/openjdk-25:latest AS base
USER root

# ---------- All LTS JDKs ----------
# JDK 25 is already present from the base image.
RUN microdnf install -y \
    java-1.8.0-openjdk-devel \
    java-11-openjdk-devel \
    java-17-openjdk-devel \
    java-21-openjdk-devel \
    git && \
    microdnf clean all

# ---------- Disable TLS 1.3 for JDK 8 and 11 ----------
# RHEL 9 backported TLS 1.3 (and the P11AEADCipher class) into JDK 8 and 11.
# Under FIPS, all crypto goes through the NSS PKCS11 module. The backported
# P11AEADCipher has a bug in AES-GCM decryption that causes TLS 1.3 handshakes
# to fail with CKR_ENCRYPTED_DATA_INVALID. JDK 17+ has the fix. TLS 1.2 works
# fine because it uses a different PKCS11 code path for AES-GCM.
#
# The fix adds TLSv1.3 to jdk.tls.disabledAlgorithms for JDK 8 and 11.
# RHEL 9's system crypto-policies file overrides that setting at runtime
# (via security.useSystemPropertiesFile=true), so we disable the system
# override for these two JDKs and bake the full FIPS crypto-policies content
# (with TLSv1.3 prepended) directly into their java.security files.
# This is strictly more restrictive than stock FIPS. JDK 17+ is unaffected.
RUN crypto=/etc/crypto-policies/back-ends/java.config && \
    tls_disabled=$(grep '^jdk.tls.disabledAlgorithms=' "$crypto" | sed 's/^jdk.tls.disabledAlgorithms=//') && \
    certpath_disabled=$(grep '^jdk.certpath.disabledAlgorithms=' "$crypto" | sed 's/^jdk.certpath.disabledAlgorithms=//') && \
    named_curves=$(grep '^jdk.disabled.namedCurves=' "$crypto" | sed 's/^jdk.disabled.namedCurves=//') && \
    for f in \
      /usr/lib/jvm/java-1.8.0-openjdk-*/jre/lib/security/java.security \
      /usr/lib/jvm/java-11-openjdk-*/conf/security/java.security; do \
      sed -i 's|^security.useSystemPropertiesFile=true|security.useSystemPropertiesFile=false|' "$f" && \
      sed -i "s|^jdk.tls.disabledAlgorithms=.*|jdk.tls.disabledAlgorithms=TLSv1.3, ${tls_disabled}|" "$f" && \
      sed -i "s|^jdk.certpath.disabledAlgorithms=.*|jdk.certpath.disabledAlgorithms=${certpath_disabled}|" "$f" && \
      sed -i "s|^jdk.disabled.namedCurves=.*|jdk.disabled.namedCurves=${named_curves}|" "$f" && \
      sed -i '/^jdk.tls.legacyAlgorithms=/s/=.*/=/' "$f"; \
    done

# ---------- Moderne CLI (latest 3.x) ----------
ARG MAVEN_REPO_URL=https://repo1.maven.org/maven2
RUN CLI_VERSION=$(curl -s "${MAVEN_REPO_URL}/io/moderne/moderne-cli/maven-metadata.xml" \
        | grep '<release>' | sed 's/.*<release>\(.*\)<\/release>.*/\1/') && \
    echo "Downloading Moderne CLI ${CLI_VERSION}" && \
    curl -fsSL -o /opt/mod.jar "${MAVEN_REPO_URL}/io/moderne/moderne-cli/${CLI_VERSION}/moderne-cli-${CLI_VERSION}.jar"
RUN printf '#!/bin/sh\nexec java -jar /opt/mod.jar "$@"\n' > /usr/local/bin/mod && \
    chmod +x /usr/local/bin/mod

# ---------- Test projects ----------
WORKDIR /repos
COPY repos/ .
RUN git config --global user.email "test@test" && \
    git config --global user.name "test" && \
    for d in */; do \
      cd "/repos/$d" && \
      git init -q && \
      git remote add origin "https://github.com/example/$(basename "$d").git" && \
      git add -A && \
      git commit -q -m "init"; \
    done
