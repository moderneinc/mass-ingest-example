#!/bin/bash

# Script to initialize credentials from environment variables at runtime
# This allows Kubernetes to inject secrets as environment variables

set -e

echo "Initializing credentials from environment variables..."

# Configure Git credentials if provided via environment variable
if [ -n "${GIT_CREDENTIALS}" ]; then
    echo "Configuring Git credentials..."
    echo "${GIT_CREDENTIALS}" > /root/.git-credentials
    git config --global credential.helper store --file=/root/.git-credentials
    
    # Optional: disable SSL verification if needed
    if [ "${GIT_SSL_VERIFY}" = "false" ]; then
        git config --global http.sslVerify false
    fi
fi

# Configure SSH keys if provided via environment variable
if [ -n "${SSH_PRIVATE_KEY}" ]; then
    echo "Configuring SSH keys..."
    mkdir -p /root/.ssh
    chmod 755 /root/.ssh
    echo "${SSH_PRIVATE_KEY}" > /root/.ssh/id_rsa
    chmod 600 /root/.ssh/id_rsa
    
    # Configure known hosts if provided
    if [ -n "${SSH_KNOWN_HOSTS}" ]; then
        echo "${SSH_KNOWN_HOSTS}" > /root/.ssh/known_hosts
        chmod 600 /root/.ssh/known_hosts
    fi
    
    # Auto-accept host keys if specified (use with caution)
    if [ "${SSH_STRICT_HOST_KEY_CHECKING}" = "false" ]; then
        echo "StrictHostKeyChecking no" >> /root/.ssh/config
        chmod 600 /root/.ssh/config
    fi
fi

# Configure Maven settings if provided via environment variable
if [ -n "${MAVEN_SETTINGS_XML}" ]; then
    echo "Configuring Maven settings..."
    mkdir -p /root/.m2
    echo "${MAVEN_SETTINGS_XML}" > /root/.m2/settings.xml
    mod config build maven settings edit /root/.m2/settings.xml
fi

# Configure Maven settings security if provided
if [ -n "${MAVEN_SETTINGS_SECURITY_XML}" ]; then
    echo "Configuring Maven settings security..."
    mkdir -p /root/.m2
    echo "${MAVEN_SETTINGS_SECURITY_XML}" > /root/.m2/settings-security.xml
fi

# Configure custom CA certificates if provided
if [ -n "${CUSTOM_CA_CERT}" ]; then
    echo "Configuring custom CA certificates..."
    echo "${CUSTOM_CA_CERT}" > /root/custom-ca.crt
    
    # Import into Java trust stores
    for JDK_VERSION in 8 11 17 21; do
        if [ -d "/usr/lib/jvm/temurin-${JDK_VERSION}-jdk" ]; then
            if [ "${JDK_VERSION}" = "8" ]; then
                CACERTS_PATH="/usr/lib/jvm/temurin-8-jdk/jre/lib/security/cacerts"
            else
                CACERTS_PATH="/usr/lib/jvm/temurin-${JDK_VERSION}-jdk/lib/security/cacerts"
            fi
            
            echo "Importing CA cert into JDK ${JDK_VERSION} trust store..."
            /usr/lib/jvm/temurin-${JDK_VERSION}-jdk/bin/keytool -import -noprompt \
                -alias custom-ca \
                -file /root/custom-ca.crt \
                -keystore ${CACERTS_PATH} \
                -storepass changeit
        fi
    done
    
    # Configure mod CLI to use Java trust store
    mod config http trust-store edit java-home
    
    # Configure wget if needed
    if [ "${CONFIGURE_WGET_CA}" = "true" ]; then
        echo "ca_certificate = /root/custom-ca.crt" > /root/.wgetrc
    fi
fi

# Configure Gradle properties if provided
if [ -n "${GRADLE_PROPERTIES}" ]; then
    echo "Configuring Gradle properties..."
    mkdir -p /root/.gradle
    echo "${GRADLE_PROPERTIES}" > /root/.gradle/gradle.properties
fi

# Configure NPM registry and auth if provided
if [ -n "${NPM_REGISTRY}" ]; then
    echo "Configuring NPM registry..."
    npm config set registry "${NPM_REGISTRY}"
    
    if [ -n "${NPM_AUTH_TOKEN}" ]; then
        npm config set _auth "${NPM_AUTH_TOKEN}"
    fi
fi

# Configure Python pip index if provided
if [ -n "${PIP_INDEX_URL}" ]; then
    echo "Configuring pip index..."
    mkdir -p /root/.pip
    cat > /root/.pip/pip.conf <<EOF
[global]
index-url = ${PIP_INDEX_URL}
EOF
    
    if [ -n "${PIP_TRUSTED_HOST}" ]; then
        echo "trusted-host = ${PIP_TRUSTED_HOST}" >> /root/.pip/pip.conf
    fi
fi

echo "Credential initialization complete."