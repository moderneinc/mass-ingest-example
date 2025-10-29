#!/bin/bash

# Test suite for the Dockerfile generator
# Tests various configuration permutations and validates output

# Don't exit on first failure - we want to see all test results
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Extract only the generation functions from the script, not the interactive parts
# We'll source it in a way that skips the main() call
SKIP_MAIN=1
source scripts/generate-dockerfile.sh 2>/dev/null || true

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# Helper function to print test results
pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((TESTS_FAILED++))
}

info() {
    echo -e "${BLUE}INFO${NC}: $1"
}

section() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}$1${NC}"
    echo -e "${YELLOW}========================================${NC}"
}

# Helper to check if string exists in file
check_contains() {
    local file=$1
    local pattern=$2
    local description=$3

    if grep -q "$pattern" "$file"; then
        pass "$description"
    else
        fail "$description (pattern not found: $pattern)"
    fi
}

# Helper to check if string does NOT exist in file
check_not_contains() {
    local file=$1
    local pattern=$2
    local description=$3

    if ! grep -q "$pattern" "$file"; then
        pass "$description"
    else
        fail "$description (pattern should not exist: $pattern)"
    fi
}

# Helper to count occurrences
check_count() {
    local file=$1
    local pattern=$2
    local expected=$3
    local description=$4

    local count=$(grep -c "$pattern" "$file" || true)
    if [ "$count" -eq "$expected" ]; then
        pass "$description (expected $expected, got $count)"
    else
        fail "$description (expected $expected, got $count)"
    fi
}

# Test 1: Minimal configuration (single JDK, download CLI, no extras)
test_minimal_config() {
    section "Test 1: Minimal Configuration"
    info "JDK 17 only, download stable CLI, no build tools, no extras"

    local output="test-minimal.dockerfile"

    # Set configuration
    ENABLED_JDKS=("17")
    CLI_SOURCE="download"
    CLI_VERSION_TYPE="stable"
    CLI_SPECIFIC_VERSION=""
    CLI_JAR_PATH=""
    ENABLE_MAVEN=false
    ENABLE_GRADLE=false
    MAVEN_SETTINGS_FILE=""
    ENABLE_ANDROID=false
    ENABLE_BAZEL=false
    ENABLE_NODE=false
    ENABLE_PYTHON=false
    ENABLE_DOTNET=false
    ENABLE_AWS_CLI=false
    ENABLE_AWS_BATCH=false
    CERT_FILE=""
    DISABLE_GIT_SSL=false
    SCM_PROVIDERS=()
    GIT_AUTH_METHODS=()
    GIT_AUTH_FILES=()
    JAVA_OPTIONS="-Xmx4g -Xss3m"
    DATA_DIR="/var/moderne"
    OUTPUT_DOCKERFILE="$output"

    generate_dockerfile

    # Validate output
    check_count "$output" "^FROM eclipse-temurin:.*-jdk AS jdk" 1 "Should have exactly 1 JDK stage"
    check_contains "$output" "eclipse-temurin:17-jdk" "Should have JDK 17"
    check_contains "$output" "FROM dependencies AS modcli" "Should have modcli stage"
    check_not_contains "$output" "eclipse-temurin:11-jdk" "Should not have JDK 11"
    check_not_contains "$output" "eclipse-temurin:21-jdk" "Should not have JDK 21"
    check_contains "$output" "mod config java options edit \"-Xmx4g -Xss3m\"" "Should have Java options"
    check_contains "$output" "ENV DATA_DIR=/var/moderne" "Should have data directory"

    rm -f "$output"
}

# Test 2: Multi-JDK configuration
test_multi_jdk() {
    section "Test 2: Multi-JDK Configuration"
    info "JDKs 8, 11, 17, 21 with local CLI JAR"

    local output="test-multi-jdk.dockerfile"

    ENABLED_JDKS=("8" "11" "17" "21")
    CLI_SOURCE="local"
    CLI_JAR_PATH="custom-mod.jar"
    ENABLE_MAVEN=false
    ENABLE_GRADLE=false
    MAVEN_SETTINGS_FILE=""
    ENABLE_ANDROID=false
    ENABLE_BAZEL=false
    ENABLE_NODE=false
    ENABLE_PYTHON=false
    ENABLE_DOTNET=false
    ENABLE_AWS_CLI=false
    ENABLE_AWS_BATCH=false
    CERT_FILE=""
    DISABLE_GIT_SSL=false
    SCM_PROVIDERS=()
    GIT_AUTH_METHODS=()
    GIT_AUTH_FILES=()
    JAVA_OPTIONS="-Xmx8g"
    DATA_DIR="/data"
    OUTPUT_DOCKERFILE="$output"

    generate_dockerfile

    check_count "$output" "^FROM eclipse-temurin:.*-jdk AS jdk" 4 "Should have exactly 4 JDK stages"
    check_contains "$output" "eclipse-temurin:8-jdk" "Should have JDK 8"
    check_contains "$output" "eclipse-temurin:11-jdk" "Should have JDK 11"
    check_contains "$output" "eclipse-temurin:17-jdk" "Should have JDK 17"
    check_contains "$output" "eclipse-temurin:21-jdk" "Should have JDK 21"
    check_count "$output" "COPY --from=jdk" 4 "Should have 4 COPY JDK statements"
    check_contains "$output" "COPY custom-mod.jar /usr/local/bin/mod.jar" "Should copy custom JAR path"
    check_contains "$output" "mod config java options edit \"-Xmx8g\"" "Should have custom Java options"
    check_contains "$output" "ENV DATA_DIR=/data" "Should have custom data directory"

    rm -f "$output"
}

# Test 3: Maven configuration with settings.xml
test_maven_config() {
    section "Test 3: Maven Configuration"
    info "Maven 3.9.11 with settings.xml"

    local output="test-maven.dockerfile"

    ENABLED_JDKS=("17")
    CLI_SOURCE="download"
    CLI_VERSION_TYPE="stable"
    ENABLE_MAVEN=true
    MAVEN_VERSION="3.9.11"
    MAVEN_SETTINGS_FILE="my-settings.xml"
    ENABLE_GRADLE=false
    ENABLE_ANDROID=false
    ENABLE_BAZEL=false
    ENABLE_NODE=false
    ENABLE_PYTHON=false
    ENABLE_DOTNET=false
    ENABLE_AWS_CLI=false
    ENABLE_AWS_BATCH=false
    CERT_FILE=""
    DISABLE_GIT_SSL=false
    SCM_PROVIDERS=()
    GIT_AUTH_METHODS=()
    GIT_AUTH_FILES=()
    JAVA_OPTIONS="-Xmx4g -Xss3m"
    DATA_DIR="/var/moderne"
    OUTPUT_DOCKERFILE="$output"

    generate_dockerfile

    check_contains "$output" "ARG MAVEN_VERSION=3.9.11" "Should have Maven version 3.9.11"
    check_contains "$output" "COPY my-settings.xml" "Should copy Maven settings file"
    check_contains "$output" "mod config build maven settings edit" "Should configure mod CLI with Maven settings"

    rm -f "$output"
}

# Test 4: Certificate configuration
test_certificate_config() {
    section "Test 4: Certificate Configuration"
    info "Self-signed certificate for JDKs 11, 17, 21"

    local output="test-cert.dockerfile"

    ENABLED_JDKS=("11" "17" "21")
    CLI_SOURCE="download"
    CLI_VERSION_TYPE="stable"
    ENABLE_MAVEN=false
    ENABLE_GRADLE=false
    MAVEN_SETTINGS_FILE=""
    ENABLE_ANDROID=false
    ENABLE_BAZEL=false
    ENABLE_NODE=false
    ENABLE_PYTHON=false
    ENABLE_DOTNET=false
    ENABLE_AWS_CLI=false
    ENABLE_AWS_BATCH=false
    CERT_FILE="company.crt"
    DISABLE_GIT_SSL=false
    SCM_PROVIDERS=()
    GIT_AUTH_METHODS=()
    GIT_AUTH_FILES=()
    JAVA_OPTIONS="-Xmx4g -Xss3m"
    DATA_DIR="/var/moderne"
    OUTPUT_DOCKERFILE="$output"

    generate_dockerfile

    check_contains "$output" "COPY company.crt /tmp/custom-cert.crt" "Should copy certificate"
    check_count "$output" "keytool -import" 3 "Should have 3 keytool commands (one per JDK)"
    check_contains "$output" "--from=jdk11" "Should reference JDK 11 for keytool"
    check_contains "$output" "--from=jdk17" "Should reference JDK 17 for keytool"
    check_contains "$output" "--from=jdk21" "Should reference JDK 21 for keytool"

    rm -f "$output"
}

# Test 5: Git authentication - SSH
test_git_ssh() {
    section "Test 5: Git Authentication (SSH)"
    info "GitHub with SSH key"

    local output="test-git-ssh.dockerfile"

    ENABLED_JDKS=("17")
    CLI_SOURCE="download"
    CLI_VERSION_TYPE="stable"
    ENABLE_MAVEN=false
    ENABLE_GRADLE=false
    MAVEN_SETTINGS_FILE=""
    ENABLE_ANDROID=false
    ENABLE_BAZEL=false
    ENABLE_NODE=false
    ENABLE_PYTHON=false
    ENABLE_DOTNET=false
    ENABLE_AWS_CLI=false
    ENABLE_AWS_BATCH=false
    CERT_FILE=""
    DISABLE_GIT_SSL=false
    SCM_PROVIDERS=("github")
    GIT_AUTH_METHODS=("ssh")
    GIT_AUTH_FILES=("~/.ssh/id_rsa")
    JAVA_OPTIONS="-Xmx4g -Xss3m"
    DATA_DIR="/var/moderne"
    OUTPUT_DOCKERFILE="$output"

    generate_dockerfile

    check_contains "$output" "COPY ~/.ssh/id_rsa /root/.ssh/github" "Should copy SSH key"
    check_contains "$output" "chmod 600 /root/.ssh/github" "Should set SSH key permissions"
    check_contains "$output" "git config --global credential.helper" "Should configure git credential helper"

    rm -f "$output"
}

# Test 6: Git authentication - Multiple providers
test_git_multi_provider() {
    section "Test 6: Git Authentication (Multiple Providers)"
    info "GitHub SSH + GitLab HTTPS"

    local output="test-git-multi.dockerfile"

    ENABLED_JDKS=("17")
    CLI_SOURCE="download"
    CLI_VERSION_TYPE="stable"
    ENABLE_MAVEN=false
    ENABLE_GRADLE=false
    MAVEN_SETTINGS_FILE=""
    ENABLE_ANDROID=false
    ENABLE_BAZEL=false
    ENABLE_NODE=false
    ENABLE_PYTHON=false
    ENABLE_DOTNET=false
    ENABLE_AWS_CLI=false
    ENABLE_AWS_BATCH=false
    CERT_FILE=""
    DISABLE_GIT_SSL=false
    SCM_PROVIDERS=("github" "gitlab")
    GIT_AUTH_METHODS=("ssh" "https")
    GIT_AUTH_FILES=("~/.ssh/github_key" "")
    JAVA_OPTIONS="-Xmx4g -Xss3m"
    DATA_DIR="/var/moderne"
    OUTPUT_DOCKERFILE="$output"

    generate_dockerfile

    check_contains "$output" "COPY ~/.ssh/github_key /root/.ssh/github" "Should copy GitHub SSH key"
    check_contains "$output" "git config --global credential.helper" "Should configure git credential helper"

    rm -f "$output"
}

# Test 7: AWS features
test_aws_features() {
    section "Test 7: AWS Features"
    info "AWS CLI + AWS Batch support"

    local output="test-aws.dockerfile"

    ENABLED_JDKS=("17")
    CLI_SOURCE="download"
    CLI_VERSION_TYPE="stable"
    ENABLE_MAVEN=false
    ENABLE_GRADLE=false
    MAVEN_SETTINGS_FILE=""
    ENABLE_ANDROID=false
    ENABLE_BAZEL=false
    ENABLE_NODE=false
    ENABLE_PYTHON=false
    ENABLE_DOTNET=false
    ENABLE_AWS_CLI=true
    ENABLE_AWS_BATCH=true
    CERT_FILE=""
    DISABLE_GIT_SSL=false
    SCM_PROVIDERS=()
    GIT_AUTH_METHODS=()
    GIT_AUTH_FILES=()
    JAVA_OPTIONS="-Xmx4g -Xss3m"
    DATA_DIR="/var/moderne"
    OUTPUT_DOCKERFILE="$output"

    generate_dockerfile

    check_contains "$output" "apt-get install.*awscli" "Should install AWS CLI"
    check_contains "$output" "COPY chunk.sh /usr/local/bin/chunk.sh" "Should copy chunk.sh for AWS Batch"
    check_contains "$output" "chmod +x /usr/local/bin/chunk.sh" "Should make chunk.sh executable"

    rm -f "$output"
}

# Test 8: Specific CLI version
test_specific_cli_version() {
    section "Test 8: Specific Moderne CLI Version"
    info "Moderne CLI version 3.22.0"

    local output="test-cli-version.dockerfile"

    ENABLED_JDKS=("17")
    CLI_SOURCE="download"
    CLI_VERSION_TYPE="specific"
    CLI_SPECIFIC_VERSION="3.22.0"
    ENABLE_MAVEN=false
    ENABLE_GRADLE=false
    MAVEN_SETTINGS_FILE=""
    ENABLE_ANDROID=false
    ENABLE_BAZEL=false
    ENABLE_NODE=false
    ENABLE_PYTHON=false
    ENABLE_DOTNET=false
    ENABLE_AWS_CLI=false
    ENABLE_AWS_BATCH=false
    CERT_FILE=""
    DISABLE_GIT_SSL=false
    SCM_PROVIDERS=()
    GIT_AUTH_METHODS=()
    GIT_AUTH_FILES=()
    JAVA_OPTIONS="-Xmx4g -Xss3m"
    DATA_DIR="/var/moderne"
    OUTPUT_DOCKERFILE="$output"

    generate_dockerfile

    check_contains "$output" "ARG MODERNE_CLI_VERSION=3.22.0" "Should have specific CLI version"

    rm -f "$output"
}

# Test 9: JDK 8 special handling (different cacerts path)
test_jdk8_cert_path() {
    section "Test 9: JDK 8 Certificate Path"
    info "Verify JDK 8 uses correct cacerts path (jre/lib/security)"

    local output="test-jdk8-cert.dockerfile"

    ENABLED_JDKS=("8")
    CLI_SOURCE="download"
    CLI_VERSION_TYPE="stable"
    ENABLE_MAVEN=false
    ENABLE_GRADLE=false
    MAVEN_SETTINGS_FILE=""
    ENABLE_ANDROID=false
    ENABLE_BAZEL=false
    ENABLE_NODE=false
    ENABLE_PYTHON=false
    ENABLE_DOTNET=false
    ENABLE_AWS_CLI=false
    ENABLE_AWS_BATCH=false
    CERT_FILE="test.crt"
    DISABLE_GIT_SSL=false
    SCM_PROVIDERS=()
    GIT_AUTH_METHODS=()
    GIT_AUTH_FILES=()
    JAVA_OPTIONS="-Xmx4g -Xss3m"
    DATA_DIR="/var/moderne"
    OUTPUT_DOCKERFILE="$output"

    generate_dockerfile

    check_contains "$output" "jdk/jre/lib/security/cacerts" "JDK 8 should use jre/lib/security/cacerts path"
    check_not_contains "$output" "jdk/lib/security/cacerts" "JDK 8 should not use modern cacerts path"

    rm -f "$output"
}

# Test 10: All JDKs configuration
test_all_jdks() {
    section "Test 10: All Available JDKs"
    info "JDKs 8, 11, 17, 21, 25"

    local output="test-all-jdks.dockerfile"

    ENABLED_JDKS=("8" "11" "17" "21" "25")
    CLI_SOURCE="download"
    CLI_VERSION_TYPE="stable"
    ENABLE_MAVEN=false
    ENABLE_GRADLE=false
    MAVEN_SETTINGS_FILE=""
    ENABLE_ANDROID=false
    ENABLE_BAZEL=false
    ENABLE_NODE=false
    ENABLE_PYTHON=false
    ENABLE_DOTNET=false
    ENABLE_AWS_CLI=false
    ENABLE_AWS_BATCH=false
    CERT_FILE=""
    DISABLE_GIT_SSL=false
    SCM_PROVIDERS=()
    GIT_AUTH_METHODS=()
    GIT_AUTH_FILES=()
    JAVA_OPTIONS="-Xmx4g -Xss3m"
    DATA_DIR="/var/moderne"
    OUTPUT_DOCKERFILE="$output"

    generate_dockerfile

    check_count "$output" "^FROM eclipse-temurin:.*-jdk AS jdk" 5 "Should have exactly 5 JDK stages"
    check_count "$output" "COPY --from=jdk" 5 "Should have 5 COPY JDK statements"
    check_contains "$output" "eclipse-temurin:25-jdk" "Should use JDK 25 as base"

    rm -f "$output"
}

# Run all tests
main() {
    section "Dockerfile Generator Test Suite"

    test_minimal_config
    test_multi_jdk
    test_maven_config
    test_certificate_config
    test_git_ssh
    test_git_multi_provider
    test_aws_features
    test_specific_cli_version
    test_jdk8_cert_path
    test_all_jdks

    # Summary
    section "Test Summary"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    fi
}

main
