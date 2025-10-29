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

# Git authentication (using parallel arrays for bash 3.2 compatibility)
SCM_PROVIDERS=()
GIT_AUTH_METHODS=()
GIT_AUTH_FILES=()

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
    echo -e "\n${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}${BOLD}$1${RESET}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

print_section() {
    echo -e "\n${CYAN}${BOLD}▶ $1${RESET}\n"
}

print_context() {
    echo -e "${YELLOW}ℹ  $1${RESET}\n"
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
    print_header "Moderne Mass Ingest - Dockerfile Generator"

    echo -e "${BOLD}Welcome!${RESET}"
    echo ""
    echo "This interactive questionnaire will help you create a customized Dockerfile for your"
    echo "mass-ingest environment. We'll ask about your repository landscape to ensure the"
    echo "container has everything needed to build LSTs successfully."
    echo ""
    echo -e "${CYAN}What to expect:${RESET}"
    echo "  • Questions about JDK versions and build tools"
    echo "  • Language runtime requirements"
    echo "  • Security and certificate configuration"
    echo "  • Maven customization options"
    echo ""
    echo -e "${CYAN}Estimated time:${RESET} 2-3 minutes"
    echo ""

    read -p "$(echo -e "${BOLD}Press Enter to begin...${RESET}")"
    clear
}

# JDK selection
ask_jdk_versions() {
    while true; do
        print_section "JDK Versions"

        print_context "The Moderne CLI needs access to all JDK versions used by your Java projects to
successfully build LSTs. We'll install JDK 8, 11, 17, 21, and 25 by default.

${BOLD}Why all versions?${RESET} This ensures compatibility with projects targeting any Java version.
The additional disk space (~2GB) is worth avoiding build failures.

${BOLD}Safe to skip:${RESET} If you're certain your projects only use specific JDK versions, you can
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

${BOLD}Download from Maven Central:${RESET} Automatically fetches the specified version during build.
${BOLD}Supply JAR directly:${RESET} You provide mod.jar in the build context (faster builds, version control)."

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

${BOLD}Latest stable:${RESET} Recommended for production use.
${BOLD}Latest staging:${RESET} Pre-release version with newest features.
${BOLD}Specific version:${RESET} Pin to a known version for reproducibility."

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

        print_context "Maven is a popular build tool for Java projects.

${BOLD}Maven wrappers (mvnw):${RESET} Many projects include wrapper scripts that don't require Maven to be pre-installed.
${BOLD}Pre-installed Maven:${RESET} Older projects or specific scenarios may need Maven available globally."

        if ! ask_yes_no "Do any of your repositories use Maven?"; then
            clear
            return
        fi

        echo ""
        if ask_yes_no "Do you need Maven pre-installed? (Say 'no' if all projects use mvnw wrapper)"; then
            ENABLE_MAVEN=true

            # Ask for Maven version
            read -p "$(echo -e "${BOLD}Maven version${RESET} (press Enter for default) [$MAVEN_VERSION]: ")" user_maven_version
            if [ -n "$user_maven_version" ]; then
                MAVEN_VERSION="$user_maven_version"
            fi
            print_success "Maven $MAVEN_VERSION will be installed"
        else
            print_success "Maven will not be installed (projects will use wrappers)"
        fi

        # Maven settings.xml configuration
        echo ""
        echo -e "${BOLD}Maven Settings${RESET}"
        print_context "If your Maven builds require custom settings (private repositories, mirrors, profiles,
authentication), you can provide a settings.xml file.

${BOLD}What this does:${RESET} Copies your settings.xml to /root/.m2/ and configures mod CLI to use it."

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
    print_section "Gradle Configuration"

    print_context "Gradle is a popular build tool for Java and Kotlin projects.

${BOLD}Gradle wrappers (gradlew):${RESET} Many projects include wrapper scripts that don't require Gradle to be pre-installed.
${BOLD}Pre-installed Gradle:${RESET} Older projects or specific scenarios may need Gradle 8.14 available globally."

    if ! ask_yes_no "Do any of your repositories use Gradle?"; then
        clear
        return
    fi

    echo ""
    if ask_yes_no "Do you need Gradle pre-installed? (Say 'no' if all projects use gradlew wrapper)"; then
        ENABLE_GRADLE=true
        print_success "Gradle 8.14 will be installed"
    else
        print_success "Gradle will not be installed (projects will use wrappers)"
    fi

    clear
}

# Other build tools
ask_other_build_tools() {
    print_section "Other Build Tools"

    print_context "Some projects use specialized build tools beyond Maven and Gradle."

    # Bazel
    echo -e "${BOLD}Bazel${RESET}"
    echo "Google's build system, commonly used in monorepos and large-scale projects."
    if ask_yes_no "Do you use Bazel?"; then
        ENABLE_BAZEL=true
        print_success "Bazel will be installed"
    fi

    clear
}

# Development platforms & runtimes
ask_language_runtimes() {
    print_section "Development Platforms & Runtimes"

    print_context "While the Moderne CLI primarily processes Java/Kotlin projects, your repositories
may have multi-language components that require additional runtimes for successful builds.

Answer 'yes' if any of your repositories need these runtimes."

    # Android
    echo -e "${BOLD}Android SDK${RESET}"
    echo "Required for Android applications. Installs API platforms 25-33 (~5GB)."
    if ask_yes_no "Do you have Android projects?"; then
        ENABLE_ANDROID=true
        print_success "Android SDK will be installed"
    fi

    # Node.js
    echo -e "\n${BOLD}Node.js${RESET}"
    echo "Required for projects with frontend components or JavaScript/TypeScript code."
    if ask_yes_no "Do you need Node.js?"; then
        ENABLE_NODE=true
        print_success "Node.js 20.x will be installed"
    fi

    # Python
    echo -e "\n${BOLD}Python 3.11${RESET}"
    echo "Needed for Python projects or build scripts with Python dependencies."
    if ask_yes_no "Do you need Python?"; then
        ENABLE_PYTHON=true
        print_success "Python 3.11 will be installed"
    fi

    # .NET
    echo -e "\n${BOLD}.NET SDK${RESET}"
    echo "Required for .NET/C# projects. Installs .NET 6.0 and 8.0 SDKs."
    if ask_yes_no "Do you have .NET projects?"; then
        ENABLE_DOTNET=true
        print_success ".NET SDK 6.0 and 8.0 will be installed"
    fi

    clear
}

# Scalability options
ask_scalability_options() {
    print_section "Scalability Options"

    # AWS CLI for S3 URLs
    echo -e "\n${BOLD}AWS CLI for S3 URLs${RESET}"
    print_context "If your repositories are stored in S3 or you need to access S3 resources,
the AWS CLI can be installed in the container.

${BOLD}What this does:${RESET} Installs AWS CLI v2, allowing you to use S3 URLs in your repos.csv
and access AWS resources during processing."

    if ask_yes_no "Do you need AWS CLI?"; then
        ENABLE_AWS_CLI=true
        print_success "AWS CLI will be installed"
    fi

    # AWS Batch support
    echo -e "\n${BOLD}AWS Batch Support${RESET}"
    print_context "AWS Batch allows you to run containerized jobs at scale. This includes
the chunk.sh script that helps divide workloads across multiple parallel jobs.

${BOLD}What this does:${RESET} Includes chunk.sh script for job parallelization in AWS Batch environments."

    if ask_yes_no "Do you need AWS Batch support?"; then
        ENABLE_AWS_BATCH=true
        print_success "AWS Batch support (chunk.sh) will be included"
    fi

    clear
}

# Security configuration
ask_security_config() {
    while true; do
        # Reset for restart
        CERT_FILE=""

        print_section "Security Configuration"

        # Self-signed certificates
        print_context "If your artifact repository, source control, or Moderne tenant uses self-signed
certificates, you'll need to import them into the JVM trust stores.

${BOLD}What this does:${RESET} Imports your certificate into all JDK keystores and configures wget
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
        # Reset arrays for restart
        SCM_PROVIDERS=()
        GIT_AUTH_METHODS=()
        GIT_AUTH_FILES=()

        print_section "Git Authentication"

        print_context "Configure Git authentication for your source control providers. You can use HTTPS
(with personal access tokens) or SSH (with SSH keys) for each provider."

        if ! ask_yes_no "Do you need to configure Git authentication?"; then
            clear
            return
        fi

        # Loop to add providers
        while true; do
            echo ""
            ask_choice "Which provider would you like to configure?" \
                "GitHub" \
                "GitLab" \
                "Bitbucket Data Center" \
                "Bitbucket Cloud" \
                "Azure DevOps"

            local provider=""
            local provider_name=""
            case $CHOICE_RESULT in
                0) provider="github"; provider_name="GitHub" ;;
                1) provider="gitlab"; provider_name="GitLab" ;;
                2) provider="bitbucket-dc"; provider_name="Bitbucket Data Center" ;;
                3) provider="bitbucket-cloud"; provider_name="Bitbucket Cloud" ;;
                4) provider="azure-devops"; provider_name="Azure DevOps" ;;
            esac

            # Check if already configured
            local already_configured=false
            for configured_provider in "${SCM_PROVIDERS[@]}"; do
                if [ "$configured_provider" = "$provider" ]; then
                    already_configured=true
                    break
                fi
            done

            if [ "$already_configured" = true ]; then
                echo -e "${YELLOW}$provider_name is already configured. Skipping...${RESET}"
            else
                # Add provider
                SCM_PROVIDERS+=("$provider")

                # Ask for authentication method
                echo ""
                if ask_yes_no "Use SSH authentication for $provider_name? (No = HTTPS with PAT)"; then
                    GIT_AUTH_METHODS+=("ssh")

                    # Ask for SSH key file
                    local ssh_key=""
                    ssh_key=$(ask_optional_path "Enter path to SSH private key (e.g., ~/.ssh/id_rsa)")

                    if [ -n "$ssh_key" ]; then
                        GIT_AUTH_FILES+=("$ssh_key")
                        print_success "Configured $provider_name with SSH key: $ssh_key"
                    else
                        GIT_AUTH_FILES+=("")
                        echo -e "${YELLOW}Note: SSH key configuration for $provider_name will be included as a comment.${RESET}"
                        echo -e "${YELLOW}      You'll need to customize it manually.${RESET}"
                    fi
                else
                    GIT_AUTH_METHODS+=("https")
                    GIT_AUTH_FILES+=("")
                    print_success "Configured $provider_name with HTTPS (.git-credentials file, load at runtime)"
                fi
            fi

            # Ask if they want to configure another
            echo ""
            if ! ask_yes_no "Configure another provider?"; then
                break
            fi
        done

        # Confirm configuration
        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        if [ ${#SCM_PROVIDERS[@]} -eq 0 ]; then
            echo -e "  Git authentication: None configured"
        else
            echo -e "  Git authentication:"
            for i in "${!SCM_PROVIDERS[@]}"; do
                local provider="${SCM_PROVIDERS[$i]}"
                local method="${GIT_AUTH_METHODS[$i]}"
                local file="${GIT_AUTH_FILES[$i]}"

                # Convert provider code to display name
                local display_name=""
                case "$provider" in
                    github) display_name="GitHub" ;;
                    gitlab) display_name="GitLab" ;;
                    bitbucket-dc) display_name="Bitbucket Data Center" ;;
                    bitbucket-cloud) display_name="Bitbucket Cloud" ;;
                    azure-devops) display_name="Azure DevOps" ;;
                esac

                if [ "$method" = "ssh" ]; then
                    if [ -n "$file" ]; then
                        echo -e "    - $display_name: SSH ($file)"
                    else
                        echo -e "    - $display_name: SSH (no key file specified)"
                    fi
                else
                    echo -e "    - $display_name: HTTPS (.git-credentials)"
                fi
            done
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
    print_section "Runtime Configuration"

    # Java options
    echo -e "${BOLD}JVM Options${RESET}"
    print_context "Configure JVM options for the Moderne CLI runtime. These affect memory allocation
and stack size for LST processing.

${BOLD}Default:${RESET} -Xmx4g -Xss3m (4GB max heap, 3MB stack size)"

    local default_java_opts="-Xmx4g -Xss3m"
    read -p "$(echo -e "${BOLD}Java options${RESET} (press Enter for default) [${default_java_opts}]: ")" user_java_opts
    if [ -n "$user_java_opts" ]; then
        JAVA_OPTIONS="$user_java_opts"
        print_success "Using custom Java options: $JAVA_OPTIONS"
    else
        JAVA_OPTIONS="$default_java_opts"
        print_success "Using default Java options: $JAVA_OPTIONS"
    fi

    # Data directory
    echo -e "\n${BOLD}Data Directory${RESET}"
    print_context "The directory where Moderne CLI stores its data, including LST artifacts
and temporary files.

${BOLD}Default:${RESET} /var/moderne"

    local default_data_dir="/var/moderne"
    read -p "$(echo -e "${BOLD}Data directory${RESET} (press Enter for default) [${default_data_dir}]: ")" user_data_dir
    if [ -n "$user_data_dir" ]; then
        DATA_DIR="$user_data_dir"
        print_success "Using custom data directory: $DATA_DIR"
    else
        DATA_DIR="$default_data_dir"
        print_success "Using default data directory: $DATA_DIR"
    fi

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
    if [ ${#SCM_PROVIDERS[@]} -gt 0 ]; then
        echo -e "${GREEN}✓${RESET} Git authentication for: ${SCM_PROVIDERS[*]}"
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
    if [ ${#SCM_PROVIDERS[@]} -gt 0 ]; then
        echo "# Git authentication for SCM providers" >> "$output"
        for i in "${!SCM_PROVIDERS[@]}"; do
            local provider="${SCM_PROVIDERS[$i]}"
            local auth_method="${GIT_AUTH_METHODS[$i]}"
            if [ "$auth_method" = "ssh" ]; then
                local ssh_key_file="${GIT_AUTH_FILES[$i]}"
                if [ -n "$ssh_key_file" ]; then
                    local key_basename=$(basename "$ssh_key_file")
                    echo "# SSH authentication for $provider" >> "$output"
                    echo "# COPY $key_basename /root/.ssh/id_rsa" >> "$output"
                    echo "# RUN chmod 600 /root/.ssh/id_rsa" >> "$output"
                else
                    echo "# TODO: Configure SSH key for $provider" >> "$output"
                fi
            else
                echo "# HTTPS authentication for $provider (configure via environment variables)" >> "$output"
            fi
        done
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

    echo -e "$step. ${BOLD}Build your container image:${RESET}"
    echo -e "   ${CYAN}docker build -f $OUTPUT_DOCKERFILE -t moderne/mass-ingest:latest .${RESET}"
    echo ""
    ((step++))

    echo -e "$step. ${BOLD}Run the container:${RESET}"
    echo "   See the mass-ingest-example documentation for detailed run instructions"
    echo -e "   ${CYAN}https://github.com/moderneinc/mass-ingest-example${RESET}"
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
