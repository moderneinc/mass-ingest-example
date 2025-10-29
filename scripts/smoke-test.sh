#!/bin/bash

# Quick smoke test for Dockerfile generator
# Tests key configurations and summarizes results

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Avoid running the interactive main
SKIP_MAIN=1
source scripts/generate-dockerfile.sh 2>/dev/null

echo "=================================="
echo "Dockerfile Generator Smoke Test"
echo "=================================="
echo ""

PASS=0
FAIL=0

# Test 1: Single JDK
echo "[Test 1] Single JDK (17 only)"
ENABLED_JDKS=("17")
CLI_SOURCE="download"
CLI_VERSION_TYPE="stable"
ENABLE_MAVEN=false
ENABLE_GRADLE=false
ENABLE_AWS_CLI=false
ENABLE_AWS_BATCH=false
CERT_FILE=""
SCM_PROVIDERS=()
GIT_AUTH_METHODS=()
GIT_AUTH_FILES=()
JAVA_OPTIONS="-Xmx4g"
DATA_DIR="/var/moderne"
OUTPUT_DOCKERFILE="test1.dockerfile"

generate_dockerfile > /dev/null 2>&1

if [ -f "test1.dockerfile" ] && grep -q "eclipse-temurin:17-jdk" "test1.dockerfile"; then
    echo "  ✓ Generated correctly"
    ((PASS++))
else
    echo "  ✗ Failed"
    ((FAIL++))
fi

# Test 2: Multiple JDKs
echo "[Test 2] Multiple JDKs (11, 17, 21)"
ENABLED_JDKS=("11" "17" "21")
OUTPUT_DOCKERFILE="test2.dockerfile"

generate_dockerfile > /dev/null 2>&1

jdk_count=$(grep -c "^FROM eclipse-temurin:.*-jdk AS jdk" "test2.dockerfile" 2>/dev/null || echo "0")
if [ "$jdk_count" -eq 3 ]; then
    echo "  ✓ All 3 JDKs present"
    ((PASS++))
else
    echo "  ✗ Expected 3 JDKs, got $jdk_count"
    ((FAIL++))
fi

# Test 3: Local JAR path
echo "[Test 3] Local CLI JAR with custom path"
ENABLED_JDKS=("17")
CLI_SOURCE="local"
CLI_JAR_PATH="custom-mod.jar"
OUTPUT_DOCKERFILE="test3.dockerfile"

generate_dockerfile > /dev/null 2>&1

if grep -q "COPY custom-mod.jar" "test3.dockerfile" 2>/dev/null; then
    echo "  ✓ Custom JAR path used"
    ((PASS++))
else
    echo "  ✗ Custom JAR path not found"
    ((FAIL++))
fi

# Test 4: Maven configuration
echo "[Test 4] Maven with settings.xml"
ENABLED_JDKS=("17")
CLI_SOURCE="download"
ENABLE_MAVEN=true
MAVEN_VERSION="3.9.11"
MAVEN_SETTINGS_FILE="settings.xml"
OUTPUT_DOCKERFILE="test4.dockerfile"

generate_dockerfile > /dev/null 2>&1

if grep -q "ARG MAVEN_VERSION=3.9.11" "test4.dockerfile" 2>/dev/null && \
   grep -q "COPY settings.xml" "test4.dockerfile" 2>/dev/null; then
    echo "  ✓ Maven configured correctly"
    ((PASS++))
else
    echo "  ✗ Maven configuration missing"
    ((FAIL++))
fi

# Test 5: Certificate handling
echo "[Test 5] Self-signed certificate"
ENABLED_JDKS=("11" "17")
ENABLE_MAVEN=false
MAVEN_SETTINGS_FILE=""
CERT_FILE="company.crt"
OUTPUT_DOCKERFILE="test5.dockerfile"

generate_dockerfile > /dev/null 2>&1

keytool_count=$(grep -c "keytool -import" "test5.dockerfile" 2>/dev/null || echo "0")
if [ "$keytool_count" -eq 2 ]; then
    echo "  ✓ Certificate configured for both JDKs"
    ((PASS++))
else
    echo "  ✗ Expected 2 keytool commands, got $keytool_count"
    ((FAIL++))
fi

# Test 6: Git SSH authentication
echo "[Test 6] Git SSH authentication"
ENABLED_JDKS=("17")
CERT_FILE=""
SCM_PROVIDERS=("github")
GIT_AUTH_METHODS=("ssh")
GIT_AUTH_FILES=("~/.ssh/id_rsa")
OUTPUT_DOCKERFILE="test6.dockerfile"

generate_dockerfile > /dev/null 2>&1

if grep -q "COPY ~/.ssh/id_rsa" "test6.dockerfile" 2>/dev/null; then
    echo "  ✓ SSH key configured"
    ((PASS++))
else
    echo "  ✗ SSH configuration missing"
    ((FAIL++))
fi

# Test 7: Custom Java options and data dir
echo "[Test 7] Custom runtime configuration"
ENABLED_JDKS=("17")
SCM_PROVIDERS=()
GIT_AUTH_METHODS=()
GIT_AUTH_FILES=()
JAVA_OPTIONS="-Xmx8g -Xss5m"
DATA_DIR="/custom/data"
OUTPUT_DOCKERFILE="test7.dockerfile"

generate_dockerfile > /dev/null 2>&1

if grep -q 'mod config java options edit "-Xmx8g -Xss5m"' "test7.dockerfile" 2>/dev/null && \
   grep -q "ENV DATA_DIR=/custom/data" "test7.dockerfile" 2>/dev/null; then
    echo "  ✓ Runtime config applied"
    ((PASS++))
else
    echo "  ✗ Runtime config not applied"
    ((FAIL++))
fi

# Test 8: AWS features
echo "[Test 8] AWS CLI and Batch support"
ENABLED_JDKS=("17")
JAVA_OPTIONS="-Xmx4g"
DATA_DIR="/var/moderne"
ENABLE_AWS_CLI=true
ENABLE_AWS_BATCH=true
OUTPUT_DOCKERFILE="test8.dockerfile"

generate_dockerfile > /dev/null 2>&1

if grep -q "awscli" "test8.dockerfile" 2>/dev/null && \
   grep -q "chunk.sh" "test8.dockerfile" 2>/dev/null; then
    echo "  ✓ AWS features included"
    ((PASS++))
else
    echo "  ✗ AWS features missing"
    ((FAIL++))
fi

# Cleanup
rm -f test*.dockerfile

# Summary
echo ""
echo "=================================="
echo "Test Summary"
echo "=================================="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "✓ All tests passed!"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
