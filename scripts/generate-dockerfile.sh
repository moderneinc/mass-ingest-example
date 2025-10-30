#!/bin/bash

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/dockerfile-templates"

# Colors for better UX
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
GRAY='\033[2m'  # Dim text for subtle appearance
RESET='\033[0m'
BOLD='\033[1m'

# Configuration storage
ENABLED_JDKS=("8" "11" "17" "21" "25")

# Moderne CLI
CLI_SOURCE="download"  # or "local"
CLI_VERSION_TYPE="stable"  # or "staging" or "specific"
CLI_SPECIFIC_VERSION=""
CLI_JAR_PATH=""

# Build tools
ENABLE_MAVEN=false
MAVEN_VERSION="3.9.11"
ENABLE_GRADLE=false
ENABLE_BAZEL=false

# Development platforms & runtimes
ENABLE_ANDROID=false
ENABLE_NODE=false
ENABLE_PYTHON=false
ENABLE_DOTNET=false

# Scalability
ENABLE_AWS_CLI=false
ENABLE_AWS_BATCH=false

# Security
CERT_FILE=""

# Git authentication
ENABLE_GIT_SSH=false
ENABLE_GIT_HTTPS=false
CREATE_GIT_CREDENTIALS_TEMPLATE=false

# Maven
MAVEN_SETTINGS_FILE=""

# Runtime config
JAVA_OPTIONS="-Xmx4g -Xss3m"
DATA_DIR="/var/moderne"

# Helper
CHOICE_RESULT=0

OUTPUT_DOCKERFILE="Dockerfile.generated"

# Helper functions
print_header() {
    echo -e "${CYAN}${BOLD}$1${RESET}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

print_section() {
    echo -e "\n${CYAN}${BOLD}▶ $1${RESET}\n"
}

print_context() {
    # Format with indentation: first line with icon, subsequent lines indented
    local text="$1"
    local first_line=$(echo "$text" | head -n 1)
    local rest=$(echo "$text" | tail -n +2)

    echo -e "${GRAY}ℹ  ${first_line}${RESET}"
    if [ -n "$rest" ]; then
        echo "$rest" | while IFS= read -r line; do
            echo -e "   ${GRAY}${line}${RESET}"
        done
    fi
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${RESET}"
}

print_error() {
    echo -e "${RED}✗ $1${RESET}"
}

ask_yes_no() {
    local prompt="$1"
    local response

    # Add (y/n) to prompt if not already present
    if [[ ! "$prompt" =~ \(y/n\) ]]; then
        prompt="$prompt (y/n)"
    fi

    while true; do
        read -p "$(echo -e "${BOLD}$prompt${RESET}: ")" response
        case "$response" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice

    echo -e "${BOLD}$prompt${RESET}"
    for i in "${!options[@]}"; do
        echo "  $((i+1)). ${options[$i]}"
    done

    while true; do
        read -p "$(echo -e "\n${BOLD}Enter your choice${RESET} [1-${#options[@]}]: ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            CHOICE_RESULT=$((choice-1))
            return 0
        fi
        echo "Invalid choice. Please enter a number between 1 and ${#options[@]}."
    done
}

ask_optional_path() {
    local prompt="$1"
    local path

    read -p "$(echo -e "${BOLD}$prompt${RESET} (or press Enter to skip): ")" path
    echo "$path"
}

# Welcome message
show_welcome() {
    clear

    # Moderne logo
    echo "   ▛▀▀▚▖  ▗▄▟▜"
    echo "   ▌   ▜▄▟▀  ▐"
    echo "   ▛▀▀█▀▛▀▀▀▀▜"
    echo "   ▌▟▀  ▛▀▀▀▀▜"
    echo "   ▀▀▀▀▀▀▀▀▀▀▀"
    echo ""

    print_header "Mass Ingest - Dockerfile Generator"

    echo -e "Ready to transform code at scale? This wizard will build a custom Docker"
    echo -e "environment perfectly matched to your repository landscape."
    echo ""
    echo -e "In just a few minutes, you'll have a production-ready container that can:"
    echo -e "  ${GREEN}✓${RESET} Build LSTs across all your projects"
    echo -e "  ${GREEN}✓${RESET} Handle diverse build tools and language runtimes"
    echo -e "  ${GREEN}✓${RESET} Scale with AWS Batch for enterprise workloads"
    echo ""
    echo -e "${CYAN}${BOLD}What we'll set up together:${RESET}"
    echo ""
    echo -e "  ${CYAN}1.${RESET} ${BOLD}JDK versions${RESET} - support for Java 8 through 25"
    echo -e "  ${CYAN}2.${RESET} ${BOLD}Moderne CLI${RESET} - the engine for code transformation"
    echo -e "  ${CYAN}3.${RESET} ${BOLD}Build tools${RESET} - Maven, Gradle, and Bazel support"
    echo -e "  ${CYAN}4.${RESET} ${BOLD}Language runtimes${RESET} - Android, Node, Python, .NET, and more"
    echo -e "  ${CYAN}5.${RESET} ${BOLD}Enterprise features${RESET} - AWS Batch integration for scale"
    echo -e "  ${CYAN}6.${RESET} ${BOLD}Security${RESET} - certificate management and Git authentication"
    echo -e "  ${CYAN}7.${RESET} ${BOLD}Runtime tuning${RESET} - memory and performance optimization"
    echo ""
    echo -e "${CYAN}${BOLD}Time investment:${RESET} Just 2-3 minutes"
    echo ""

    read -p "$(echo -e "${BOLD}Press Enter to get started!${RESET} ")"
    clear
}

# JDK selection
ask_jdk_versions() {
    while true; do
        print_section "JDK Versions"

        echo "The Moderne CLI needs access to all JDK versions used by your Java projects to"
        echo "successfully build LSTs. We'll install JDK 8, 11, 17, 21, and 25 by default."
        echo ""

        print_context "${BOLD}Why all versions?\033[22m${GRAY} This ensures compatibility with projects targeting any Java version.
The additional disk space (~2GB) is worth avoiding build failures.

${BOLD}Safe to skip:\033[22m${GRAY} If you're certain your projects only use specific JDK versions, you can
disable the ones you don't need to save space."

        if ask_yes_no "Keep all JDK versions (8, 11, 17, 21, 25)?"; then
            ENABLED_JDKS=("8" "11" "17" "21" "25")
            print_success "All JDK versions will be installed"
        else
            echo ""
            echo -e "${BOLD}Select which JDK versions to include:${RESET}"

            local selected_jdks=()

            if ask_yes_no "  Include JDK 8?"; then
                selected_jdks+=("8")
            fi

            if ask_yes_no "  Include JDK 11?"; then
                selected_jdks+=("11")
            fi

            if ask_yes_no "  Include JDK 17?"; then
                selected_jdks+=("17")
            fi

            if ask_yes_no "  Include JDK 21?"; then
                selected_jdks+=("21")
            fi

            if ask_yes_no "  Include JDK 25?"; then
                selected_jdks+=("25")
            fi

            if [ ${#selected_jdks[@]} -eq 0 ]; then
                echo -e "\n${RED}Error: At least one JDK version must be selected!${RESET}"
                echo -e "${YELLOW}Defaulting to all JDK versions.${RESET}"
                ENABLED_JDKS=("8" "11" "17" "21" "25")
            else
                ENABLED_JDKS=("${selected_jdks[@]}")
                print_success "Selected JDK versions: ${ENABLED_JDKS[*]}"
            fi
        fi

        # Confirm selection
        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        echo -e "  JDK versions: ${ENABLED_JDKS[*]}"
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Moderne CLI configuration
ask_modcli_config() {
    while true; do
        # Reset for restart
        CLI_SOURCE="download"
        CLI_VERSION_TYPE="stable"
        CLI_SPECIFIC_VERSION=""
        CLI_JAR_PATH=""

        print_section "Moderne CLI Configuration"

        print_context "Choose how to provide the Moderne CLI to the container.

${BOLD}Download from Maven Central:\033[22m${GRAY} Automatically fetches the specified version during build.
${BOLD}Supply JAR directly:\033[22m${GRAY} You provide mod.jar in the build context (faster builds, version control)."

        ask_choice "How do you want to provide the Moderne CLI?" \
            "Download from Maven Central (recommended)" \
            "Supply JAR directly (mod.jar in build context)"

        case $CHOICE_RESULT in
            0) CLI_SOURCE="download";;
            1) CLI_SOURCE="local";;
        esac

        if [ "$CLI_SOURCE" = "download" ]; then
            echo ""
            print_context "Select which version to download.

${BOLD}Latest stable:\033[22m${GRAY} Recommended for production use.
${BOLD}Latest staging:\033[22m${GRAY} Pre-release version with newest features.
${BOLD}Specific version:\033[22m${GRAY} Pin to a known version for reproducibility."

            ask_choice "Which version do you want?" \
                "Latest stable (recommended)" \
                "Latest staging" \
                "Specific version"

            case $CHOICE_RESULT in
                0) CLI_VERSION_TYPE="stable";;
                1) CLI_VERSION_TYPE="staging";;
                2)
                    CLI_VERSION_TYPE="specific"
                    read -p "$(echo -e "${BOLD}Enter version number${RESET} (e.g., 3.0.0): ")" CLI_SPECIFIC_VERSION
                    if [ -z "$CLI_SPECIFIC_VERSION" ]; then
                        echo -e "${YELLOW}No version specified, defaulting to latest stable${RESET}"
                        CLI_VERSION_TYPE="stable"
                    fi
                    ;;
            esac

            print_success "Will download: $CLI_VERSION_TYPE$([ "$CLI_VERSION_TYPE" = "specific" ] && echo " ($CLI_SPECIFIC_VERSION)")"
        else
            echo ""
            CLI_JAR_PATH=$(ask_optional_path "Enter path to mod.jar file (default: mod.jar in build context)")
            if [ -z "$CLI_JAR_PATH" ]; then
                CLI_JAR_PATH="mod.jar"
                print_success "Will use mod.jar from build context"
            else
                print_success "Will use JAR from: $CLI_JAR_PATH"
            fi
        fi

        # Confirm configuration
        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        if [ "$CLI_SOURCE" = "download" ]; then
            echo -e "  Moderne CLI: Download from Maven Central ($CLI_VERSION_TYPE$([ "$CLI_VERSION_TYPE" = "specific" ] && echo " - $CLI_SPECIFIC_VERSION"))"
        else
            echo -e "  Moderne CLI: Local JAR file ($CLI_JAR_PATH)"
        fi
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Maven configuration page
ask_maven_build_config() {
    while true; do
        # Reset for restart
        ENABLE_MAVEN=false
        MAVEN_SETTINGS_FILE=""
        MAVEN_VERSION="3.9.11"

        print_section "Maven Configuration"

        echo "Maven is a popular build tool for Java projects."
        echo ""

        print_context "${BOLD}Maven wrappers (mvnw):\033[22m${GRAY} Many projects include wrapper scripts that don't require Maven to be pre-installed.
${BOLD}Pre-installed Maven:\033[22m${GRAY} Older projects or specific scenarios may need Maven available globally."

        if ! ask_yes_no "Do any of your repositories use Maven?"; then
            clear
            return
        fi

        echo ""
        if ask_yes_no "Do you need Maven pre-installed? (Say 'no' if all projects use mvnw wrapper)"; then
            ENABLE_MAVEN=true

            # Ask for Maven version with validation
            while true; do
                read -p "$(echo -e "${BOLD}Maven version${RESET} (press Enter for default) [$MAVEN_VERSION]: ")" user_maven_version

                if [ -z "$user_maven_version" ]; then
                    # User pressed Enter, use default
                    break
                fi

                # Validate semver format (MAJOR.MINOR.PATCH)
                if [[ "$user_maven_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    MAVEN_VERSION="$user_maven_version"
                    break
                else
                    echo -e "${RED}Invalid version format. Maven versions must follow semver (e.g., 3.9.11)${RESET}"
                    if ! ask_yes_no "Try again?"; then
                        # Keep default version
                        break
                    fi
                fi
            done

            print_success "Maven $MAVEN_VERSION will be installed"
        else
            print_success "Maven will not be installed (projects will use wrappers)"
        fi

        # Maven settings.xml configuration
        echo ""
        echo -e "${BOLD}Maven Settings${RESET}"
        print_context "If your Maven builds require custom settings (private repositories, mirrors, profiles,
authentication), you can provide a settings.xml file.

${BOLD}What this does:\033[22m${GRAY} Copies your settings.xml to /root/.m2/ and configures mod CLI to use it."

        if ask_yes_no "Do you need custom Maven settings.xml?"; then
            while true; do
                MAVEN_SETTINGS_FILE=$(ask_optional_path "Enter path to your settings.xml file")

                if [ -z "$MAVEN_SETTINGS_FILE" ]; then
                    echo -e "\n${YELLOW}Note: Maven settings sections will be included as comments."
                    echo -e "      You'll need to uncomment and customize them manually.${RESET}"
                    break
                fi

                # Validate file extension
                if [[ ! "$MAVEN_SETTINGS_FILE" =~ \.xml$ ]]; then
                    echo -e "${RED}Error: Maven settings must be an XML file (expected .xml extension)${RESET}"
                    echo -e "${YELLOW}You provided: $(basename "$MAVEN_SETTINGS_FILE")${RESET}"
                    if ! ask_yes_no "Try again?"; then
                        MAVEN_SETTINGS_FILE=""
                        break
                    fi
                    continue
                fi

                if [ -f "$MAVEN_SETTINGS_FILE" ]; then
                    print_success "Maven settings file found: $MAVEN_SETTINGS_FILE"
                    break
                else
                    print_error "Warning: File not found, but will include in Dockerfile anyway"
                    echo -e "${YELLOW}        Make sure to provide the settings.xml before building.${RESET}"
                    if ask_yes_no "Use this path anyway?"; then
                        break
                    fi
                fi
            done
        fi

        # Confirm configuration
        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        if [ "$ENABLE_MAVEN" = true ]; then
            echo -e "  Maven: Version $MAVEN_VERSION will be installed"
        else
            echo -e "  Maven: Not installed (projects use wrappers)"
        fi
        if [ -n "$MAVEN_SETTINGS_FILE" ]; then
            echo -e "  Maven settings: $MAVEN_SETTINGS_FILE"
        else
            echo -e "  Maven settings: None configured"
        fi
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Gradle configuration page
ask_gradle_build_config() {
    while true; do
        # Reset for restart
        ENABLE_GRADLE=false

        print_section "Gradle Configuration"

        echo "Gradle is a popular build tool for Java and Kotlin projects."
        echo ""

        print_context "${BOLD}Gradle wrappers (gradlew):\033[22m${GRAY} Many projects include wrapper scripts that don't require Gradle to be pre-installed.
${BOLD}Pre-installed Gradle:\033[22m${GRAY} Older projects or specific scenarios may need Gradle 8.14 available globally."

        if ! ask_yes_no "Do any of your repositories use Gradle?"; then
            clear
            return
        fi

        echo ""
        if ask_yes_no "Do you need Gradle pre-installed? (Say 'no' if all projects use gradlew wrapper)"; then
            ENABLE_GRADLE=true
        fi

        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        if [ "$ENABLE_GRADLE" = true ]; then
            echo -e "  Gradle: Version 8.14 will be installed"
        else
            echo -e "  Gradle: Not installed (projects use wrappers)"
        fi
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Other build tools
ask_other_build_tools() {
    while true; do
        print_section "Other Build Tools"

        print_context "Some projects use specialized build tools beyond Maven and Gradle."

        # Bazel
        echo -e "${BOLD}Bazel${RESET}"
        echo "Google's build system, commonly used in monorepos and large-scale projects."
        if ask_yes_no "Do you use Bazel?"; then
            ENABLE_BAZEL=true
        else
            ENABLE_BAZEL=false
        fi

        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        if [ "$ENABLE_BAZEL" = true ]; then
            echo -e "  Bazel: Will be installed"
        else
            echo -e "  Bazel: Not needed"
        fi
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Development platforms & runtimes
ask_language_runtimes() {
    while true; do
        # Initialize all to false for restart
        ENABLE_ANDROID=false
        ENABLE_NODE=false
        ENABLE_PYTHON=false
        ENABLE_DOTNET=false

        print_section "Development Platforms & Runtimes"

        print_context "While the Moderne CLI primarily processes Java/Kotlin projects, your repositories
may have multi-language components that require additional runtimes for successful builds.

Answer 'yes' if any of your repositories need these runtimes."

        # Android
        echo -e "${BOLD}Android SDK${RESET}"
        echo "Required for Android applications. Installs API platforms 25-33 (~5GB)."
        if ask_yes_no "Do you have Android projects?"; then
            ENABLE_ANDROID=true
        fi

        # Node.js
        echo -e "\n${BOLD}Node.js${RESET}"
        echo "Required for projects with frontend components or JavaScript/TypeScript code."
        if ask_yes_no "Do you need Node.js?"; then
            ENABLE_NODE=true
        fi

        # Python
        echo -e "\n${BOLD}Python 3.11${RESET}"
        echo "Needed for Python projects or build scripts with Python dependencies."
        if ask_yes_no "Do you need Python?"; then
            ENABLE_PYTHON=true
        fi

        # .NET
        echo -e "\n${BOLD}.NET SDK${RESET}"
        echo "Required for .NET/C# projects. Installs .NET 6.0 and 8.0 SDKs."
        if ask_yes_no "Do you have .NET projects?"; then
            ENABLE_DOTNET=true
        fi

        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        local any_selected=false
        [ "$ENABLE_ANDROID" = true ] && echo -e "  Android SDK: Will be installed" && any_selected=true
        [ "$ENABLE_NODE" = true ] && echo -e "  Node.js 20.x: Will be installed" && any_selected=true
        [ "$ENABLE_PYTHON" = true ] && echo -e "  Python 3.11: Will be installed" && any_selected=true
        [ "$ENABLE_DOTNET" = true ] && echo -e "  .NET SDK 6.0/8.0: Will be installed" && any_selected=true
        [ "$any_selected" = false ] && echo -e "  No additional language runtimes"
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Scalability options
ask_scalability_options() {
    while true; do
        # Reset for restart
        ENABLE_AWS_CLI=false
        ENABLE_AWS_BATCH=false

        print_section "Scalability Options"

        # AWS CLI for S3 URLs
        echo -e "\n${BOLD}AWS CLI for S3 URLs${RESET}"
        echo "If your repositories are stored in S3 or you need to access S3 resources,"
        echo "the AWS CLI can be installed in the container."
        echo ""

        print_context "${BOLD}What this does:\033[22m${GRAY} Installs AWS CLI v2, allowing you to use S3 URLs in your repos.csv
and access AWS resources during processing."

        if ask_yes_no "Do you need AWS CLI?"; then
            ENABLE_AWS_CLI=true
        fi

        # AWS Batch support
        echo -e "\n${BOLD}AWS Batch Support${RESET}"
        echo "AWS Batch allows you to run containerized jobs at scale."
        echo ""

        print_context "${BOLD}What this does:\033[22m${GRAY} Includes chunk.sh script for job parallelization in AWS Batch environments."

        if ask_yes_no "Do you need AWS Batch support?"; then
            ENABLE_AWS_BATCH=true
        fi

        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        local any_selected=false
        if [ "$ENABLE_AWS_CLI" = true ]; then
            echo -e "  AWS CLI: Will be installed"
            any_selected=true
        fi
        if [ "$ENABLE_AWS_BATCH" = true ]; then
            echo -e "  AWS Batch support: Will be included"
            any_selected=true
        fi
        if [ "$any_selected" = false ]; then
            echo -e "  No scalability options needed"
        fi
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Security configuration
ask_security_config() {
    while true; do
        # Reset for restart
        CERT_FILE=""

        print_section "Security Configuration"

        # Self-signed certificates
        echo "If your artifact repository, source control, or Moderne tenant uses self-signed"
        echo "certificates, you'll need to import them into the JVM trust stores."
        echo ""

        print_context "${BOLD}What this does:\033[22m${GRAY} Imports your certificate into all JDK keystores and configures wget
for Maven wrapper scripts."

        if ! ask_yes_no "Do you use self-signed certificates?"; then
            clear
            return
        fi

        # If we get here, user said yes
        if true; then
            while true; do
                CERT_FILE=$(ask_optional_path "Enter path to your certificate file (e.g., mycert.crt)")

                if [ -z "$CERT_FILE" ]; then
                    echo -e "\n${YELLOW}Note: Certificate configuration sections will be included as comments."
                    echo -e "      You'll need to uncomment and customize them manually.${RESET}"
                    break
                fi

                # Validate file extension (common certificate formats)
                if [[ ! "$CERT_FILE" =~ \.(crt|cer|pem|der)$ ]]; then
                    echo -e "${RED}Warning: File doesn't appear to be a certificate (expected .crt, .cer, .pem, or .der)${RESET}"
                    if ! ask_yes_no "Use this file anyway?"; then
                        continue
                    fi
                fi

                if [ -f "$CERT_FILE" ]; then
                    print_success "Certificate file found: $CERT_FILE"
                    break
                else
                    print_error "Warning: File not found, but will include in Dockerfile anyway"
                    echo -e "${YELLOW}        Make sure to provide the certificate before building.${RESET}"
                    if ask_yes_no "Use this path anyway?"; then
                        break
                    fi
                fi
            done
        fi

        # Confirm configuration
        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        if [ -n "$CERT_FILE" ]; then
            echo -e "  Certificate: $CERT_FILE"
        else
            echo -e "  Certificate: None configured"
        fi
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Git authentication
ask_git_auth() {
    while true; do
        # Reset for restart
        ENABLE_GIT_SSH=false
        ENABLE_GIT_HTTPS=false
        CREATE_GIT_CREDENTIALS_TEMPLATE=false

        print_section "Git Authentication"

        echo "Configure Git authentication for accessing private repositories."
        echo ""

        print_context "${BOLD}SSH authentication:\033[22m${GRAY} Uses SSH keys for Git operations. Place your SSH keys in a .ssh/ directory.
${BOLD}HTTPS authentication:\033[22m${GRAY} Uses a .git-credentials file with personal access tokens."

        # Ask about SSH
        if ask_yes_no "Do you need SSH authentication?"; then
            ENABLE_GIT_SSH=true

            # Create .ssh directory
            local build_dir=$(dirname "$OUTPUT_DOCKERFILE")
            local ssh_dir="$build_dir/.ssh"
            if [ ! -d "$ssh_dir" ]; then
                mkdir -p "$ssh_dir"
                print_success "Created .ssh/ directory in build context"
            fi
        fi

        echo ""

        # Ask about HTTPS
        if ask_yes_no "Do you need HTTPS authentication?"; then
            ENABLE_GIT_HTTPS=true

            echo ""
            if ask_yes_no "Do you already have a .git-credentials file?"; then
                print_success "HTTPS authentication will use your existing .git-credentials file"
            else
                # Create template .git-credentials file
                local build_dir=$(dirname "$OUTPUT_DOCKERFILE")
                local creds_file="$build_dir/.git-credentials"
                cat > "$creds_file" << 'EOF'
# Git credentials for HTTPS authentication
# Format: https://username:token@hostname
#
# Examples:
#   https://myuser:ghp_tokenhere@github.com
#   https://myuser:glpat-tokenhere@gitlab.com
#   https://myuser:tokenhere@bitbucket.org
#
# Add your credentials below (one per line):

EOF
                CREATE_GIT_CREDENTIALS_TEMPLATE=true
                print_success "Created template .git-credentials file in build context"
            fi
        fi

        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        local any_selected=false
        if [ "$ENABLE_GIT_SSH" = true ]; then
            echo -e "  SSH authentication: Will be configured"
            any_selected=true
        fi
        if [ "$ENABLE_GIT_HTTPS" = true ]; then
            echo -e "  HTTPS authentication: Will be configured"
            if [ "$CREATE_GIT_CREDENTIALS_TEMPLATE" = true ]; then
                echo -e "    Template .git-credentials file created"
            fi
            any_selected=true
        fi
        if [ "$any_selected" = false ]; then
            echo -e "  No Git authentication needed"
        fi
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Runtime configuration
ask_runtime_config() {
    while true; do
        print_section "Runtime Configuration"

        # Java options
        echo -e "${BOLD}JVM Options${RESET}"
        print_context "Configure JVM options for the Moderne CLI runtime. These affect memory allocation
and stack size for LST processing."
        echo "Default: -Xmx4g -Xss3m (4GB max heap, 3MB stack size)"
        echo ""

        local default_java_opts="-Xmx4g -Xss3m"
        read -p "$(echo -e "${BOLD}Java options${RESET} (press Enter for default) [${default_java_opts}]: ")" user_java_opts
        if [ -n "$user_java_opts" ]; then
            JAVA_OPTIONS="$user_java_opts"
        else
            JAVA_OPTIONS="$default_java_opts"
        fi

        # Data directory
        echo -e "\n${BOLD}Data Directory${RESET}"
        print_context "The directory where Moderne CLI stores its data, including LST artifacts
and temporary files."
        echo "Default: /var/moderne"
        echo ""

        local default_data_dir="/var/moderne"
        read -p "$(echo -e "${BOLD}Data directory${RESET} (press Enter for default) [${default_data_dir}]: ")" user_data_dir
        if [ -n "$user_data_dir" ]; then
            DATA_DIR="$user_data_dir"
        else
            DATA_DIR="$default_data_dir"
        fi

        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        echo -e "  JVM options: $JAVA_OPTIONS"
        echo -e "  Data directory: $DATA_DIR"
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Show configuration summary
show_summary() {
    print_section "Configuration Summary"

    echo -e "${BOLD}Your Dockerfile will include:${RESET}\n"

    # Always included
    echo -e "${GREEN}✓${RESET} JDK versions: ${ENABLED_JDKS[*]}"
    echo -e "${GREEN}✓${RESET} Git, curl, and essential tools"

    # Moderne CLI
    if [ "$CLI_SOURCE" = "local" ]; then
        echo -e "${GREEN}✓${RESET} Moderne CLI (from local mod.jar)"
    else
        if [ "$CLI_VERSION_TYPE" = "stable" ]; then
            echo -e "${GREEN}✓${RESET} Moderne CLI (latest stable)"
        elif [ "$CLI_VERSION_TYPE" = "staging" ]; then
            echo -e "${GREEN}✓${RESET} Moderne CLI (latest staging)"
        else
            echo -e "${GREEN}✓${RESET} Moderne CLI (version $CLI_SPECIFIC_VERSION)"
        fi
    fi

    # Build tools
    [ "$ENABLE_MAVEN" = true ] && echo -e "${GREEN}✓${RESET} Apache Maven $MAVEN_VERSION"
    [ "$ENABLE_GRADLE" = true ] && echo -e "${GREEN}✓${RESET} Gradle 8.14"
    [ "$ENABLE_BAZEL" = true ] && echo -e "${GREEN}✓${RESET} Bazel build system"

    # Development platforms & runtimes
    [ "$ENABLE_ANDROID" = true ] && echo -e "${GREEN}✓${RESET} Android SDK (platforms 25-33)"
    [ "$ENABLE_NODE" = true ] && echo -e "${GREEN}✓${RESET} Node.js 20.x"
    [ "$ENABLE_PYTHON" = true ] && echo -e "${GREEN}✓${RESET} Python 3.11"
    [ "$ENABLE_DOTNET" = true ] && echo -e "${GREEN}✓${RESET} .NET SDK 6.0 and 8.0"

    # Scalability
    [ "$ENABLE_AWS_CLI" = true ] && echo -e "${GREEN}✓${RESET} AWS CLI v2"
    [ "$ENABLE_AWS_BATCH" = true ] && echo -e "${GREEN}✓${RESET} AWS Batch support (chunk.sh)"

    # Security
    if [ -n "$CERT_FILE" ]; then
        echo -e "${GREEN}✓${RESET} Self-signed certificate: $(basename "$CERT_FILE")"
    elif [ "$CERT_FILE" = "skip" ]; then
        echo -e "${CYAN}○${RESET} Self-signed certificate support (manual configuration needed)"
    fi

    # Git authentication
    if [ "$ENABLE_GIT_SSH" = true ] || [ "$ENABLE_GIT_HTTPS" = true ]; then
        local auth_types=()
        [ "$ENABLE_GIT_SSH" = true ] && auth_types+=("SSH")
        [ "$ENABLE_GIT_HTTPS" = true ] && auth_types+=("HTTPS")
        echo -e "${GREEN}✓${RESET} Git authentication: ${auth_types[*]}"
    fi

    # Maven
    if [ -n "$MAVEN_SETTINGS_FILE" ]; then
        echo -e "${GREEN}✓${RESET} Custom Maven settings: $(basename "$MAVEN_SETTINGS_FILE")"
    elif [ "$MAVEN_SETTINGS_FILE" = "skip" ]; then
        echo -e "${CYAN}○${RESET} Maven settings support (manual configuration needed)"
    fi

    # Runtime
    echo -e "${GREEN}✓${RESET} Java options: $JAVA_OPTIONS"
    echo -e "${GREEN}✓${RESET} Data directory: $DATA_DIR"

    echo ""
}

# Helper function to get highest JDK version from enabled list
get_highest_jdk() {
    local highest=0
    for jdk in "${ENABLED_JDKS[@]}"; do
        if [ "$jdk" -gt "$highest" ]; then
            highest="$jdk"
        fi
    done
    echo "$highest"
}

# Generate base Dockerfile with selected JDKs only
generate_base_section() {
    local output="$1"
    local highest_jdk=$(get_highest_jdk)

    # Generate FROM statements for selected JDKs
    for jdk in "${ENABLED_JDKS[@]}"; do
        echo "FROM eclipse-temurin:${jdk}-jdk AS jdk${jdk}" >> "$output"
    done
    echo "" >> "$output"

    # Install dependencies (using highest JDK as base)
    echo "# Install dependencies for \`mod\` cli" >> "$output"
    echo "FROM jdk${highest_jdk} AS dependencies" >> "$output"
    echo "RUN apt-get -y update && apt-get install -y curl git git-lfs jq libxml2-utils unzip wget zip vim && git lfs install" >> "$output"
    echo "" >> "$output"

    # Copy selected JDK versions
    echo "# Gather various JDK versions" >> "$output"
    for jdk in "${ENABLED_JDKS[@]}"; do
        echo "COPY --from=jdk${jdk} /opt/java/openjdk /usr/lib/jvm/temurin-${jdk}-jdk" >> "$output"
    done
}

# Generate certificate configuration for selected JDKs only
generate_certs_section() {
    local output="$1"
    local cert_basename="$2"

    echo "# Configure trust store for self-signed certificates" >> "$output"
    echo "COPY ${cert_basename} /root/${cert_basename}" >> "$output"

    # Add keytool imports for each enabled JDK
    for jdk in "${ENABLED_JDKS[@]}"; do
        if [ "$jdk" = "8" ]; then
            # JDK 8 has cacerts in a different location
            echo "RUN /usr/lib/jvm/temurin-${jdk}-jdk/bin/keytool -import -noprompt -file /root/${cert_basename} -keystore /usr/lib/jvm/temurin-${jdk}-jdk/jre/lib/security/cacerts -storepass changeit" >> "$output"
        else
            echo "RUN /usr/lib/jvm/temurin-${jdk}-jdk/bin/keytool -import -noprompt -file /root/${cert_basename} -keystore /usr/lib/jvm/temurin-${jdk}-jdk/lib/security/cacerts -storepass changeit" >> "$output"
        fi
    done

    echo "RUN mod config http trust-store edit java-home" >> "$output"
    echo "" >> "$output"
    echo "# mvnw scripts in maven projects may attempt to download maven-wrapper jars using wget." >> "$output"
    echo "RUN echo \"ca_certificate = /root/${cert_basename}\" > /root/.wgetrc" >> "$output"
}

# Generate the Dockerfile
generate_dockerfile() {
    print_section "Generating Dockerfile"

    local output="$OUTPUT_DOCKERFILE"

    # Check if templates exist
    if [ ! -d "$TEMPLATES_DIR" ]; then
        print_error "Templates directory not found: $TEMPLATES_DIR"
        exit 1
    fi

    # Start fresh
    > "$output"

    # Generate base section with selected JDKs
    generate_base_section "$output"
    echo "" >> "$output"

    # Add Moderne CLI (download or local)
    if [ "$CLI_SOURCE" = "local" ]; then
        sed -e "s|{{CLI_JAR_PATH}}|$CLI_JAR_PATH|g" \
            "$TEMPLATES_DIR/00-modcli-local.Dockerfile" >> "$output"
    else
        # Download - replace placeholders for stage and version
        local cli_stage=""
        local cli_version=""

        if [ "$CLI_VERSION_TYPE" = "staging" ]; then
            cli_stage="staging"
        elif [ "$CLI_VERSION_TYPE" = "specific" ]; then
            cli_version="$CLI_SPECIFIC_VERSION"
        fi
        # For stable, both remain empty (script will download latest stable)

        sed -e "s|{{CLI_STAGE}}|$cli_stage|g" \
            -e "s|{{CLI_VERSION}}|$cli_version|g" \
            "$TEMPLATES_DIR/00-modcli-download.Dockerfile" >> "$output"
    fi
    echo "" >> "$output"

    # Add build tools
    if [ "$ENABLE_GRADLE" = true ]; then
        cat "$TEMPLATES_DIR/10-gradle.Dockerfile" >> "$output"
        echo "" >> "$output"
    fi

    if [ "$ENABLE_MAVEN" = true ]; then
        # Replace hardcoded Maven version with user's chosen version
        sed "s/ENV MAVEN_VERSION=.*/ENV MAVEN_VERSION=$MAVEN_VERSION/" "$TEMPLATES_DIR/11-maven.Dockerfile" >> "$output"
        echo "" >> "$output"
    fi

    # Add language runtimes
    if [ "$ENABLE_ANDROID" = true ]; then
        cat "$TEMPLATES_DIR/20-android.Dockerfile" >> "$output"
        echo "" >> "$output"
    fi

    if [ "$ENABLE_BAZEL" = true ]; then
        cat "$TEMPLATES_DIR/21-bazel.Dockerfile" >> "$output"
        echo "" >> "$output"
    fi

    if [ "$ENABLE_NODE" = true ]; then
        cat "$TEMPLATES_DIR/22-node.Dockerfile" >> "$output"
        echo "" >> "$output"
    fi

    if [ "$ENABLE_PYTHON" = true ]; then
        cat "$TEMPLATES_DIR/23-python.Dockerfile" >> "$output"
        echo "" >> "$output"
    fi

    if [ "$ENABLE_DOTNET" = true ]; then
        cat "$TEMPLATES_DIR/24-dotnet.Dockerfile" >> "$output"
        echo "" >> "$output"
    fi

    # Add AWS CLI
    if [ "$ENABLE_AWS_CLI" = true ]; then
        cat "$TEMPLATES_DIR/15-aws-cli.Dockerfile" >> "$output"
        echo "" >> "$output"
    fi

    # Add AWS Batch support
    if [ "$ENABLE_AWS_BATCH" = true ]; then
        cat "$TEMPLATES_DIR/16-aws-batch.Dockerfile" >> "$output"
        echo "" >> "$output"
    fi

    # Add Maven settings
    if [ -n "$MAVEN_SETTINGS_FILE" ]; then
        # Replace placeholder with actual filename
        local settings_basename=$(basename "$MAVEN_SETTINGS_FILE")
        sed "s|{{SETTINGS_FILE}}|$settings_basename|g" "$TEMPLATES_DIR/32-maven-settings.Dockerfile" >> "$output"
        echo "" >> "$output"
    fi

    # Add certificate configuration
    if [ -n "$CERT_FILE" ]; then
        # Generate cert section with only selected JDKs
        local cert_basename=$(basename "$CERT_FILE")
        generate_certs_section "$output" "$cert_basename"
        echo "" >> "$output"
    fi

    # Add Git authentication configuration
    if [ "$ENABLE_GIT_SSH" = true ] || [ "$ENABLE_GIT_HTTPS" = true ]; then
        echo "# Git authentication" >> "$output"

        if [ "$ENABLE_GIT_SSH" = true ]; then
            echo "COPY .ssh/ /root/.ssh/" >> "$output"
            echo "RUN chmod 700 /root/.ssh && chmod 600 /root/.ssh/*" >> "$output"
        fi

        if [ "$ENABLE_GIT_HTTPS" = true ]; then
            echo "COPY .git-credentials /root/.git-credentials" >> "$output"
            echo "RUN chmod 600 /root/.git-credentials && git config --global credential.helper store" >> "$output"
        fi

        echo "" >> "$output"
    fi

    # Always include runner (with placeholder replacement)
    sed -e "s|{{JAVA_OPTIONS}}|$JAVA_OPTIONS|g" \
        -e "s|{{DATA_DIR}}|$DATA_DIR|g" \
        "$TEMPLATES_DIR/99-runner.Dockerfile" >> "$output"

    print_success "Dockerfile generated: $output"
}

# Show next steps
show_next_steps() {
    print_header "Setup Complete!"

    echo -e "${GREEN}${BOLD}Your customized Dockerfile is ready!${RESET}"
    echo ""
    echo -e "${BOLD}Generated file:${RESET} ${CYAN}$OUTPUT_DOCKERFILE${RESET}"
    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo ""

    local step=1

    # Certificate file needs to be in place
    if [ -n "$CERT_FILE" ]; then
        echo -e "$step. ${YELLOW}Copy certificate file:${RESET}"
        echo -e "   ${CYAN}cp $CERT_FILE $(dirname $OUTPUT_DOCKERFILE)/$(basename "$CERT_FILE")${RESET}"
        echo ""
        ((step++))
    fi

    # Maven settings file needs to be in place
    if [ -n "$MAVEN_SETTINGS_FILE" ]; then
        echo -e "$step. ${YELLOW}Copy Maven settings file:${RESET}"
        echo -e "   ${CYAN}cp $MAVEN_SETTINGS_FILE $(dirname $OUTPUT_DOCKERFILE)/$(basename "$MAVEN_SETTINGS_FILE")${RESET}"
        echo ""
        ((step++))
    fi

    # Git authentication setup
    if [ "$ENABLE_GIT_SSH" = true ]; then
        echo -e "$step. ${YELLOW}Add SSH keys to .ssh/ directory:${RESET}"
        echo -e "   Copy your SSH private keys to $(dirname $OUTPUT_DOCKERFILE)/.ssh/"
        echo -e "   ${GRAY}Example: cp ~/.ssh/id_rsa $(dirname $OUTPUT_DOCKERFILE)/.ssh/${RESET}"
        echo ""
        ((step++))
    fi

    if [ "$CREATE_GIT_CREDENTIALS_TEMPLATE" = true ]; then
        echo -e "$step. ${YELLOW}Fill in .git-credentials file:${RESET}"
        echo -e "   Edit $(dirname $OUTPUT_DOCKERFILE)/.git-credentials and add your credentials"
        echo -e "   ${GRAY}Format: https://username:token@hostname${RESET}"
        echo ""
        ((step++))
    elif [ "$ENABLE_GIT_HTTPS" = true ]; then
        echo -e "$step. ${YELLOW}Copy .git-credentials file:${RESET}"
        echo -e "   ${CYAN}cp /path/to/your/.git-credentials $(dirname $OUTPUT_DOCKERFILE)/${RESET}"
        echo ""
        ((step++))
    fi

    echo -e "$step. ${BOLD}Build your container image:${RESET}"
    echo -e "   ${CYAN}docker build -f $OUTPUT_DOCKERFILE -t moderne/mass-ingest:latest .${RESET}"
    echo ""
    ((step++))

    echo -e "$step. ${BOLD}Run the container:${RESET}"
    echo ""
    echo "   ${BOLD}For Moderne SaaS:${RESET}"
    echo -e "   ${CYAN}docker run --rm \\"
    echo "     -e MODERNE_TOKEN=your_token \\"
    echo "     -e MODERNE_TENANT=your_tenant \\"
    echo -e "     moderne/mass-ingest:latest${RESET}"
    echo ""
    echo "   ${BOLD}For artifact repository:${RESET}"
    echo -e "   ${CYAN}docker run --rm \\"
    echo "     -e PUBLISH_URL=https://your-artifactory.com \\"
    echo "     -e PUBLISH_TOKEN=your_token \\"
    echo -e "     moderne/mass-ingest:latest${RESET}"
    echo ""
    echo "   ${GRAY}See documentation for additional options (volumes, networking, etc.)${RESET}"
    echo ""

    echo -e "${BOLD}Documentation:${RESET}"
    echo "  • Moderne CLI: https://docs.moderne.io/user-documentation/moderne-cli"
    echo "  • Mass Ingest: https://github.com/moderneinc/mass-ingest-example"
    echo ""

    echo -e "${GREEN}${BOLD}Happy ingesting! 🚀${RESET}\n"
}

# Main flow
main() {
    show_welcome
    ask_jdk_versions
    ask_modcli_config
    ask_maven_build_config
    ask_gradle_build_config
    ask_other_build_tools
    ask_language_runtimes
    ask_scalability_options
    ask_security_config
    ask_git_auth
    ask_runtime_config
    show_summary

    echo ""
    if ask_yes_no "Generate Dockerfile with this configuration?"; then
        generate_dockerfile
        show_next_steps
    else
        echo -e "\n${YELLOW}Dockerfile generation cancelled.${RESET}\n"
        exit 0
    fi
}

# Only run main if not being sourced for testing
if [ -z "$SKIP_MAIN" ]; then
    main "$@"
fi
