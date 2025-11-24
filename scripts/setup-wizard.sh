#!/bin/bash

set -e

# TODO: Future enhancement - Session resume capability
# Save wizard state to .wizard-session file and allow resuming from checkpoints
# Delete session file on successful completion
# On startup, detect and offer to resume from saved session

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_FETCHERS_DIR="$SCRIPT_DIR/repository-fetchers"
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

# ============================================================================
# Configuration storage - repos.csv wizard
# ============================================================================

# Output file
OUTPUT_FILE="repos.csv"
USE_HIERARCHICAL_ORGS=false  # Options: "none", false (simple), or true (hierarchical)
NORMALIZE_CSV=false
REPOS_CSV_REUSED=false  # Track if we reused existing repos.csv

# Temp directory for CSV files
TEMP_DIR=""

# SCM provider selection
ENABLE_GITHUB=false
ENABLE_GITLAB=false
ENABLE_AZURE_DEVOPS=false
ENABLE_BITBUCKET_CLOUD=false
ENABLE_BITBUCKET_DATA_CENTER=false

# GitHub configuration
GITHUB_ORGS=()
GITHUB_URL="https://github.com"

# GitLab configuration
GITLAB_GROUPS=()
GITLAB_DOMAIN="https://gitlab.com"

# Azure DevOps configuration
AZURE_ORGS=()
AZURE_PROJECTS=()

# Bitbucket Cloud configuration
BITBUCKET_CLOUD_WORKSPACES=()

# Bitbucket Data Center configuration
BITBUCKET_DC_PROJECTS=()
BITBUCKET_DC_URL=""

# Track fetch results and repository sources
declare -a FETCH_RESULTS
declare -a REPO_SOURCES

# ============================================================================
# Configuration storage - Dockerfile wizard
# ============================================================================

# Enabled JDKs
ENABLED_JDKS=("8" "11" "17" "21" "25")

# Moderne CLI
# Preserve existing environment variables, set defaults only if not set
CLI_SOURCE="${CLI_SOURCE:-download}"  # or "local"
CLI_VERSION_TYPE="${CLI_VERSION_TYPE:-stable}"  # or "staging" or "specific"
CLI_SPECIFIC_VERSION="${CLI_SPECIFIC_VERSION:-}"
CLI_JAR_PATH="${CLI_JAR_PATH:-}"
MODERNE_TENANT="${MODERNE_TENANT:-}"
MODERNE_TOKEN="${MODERNE_TOKEN:-}"

# Artifact repository (preserve environment variables)
PUBLISH_URL="${PUBLISH_URL:-}"
PUBLISH_AUTH_METHOD="${PUBLISH_AUTH_METHOD:-userpass}"  # or "token"
PUBLISH_USER="${PUBLISH_USER:-}"
PUBLISH_PASSWORD="${PUBLISH_PASSWORD:-}"
PUBLISH_TOKEN="${PUBLISH_TOKEN:-}"

# Build tools
ENABLE_MAVEN=false
MAVEN_VERSION="3.9.11"
ENABLE_GRADLE=false
GRADLE_VERSION="8.14"
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
JAVA_OPTIONS="-XX:MaxRAMPercentage=60.0 -Xss3m"
DATA_DIR="/var/moderne"

# Helper
CHOICE_RESULT=0

# Output files
OUTPUT_DOCKERFILE="Dockerfile"
GENERATE_DOCKER_COMPOSE=false
OUTPUT_DOCKER_COMPOSE="docker-compose.yml"
OUTPUT_ENV=".env"
DATA_MOUNT_DIR=""

# ============================================================================
# Helper functions (merged from both scripts)
# ============================================================================

print_header() {
    echo -e "${CYAN}${BOLD}$1${RESET}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

print_section() {
    local title="$1"
    local progress="$2"  # Optional: "Step X/Y" or similar

    if [ -n "$progress" ]; then
        echo -e "\n${CYAN}[$progress]${RESET} ${CYAN}${BOLD}▶ $title${RESET}\n"
    else
        echo -e "\n${CYAN}${BOLD}▶ $title${RESET}\n"
    fi
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

print_warning() {
    echo -e "${YELLOW}⚠ $1${RESET}"
}

ask_yes_no() {
    local prompt="$1"
    local yes_label="${2:-Yes, continue}"
    local no_label="${3:-No, redo this section}"
    local selected=0
    local key

    # Temporarily disable exit-on-error for interactive input
    set +e

    # Show prompt
    echo -e "${BOLD}$prompt${RESET}"
    echo ""

    # Function to draw menu
    draw_menu() {
        if [ $selected -eq 0 ]; then
            echo -e "  ${CYAN}▶${RESET} ${BOLD}$yes_label${RESET}"
            echo -e "    $no_label"
        else
            echo -e "    $yes_label"
            echo -e "  ${CYAN}▶${RESET} ${BOLD}$no_label${RESET}"
        fi
        echo ""
        echo -e "${GRAY}(Use ↑/↓ arrows, Enter to select)${RESET}"
    }

    # Initial draw
    draw_menu

    # Read keys and navigate
    while true; do
        read -rsn1 key

        if [[ $key == "" ]]; then
            # Enter key pressed
            echo "" # newline after selection
            set -e  # Re-enable exit-on-error
            if [ $selected -eq 0 ]; then
                return 0  # Yes
            else
                return 1  # No
            fi
        elif [[ $key == $'\x1b' ]]; then
            read -rsn2 key

            case $key in
                '[A'|'[B') # Up or Down arrow (toggle between 2 options)
                    selected=$((1 - selected))
                    ;;
            esac

            # Clear previous menu and redraw
            echo -ne "\033[1A\033[2K" # Clear hint line
            echo -ne "\033[1A\033[2K" # Clear empty line
            echo -ne "\033[1A\033[2K" # Clear "No"
            echo -ne "\033[1A\033[2K" # Clear "Yes"

            draw_menu
        fi
    done
}

ask_question() {
    local prompt="$1"
    local response

    read -p "$(echo -e "${BOLD}$prompt${RESET}: ")" response
    response=$(clean_value "$response")
    echo "$response"
}

# Wait for Enter key (ignore other keys like arrows)
wait_for_enter() {
    local prompt="${1:-Press Enter to continue...}"
    echo -ne "${BOLD}$prompt${RESET}"

    # Wait for Enter, ignore other keys (no echo)
    while true; do
        read -rsn1 key
        if [[ $key == "" ]]; then
            echo "" # Add newline after Enter is pressed
            break
        fi
    done
}

# Check if a value is an environment variable reference
is_env_var_reference() {
    local value="$1"
    [[ "$value" =~ ^\$\{[A-Z_][A-Z0-9_]*\}$ ]]
}

# Expand environment variable reference to its actual value
expand_env_var() {
    local value="$1"
    if is_env_var_reference "$value"; then
        # Extract the variable name from ${VAR_NAME}
        # Remove ${ from start and } from end
        local var_name="${value#\$\{}"
        var_name="${var_name%\}}"
        # Use printenv to get the actual environment variable (not shadowed by shell vars)
        # Don't fail if variable doesn't exist (returns empty string instead)
        printenv "$var_name" 2>/dev/null || true
    else
        echo "$value"
    fi
}

# Ask for secret or env var reference (returns literal ${VAR} without expanding)
ask_secret_or_env_var_ref() {
    local prompt="$1"
    local value
    local selected=0
    local key

    # Temporarily disable exit-on-error for interactive input
    set +e

    echo "" >&2

    # Show selection menu
    echo -e "${BOLD}How do you want to provide this?${RESET}" >&2
    echo "" >&2

    # Function to draw menu
    draw_menu() {
        if [ $selected -eq 0 ]; then
            echo -e "  ${CYAN}▶${RESET} ${BOLD}Enter secret directly${RESET}" >&2
            echo -e "    Use environment variable" >&2
        else
            echo -e "    Enter secret directly" >&2
            echo -e "  ${CYAN}▶${RESET} ${BOLD}Use environment variable${RESET}" >&2
        fi
        echo "" >&2
        echo -e "${GRAY}(Use ↑/↓ arrows, Enter to select)${RESET}" >&2
    }

    # Initial draw
    draw_menu

    # Read keys and navigate
    while true; do
        read -rsn1 key

        if [[ $key == "" ]]; then
            # Enter key pressed
            echo "" >&2 # newline after selection

            # Clear menu
            echo -ne "\033[1A\033[2K" >&2 # Clear hint line
            echo -ne "\033[1A\033[2K" >&2 # Clear empty line
            echo -ne "\033[1A\033[2K" >&2 # Clear option 2
            echo -ne "\033[1A\033[2K" >&2 # Clear option 1
            echo -ne "\033[1A\033[2K" >&2 # Clear empty line after prompt
            echo -ne "\033[1A\033[2K" >&2 # Clear prompt

            break
        elif [[ $key == $'\x1b' ]]; then
            read -rsn2 key

            case $key in
                '[A'|'[B') # Up or Down arrow
                    selected=$((1 - selected))
                    ;;
            esac

            # Clear previous menu and redraw
            echo -ne "\033[1A\033[2K" >&2
            echo -ne "\033[1A\033[2K" >&2
            echo -ne "\033[1A\033[2K" >&2
            echo -ne "\033[1A\033[2K" >&2

            draw_menu
        fi
    done

    if [ $selected -eq 1 ]; then
        # Use environment variable
        while true; do
            read -p "$(echo -e "${BOLD}Environment variable name${RESET}: ")" value
            value=$(clean_value "$value")

            if [ -z "$value" ]; then
                echo -e "${RED}Environment variable name cannot be empty.${RESET}" >&2
                continue
            fi

            # Normalize to ${VAR_NAME} format
            local var_name=$(echo "$value" | sed 's/^\${\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)}\{0,1\}$/\1/')

            if [ -n "$var_name" ]; then
                echo "\${$var_name}"
                set -e  # Re-enable exit-on-error
                return
            fi
            echo -e "${RED}Invalid environment variable name. Use alphanumeric characters and underscores.${RESET}" >&2
        done
    else
        # Enter secret directly
        while true; do
            read -s -p "$(echo -e "${BOLD}$prompt${RESET}: ")" value
            echo "" >&2  # newline after hidden input
            value=$(clean_value "$value")
            if [ -n "$value" ]; then
                echo "$value"
                set -e  # Re-enable exit-on-error
                return
            fi
            echo -e "${RED}$prompt cannot be empty.${RESET}" >&2
        done
    fi
}

# Ask for secret or env var, clean and expand it (most common usage)
ask_secret_or_env_var() {
    local prompt="$1"
    local value
    value=$(ask_secret_or_env_var_ref "$prompt")
    value=$(clean_value "$value")
    value=$(expand_env_var "$value")
    echo "$value"
}

# Ask for input or environment variable reference (non-secret fields)
ask_input_or_env_var() {
    local prompt="$1"
    local value
    local selected=0
    local key

    # Temporarily disable exit-on-error for interactive input
    set +e

    echo "" >&2

    # Show selection menu
    echo -e "${BOLD}How do you want to provide this?${RESET}" >&2
    echo "" >&2

    # Function to draw menu
    draw_menu() {
        if [ $selected -eq 0 ]; then
            echo -e "  ${CYAN}▶${RESET} ${BOLD}Enter value directly${RESET}" >&2
            echo -e "    Use environment variable" >&2
        else
            echo -e "    Enter value directly" >&2
            echo -e "  ${CYAN}▶${RESET} ${BOLD}Use environment variable${RESET}" >&2
        fi
        echo "" >&2
        echo -e "${GRAY}(Use ↑/↓ arrows, Enter to select)${RESET}" >&2
    }

    # Initial draw
    draw_menu

    # Read keys and navigate
    while true; do
        read -rsn1 key

        if [[ $key == "" ]]; then
            # Enter key pressed
            echo "" >&2 # newline after selection

            # Clear menu
            echo -ne "\033[1A\033[2K" >&2 # Clear hint line
            echo -ne "\033[1A\033[2K" >&2 # Clear empty line
            echo -ne "\033[1A\033[2K" >&2 # Clear option 2
            echo -ne "\033[1A\033[2K" >&2 # Clear option 1
            echo -ne "\033[1A\033[2K" >&2 # Clear empty line after prompt
            echo -ne "\033[1A\033[2K" >&2 # Clear prompt

            break
        elif [[ $key == $'\x1b' ]]; then
            read -rsn2 key

            case $key in
                '[A'|'[B') # Up or Down arrow
                    selected=$((1 - selected))
                    ;;
            esac

            # Clear previous menu and redraw
            echo -ne "\033[1A\033[2K" >&2
            echo -ne "\033[1A\033[2K" >&2
            echo -ne "\033[1A\033[2K" >&2
            echo -ne "\033[1A\033[2K" >&2

            draw_menu
        fi
    done

    if [ $selected -eq 1 ]; then
        # Use environment variable
        while true; do
            read -p "$(echo -e "${BOLD}Environment variable name${RESET}: ")" value
            value=$(clean_value "$value")

            if [ -z "$value" ]; then
                echo -e "${RED}Environment variable name cannot be empty.${RESET}" >&2
                continue
            fi

            # Normalize to ${VAR_NAME} format
            local var_name=$(echo "$value" | sed 's/^\${\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)}\{0,1\}$/\1/')

            if [ -n "$var_name" ]; then
                echo "\${$var_name}"
                set -e  # Re-enable exit-on-error
                return
            fi
            echo -e "${RED}Invalid environment variable name. Use alphanumeric characters and underscores.${RESET}" >&2
        done
    else
        # Enter value directly
        while true; do
            read -p "$(echo -e "${BOLD}$prompt${RESET}: ")" value
            value=$(clean_value "$value")
            if [ -n "$value" ]; then
                echo "$value"
                set -e  # Re-enable exit-on-error
                return
            fi
            echo -e "${RED}$prompt cannot be empty.${RESET}" >&2
        done
    fi
}

ask_input() {
    local prompt="$1"
    local default="$2"
    local value

    if [ -n "$default" ]; then
        read -p "$(echo -e "${BOLD}$prompt${RESET} [$default]: ")" value
        value=$(clean_value "$value")
        echo "${value:-$default}"
    else
        while true; do
            read -p "$(echo -e "${BOLD}$prompt${RESET}: ")" value
            value=$(clean_value "$value")
            if [ -n "$value" ]; then
                echo "$value"
                set -e  # Re-enable exit-on-error
                return
            fi
            echo -e "${RED}This field cannot be empty. Please enter a value.${RESET}" >&2
        done
    fi
}

ask_secret() {
    local prompt="$1"
    local value

    while true; do
        read -s -p "$(echo -e "${BOLD}$prompt${RESET}: ")" value
        echo "" >&2  # newline after hidden input (to stderr, not return value)
        value=$(clean_value "$value")
        if [ -n "$value" ]; then
            echo "$value"
            return
        fi
        echo -e "${RED}This field cannot be empty. Please enter a value.${RESET}" >&2
    done
}

ask_env_var_name() {
    local prompt="$1"
    local value

    while true; do
        read -p "$(echo -e "${BOLD}Environment variable name for $prompt${RESET}: ")" value
        value=$(clean_value "$value")

        if [ -z "$value" ]; then
            echo -e "${RED}Environment variable name cannot be empty.${RESET}" >&2
            continue
        fi

        # Normalize to ${VAR_NAME} format
        local var_name=$(echo "$value" | sed 's/^\${\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)}\{0,1\}$/\1/')

        if [ -n "$var_name" ]; then
            echo "\${$var_name}"
            return
        fi
        echo -e "${RED}Invalid environment variable name. Use alphanumeric characters and underscores.${RESET}" >&2
    done
}

# Clean value by removing newlines, carriage returns, and trimming whitespace
clean_value() {
    local value="$1"
    echo "$value" | tr -d '\n\r' | xargs
}

ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local selected=0
    local key

    # Temporarily disable exit-on-error for interactive input
    set +e

    # Show prompt
    echo -e "${BOLD}$prompt${RESET}"
    echo ""

    # Function to draw menu
    draw_menu() {
        for i in "${!options[@]}"; do
            if [ $i -eq $selected ]; then
                echo -e "  ${CYAN}▶${RESET} ${BOLD}${options[$i]}${RESET}"
            else
                echo -e "    ${options[$i]}"
            fi
        done
        echo ""
        echo -e "${GRAY}(Use ↑/↓ arrows, Enter to select)${RESET}"
    }

    # Initial draw
    draw_menu

    # Read keys and navigate
    while true; do
        # Read a single character
        read -rsn1 key

        # Handle different key types
        if [[ $key == "" ]]; then
            # Enter key pressed
            CHOICE_RESULT=$selected
            echo "" # newline after selection
            set -e  # Re-enable exit-on-error
            return 0
        elif [[ $key == $'\x1b' ]]; then
            # Escape sequence (arrow keys)
            read -rsn2 key # Read the rest of the escape sequence

            case $key in
                '[A') # Up arrow
                    selected=$((selected - 1))
                    if [ $selected -lt 0 ]; then
                        selected=$((${#options[@]} - 1))
                    fi
                    ;;
                '[B') # Down arrow
                    selected=$((selected + 1))
                    if [ $selected -ge ${#options[@]} ]; then
                        selected=0
                    fi
                    ;;
            esac

            # Clear previous menu and redraw
            for i in "${!options[@]}"; do
                echo -ne "\033[1A\033[2K" # Move up one line and clear it
            done
            echo -ne "\033[1A\033[2K" # Clear the empty line
            echo -ne "\033[1A\033[2K" # Clear the hint line

            draw_menu
        fi
    done
}

# Multi-select with checkboxes (returns array in MULTI_SELECT_RESULT)
# Usage: ask_multi_select "prompt" [--default-checked|--default-unchecked] "option1" "option2" ...
ask_multi_select() {
    local prompt="$1"
    shift

    # Check for default state flag
    local default_checked=1
    if [[ "$1" == "--default-checked" ]]; then
        default_checked=1
        shift
    elif [[ "$1" == "--default-unchecked" ]]; then
        default_checked=0
        shift
    fi

    local options=("$@")
    local selected=0
    local key

    # Temporarily disable exit-on-error for interactive input
    set +e

    # Track which items are checked
    local -a checked=()
    for i in "${!options[@]}"; do
        checked[$i]=$default_checked
    done

    # Show prompt
    echo -e "${BOLD}$prompt${RESET}"
    echo ""

    # Function to draw menu
    draw_menu() {
        for i in "${!options[@]}"; do
            local checkbox="[ ]"
            if [ "${checked[$i]}" -eq 1 ]; then
                checkbox="${GREEN}[✓]${RESET}"
            fi

            if [ $i -eq $selected ]; then
                echo -e "  ${CYAN}▶${RESET} $checkbox ${BOLD}${options[$i]}${RESET}"
            else
                echo -e "    $checkbox ${options[$i]}"
            fi
        done
        echo ""
        echo -e "${GRAY}(Use ↑/↓ arrows, Space to toggle, Enter to confirm)${RESET}"
    }

    # Save current terminal state to a temp file (avoids variable expansion issues)
    STTY_SAVE_FILE=$(mktemp)
    stty -g > "$STTY_SAVE_FILE"

    # Disable echo + canonical mode
    stty -icanon -echo

    # Initial draw
    draw_menu

    # Read keys and navigate
    while true; do
        # Use dd to read exactly 1 byte - works reliably on macOS
        key=$(dd bs=1 count=1 2>/dev/null)

        # Check for Space (now properly captured on macOS)
        if [[ $key == " " ]]; then
            # Spacebar - toggle current item
            if [ "${checked[$selected]}" -eq 1 ]; then
                checked[$selected]=0
            else
                checked[$selected]=1
            fi

            # Clear and redraw
            for i in "${!options[@]}"; do
                echo -ne "\033[1A\033[2K"
            done
            echo -ne "\033[1A\033[2K" # Clear empty line
            echo -ne "\033[1A\033[2K" # Clear hint line

            draw_menu
        elif [[ -z $key ]] || [[ $key == $'\n' ]] || [[ $key == $'\r' ]]; then
            # Enter key pressed (empty string in -icanon mode) - collect selected items
            MULTI_SELECT_RESULT=()
            for i in "${!options[@]}"; do
                if [ "${checked[$i]}" -eq 1 ]; then
                    MULTI_SELECT_RESULT+=("${options[$i]}")
                fi
            done
            # Restore terminal settings from saved file
            if [ -f "$STTY_SAVE_FILE" ]; then
                stty $(cat "$STTY_SAVE_FILE" 2>/dev/null) 2>/dev/null || stty sane
                rm -f "$STTY_SAVE_FILE"
            else
                stty sane
            fi
            echo "" # newline after selection
            set -e  # Re-enable exit-on-error
            return 0
        elif [[ $key == $'\x1b' ]]; then
            # Escape sequence - read next 2 bytes for arrow keys
            rest=$(dd bs=1 count=2 2>/dev/null)

            case $rest in
                '[A') # Up arrow
                    selected=$((selected - 1))
                    if [ $selected -lt 0 ]; then
                        selected=$((${#options[@]} - 1))
                    fi
                    ;;
                '[B') # Down arrow
                    selected=$((selected + 1))
                    if [ $selected -ge ${#options[@]} ]; then
                        selected=0
                    fi
                    ;;
            esac

            # Clear and redraw
            for i in "${!options[@]}"; do
                echo -ne "\033[1A\033[2K"
            done
            echo -ne "\033[1A\033[2K" # Clear empty line
            echo -ne "\033[1A\033[2K" # Clear hint line

            draw_menu
        fi
    done
}

ask_optional_path() {
    local prompt="$1"
    local path

    read -p "$(echo -e "${BOLD}$prompt${RESET} (or press Enter to skip): ")" path

    # Expand tilde if present
    if [[ "$path" =~ ^~ ]]; then
        path="${path/#\~/$HOME}"
    fi

    echo "$path"
}

ask_optional_input() {
    local prompt="$1"
    local value

    read -p "$(echo -e "${BOLD}$prompt${RESET} (or press Enter to skip): ")" value
    value=$(clean_value "$value")
    echo "$value"
}

# Validate Moderne token
validate_moderne_token() {
    local api_url="$1"  # Should be https://api.{tenant}.moderne.io
    local token="$2"

    if [ -z "$token" ]; then
        return 1
    fi

    # Make a simple GraphQL query to validate the token
    local graphql_url="${api_url}/graphql"
    local query='{"query":"query test { accessTokens { id } }"}'

    local response=$(curl -s -w "\n%{http_code}" -X POST "$graphql_url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d "$query" 2>/dev/null)

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    # Check if the request was successful
    if [ "$http_code" = "200" ] && echo "$body" | grep -q '"accessTokens"'; then
        return 0
    else
        # Show curl command for debugging
        printf "\n" >&2
        printf "${GRAY}Debug: Test this connection yourself with:${RESET}\n" >&2
        printf "${GRAY}curl -X POST \"$graphql_url\" \\${RESET}\n" >&2
        printf "${GRAY}  -H \"Content-Type: application/json\" \\${RESET}\n" >&2
        printf "${GRAY}  -H \"Authorization: Bearer YOUR_TOKEN\" \\${RESET}\n" >&2
        printf "${GRAY}  -d '{\"query\":\"query test { accessTokens { id } }\"}\'${RESET}\n" >&2
        printf "\n" >&2
        return 1
    fi
}

# Validate artifact repository credentials
validate_artifact_repository() {
    local url="$1"
    local auth_method="$2"
    local username="$3"
    local password="$4"
    local token="$5"

    if [ -z "$url" ]; then
        return 1
    fi

    # Make a HEAD request to the repository to test authentication
    local http_code
    if [ "$auth_method" = "userpass" ]; then
        http_code=$(curl -s -L -o /dev/null -w "%{http_code}" -u "$username:$password" "$url" 2>/dev/null)
    else
        http_code=$(curl -s -L -o /dev/null -w "%{http_code}" -H "X-JFrog-Art-Api: $token" "$url" 2>/dev/null)
    fi

    # Check if the request was successful (200, 201, 204)
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
        return 0
    else
        # Show curl command for debugging
        printf "\n" >&2
        printf "${GRAY}Debug: Test this connection yourself with:${RESET}\n" >&2
        if [ "$auth_method" = "userpass" ]; then
            printf "${GRAY}curl -L -u \"YOUR_USERNAME:YOUR_PASSWORD\" \"$url\"${RESET}\n" >&2
        else
            printf "${GRAY}curl -L -H \"X-JFrog-Art-Api: YOUR_TOKEN\" \"$url\"${RESET}\n" >&2
        fi
        printf "\n" >&2
        return 1
    fi
}

# Parse error messages from output file
parse_error_message() {
    local output_file="$1"
    local error_msg=""

    if [ ! -f "$output_file" ]; then
        return
    fi

    # Check for common error patterns
    if grep -q "Error.*Invalid JSON" "$output_file" 2>/dev/null; then
        error_msg="Invalid API response - check your URL and network connection"
    elif grep -q "Error.*Failed to fetch" "$output_file" 2>/dev/null; then
        error_msg="Network timeout or connection error"
    elif grep -q "401\|Unauthorized\|Authentication failed" "$output_file" 2>/dev/null; then
        error_msg="Authentication failed - check your credentials"
    elif grep -q "403\|Forbidden\|Permission denied" "$output_file" 2>/dev/null; then
        error_msg="Permission denied - check token/credentials have required permissions"
    elif grep -q "404\|Not found" "$output_file" 2>/dev/null; then
        error_msg="Resource not found - check your URL, organization, or project name"
    elif grep -q "Error:" "$output_file" 2>/dev/null; then
        # Extract first error line
        error_msg=$(grep -m 1 "Error:" "$output_file" 2>/dev/null | sed 's/^Error: //' || true)
    fi

    if [ -n "$error_msg" ]; then
        echo "$error_msg"
    fi
}

# Show progress while a command runs
run_with_progress() {
    local message="$1"
    shift
    local output_file="${@:$#}"  # Last argument

    # All arguments except last - copy all but last to new array
    local cmd_args=()
    local last_idx=$(($# - 1))
    local i=0
    for arg in "$@"; do
        if [ $i -lt $last_idx ]; then
            cmd_args+=("$arg")
        fi
        ((i++))
    done

    # Run command in background
    "${cmd_args[@]}" > "$output_file" 2>&1 &
    local pid=$!

    # Show spinner while running (no total timeout - individual curl requests have their own timeout)
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    echo -n "  "
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r${CYAN}${spin:$i:1}${RESET} $message..."
        sleep 0.1
    done

    # Wait for completion and get exit code
    wait $pid
    local exit_code=$?

    # Clear spinner line
    printf "\r  "
    printf "\033[K" # Clear to end of line

    return $exit_code
}

# Cleanup function
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# ============================================================================
# Welcome message
# ============================================================================

show_welcome() {
    clear

    # Moderne logo
    echo "   ▛▀▀▚▖  ▗▄▟▜"
    echo "   ▌   ▜▄▟▀  ▐"
    echo "   ▛▀▀█▀▛▀▀▀▀▜"
    echo "   ▌▟▀  ▛▀▀▀▀▜"
    echo "   ▀▀▀▀▀▀▀▀▀▀▀"
    echo ""

    print_header "Mass Ingest - Setup Wizard"

    echo -e "Let's get your repositories into Moderne."
    echo ""
    echo -e "In the next ${BOLD}5-10 minutes${RESET}, we'll:"
    echo ""
    echo -e "  ${CYAN}1.${RESET} Connect to your SCM providers and discover repositories"
    echo -e "  ${CYAN}2.${RESET} Configure Docker with the JDKs and build tools you need"
    echo -e "  ${CYAN}3.${RESET} Set up artifact repository publishing and authentication"
    echo -e "  ${CYAN}4.${RESET} Generate all configuration files"
    echo ""
    echo -e "${BOLD}What you'll have when we're done:${RESET}"
    echo ""
    echo -e "  ${GREEN}✓${RESET} repos.csv with your repositories"
    echo -e "  ${GREEN}✓${RESET} Custom Dockerfile tailored to your tech stack"
    echo -e "  ${GREEN}✓${RESET} docker-compose.yml ready to run"
    echo -e "  ${GREEN}✓${RESET} .env with credentials configured"
    echo ""
    echo -e "${BOLD}Next:${RESET} Build the Docker image and run mass-ingest to generate LSTs"
    echo ""
    echo -e "${GRAY}(Press Ctrl+C at any time to cancel)${RESET}"
    echo ""

    wait_for_enter "Ready? Press Enter to start..."
    clear
}

# ============================================================================
# Phase 1: Repository Discovery (repos.csv)
# ============================================================================

# Combined introduction and existing file check
show_repos_csv_introduction() {
    clear
    print_section "Repository Discovery - repos.csv"

    echo "The repos.csv file tells Moderne which repositories to process."
    echo ""
    echo -e "${CYAN}${BOLD}What is repos.csv?${RESET}"
    echo ""
    echo "A CSV file listing all repositories you want to ingest into Moderne."
    echo "Each row describes a single repository with its clone URL, branch, and"
    echo "organizational structure."
    echo ""
    echo -e "${BOLD}Required columns:${RESET}"
    echo -e "  ${CYAN}•${RESET} cloneUrl - Full Git URL to clone the repository"
    echo -e "  ${CYAN}•${RESET} branch - Branch to build LST artifacts from"
    echo -e "  ${CYAN}•${RESET} origin - Source identifier (e.g., github.com, gitlab.com)"
    echo -e "  ${CYAN}•${RESET} path - Repository identifier/path (e.g., org/repo-name)"
    echo ""
    echo -e "${BOLD}Optional columns:${RESET}"
    echo -e "  ${CYAN}•${RESET} org1, org2, ... - Organizational hierarchy for grouping repositories"
    echo ""

    # Show either example or existing file
    if [ -f "$OUTPUT_FILE" ]; then
        echo -e "${CYAN}${BOLD}Your existing repos.csv:${RESET}"
        echo ""
        echo -e "${GRAY}$(head -n 10 "$OUTPUT_FILE")${RESET}"
        echo ""

        if ask_yes_no "Use this existing repos.csv?" "Yes, use existing" "No, generate new"; then
            print_success "Using existing repos.csv"
            REPOS_CSV_REUSED=true
            return 0  # Skip repos.csv generation
        else
            print_warning "Will regenerate repos.csv"
            echo ""
        fi
    else
        echo -e "${CYAN}${BOLD}Example repos.csv:${RESET}"
        echo ""
        echo -e "${GRAY}  cloneUrl,branch,origin,path,org1,org2${RESET}"
        echo -e "${GRAY}  https://github.com/openrewrite/rewrite,main,github.com,openrewrite/rewrite,openrewrite,ALL${RESET}"
        echo -e "${GRAY}  https://github.com/openrewrite/rewrite-spring,main,github.com,openrewrite/rewrite-spring,openrewrite,ALL${RESET}"
        echo ""
    fi

    echo -e "${CYAN}${BOLD}How we'll generate it:${RESET}"
    echo ""
    echo -e "  ${CYAN}1.${RESET} Choose SCM providers (GitHub, GitLab, Azure DevOps, Bitbucket)"
    echo -e "  ${CYAN}2.${RESET} Authenticate with access tokens or credentials"
    echo -e "  ${CYAN}3.${RESET} Fetch repositories automatically from each provider"
    echo -e "  ${CYAN}4.${RESET} Generate repos.csv with all discovered repositories"
    echo ""

    wait_for_enter
    return 1  # Need to generate repos.csv
}

# SCM provider selection (loop with menu)
add_scm_providers() {
    local has_provider=false

    while true; do
        clear
        print_section "SCM Provider Selection"

        # Check if at least one provider has actual data fetched
        has_provider=false
        if [ ${#GITHUB_ORGS[@]} -gt 0 ] || \
           [ ${#GITLAB_GROUPS[@]} -gt 0 ] || \
           [ ${#AZURE_ORGS[@]} -gt 0 ] || \
           [ ${#BITBUCKET_CLOUD_WORKSPACES[@]} -gt 0 ] || \
           [ ${#BITBUCKET_DC_PROJECTS[@]} -gt 0 ]; then
            has_provider=true
        fi

        # Show menu with optional "Done" option
        if [ "$has_provider" = true ]; then
            ask_choice "Select an SCM provider to add:" \
                "GitHub" \
                "GitLab" \
                "Azure DevOps" \
                "Bitbucket Data Center / Server" \
                "Bitbucket Cloud" \
                "Done adding SCM providers"
        else
            ask_choice "Select an SCM provider to add:" \
                "GitHub" \
                "GitLab" \
                "Azure DevOps" \
                "Bitbucket Data Center / Server" \
                "Bitbucket Cloud"
        fi

        local continue_adding
        case $CHOICE_RESULT in
            0)
                configure_github && continue_adding=0 || continue_adding=1
                ENABLE_GITHUB=true
                ;;
            1)
                configure_gitlab && continue_adding=0 || continue_adding=1
                ENABLE_GITLAB=true
                ;;
            2)
                configure_azure_devops && continue_adding=0 || continue_adding=1
                ENABLE_AZURE_DEVOPS=true
                ;;
            3)
                configure_bitbucket_data_center && continue_adding=0 || continue_adding=1
                ENABLE_BITBUCKET_DATA_CENTER=true
                ;;
            4)
                configure_bitbucket_cloud && continue_adding=0 || continue_adding=1
                ENABLE_BITBUCKET_CLOUD=true
                ;;
            5)
                # "Done adding SCM providers" - only available when has_provider=true
                if [ "$has_provider" = true ]; then
                    break
                fi
                ;;
        esac

        # Check if user wants to continue (return 0) or stop (return 1)
        if [ $continue_adding -ne 0 ]; then
            break
        fi
    done

    # Validate at least one provider was configured
    if [ "$ENABLE_GITHUB" = false ] && [ "$ENABLE_GITLAB" = false ] && \
       [ "$ENABLE_AZURE_DEVOPS" = false ] && [ "$ENABLE_BITBUCKET_CLOUD" = false ] && \
       [ "$ENABLE_BITBUCKET_DATA_CENTER" = false ]; then
        echo ""
        print_error "Error: No SCM providers were configured. Exiting."
        exit 1
    fi
}

# GitHub configuration
configure_github() {
    clear
    print_section "GitHub Configuration"

    print_context "We'll fetch all repositories from GitHub organization(s) or user account(s)."

    echo ""
    read -p "$(echo -e "${BOLD}GitHub URL${RESET} (press Enter for github.com): ")" github_url_input

    if [ -z "$github_url_input" ]; then
        github_url="https://github.com"
        api_url="https://api.github.com"
        print_success "Using GitHub.com"
    else
        # Add https:// if not present
        if [[ ! "$github_url_input" =~ ^https?:// ]]; then
            github_url="https://$github_url_input"
        else
            github_url="$github_url_input"
        fi
        api_url="${github_url}/api/v3"
        print_success "Using GitHub Enterprise Server: $github_url"
    fi

    GITHUB_URL="$github_url"

    echo ""
    echo -e "${BOLD}Organization Configuration${RESET}"
    print_context "You can fetch repositories from one or more GitHub organizations or users.
We'll fetch all repositories from each organization you specify."

    # CLI detection and API fallback
    echo ""
    echo -e "${BOLD}Authentication Method${RESET}"

    local token=""
    if [ "$FORCE_GITHUB_API_MODE" = "true" ]; then
        echo ""
        print_warning "API mode forced (FORCE_GITHUB_API_MODE=true)"
        echo ""
        echo -e "${BOLD}Supply a GitHub Personal Access Token.${RESET}"
        echo ""
        print_context "You'll need a Personal Access Token (classic) with these scopes:
  • 'repo' (for private repositories)
  OR
  • 'public_repo' (if you only have public repositories)

Create at: ${github_url}/settings/tokens (select 'Tokens (classic)' type)"
        token=$(ask_secret_or_env_var "GitHub Personal Access Token")
    elif command -v gh &> /dev/null; then
        echo ""
        print_context "GitHub CLI (gh) detected. We'll use it for authentication.
Make sure you've already run 'gh auth login'.
Learn more: https://cli.github.com/manual/gh_auth_login"
    else
        echo ""
        print_warning "GitHub CLI (gh) not found. Falling back to API mode."
        echo ""
        echo -e "${BOLD}Supply a GitHub Personal Access Token.${RESET}"
        echo ""
        print_context "You'll need a Personal Access Token (classic) with these scopes:
  • 'repo' (for private repositories)
  OR
  • 'public_repo' (if you only have public repositories)

Create at: ${GITHUB_URL}/settings/tokens (select 'Tokens (classic)' type)"
        token=$(ask_secret_or_env_var "GitHub Personal Access Token")
    fi

    # Store token and API URL in environment if provided
    if [ -n "$token" ]; then
        export GITHUB_TOKEN="$token"
        export GITHUB_API_URL="$api_url"
    fi

    # Discover organizations
    echo ""
    echo -e "${CYAN}Discovering your organizations...${RESET}"

    local -a discovered_orgs=()
    local orgs_json=""

    if command -v gh &> /dev/null && [ -z "$token" ]; then
        # Use GH CLI
        if [[ "$github_url" != "https://github.com" ]]; then
            export GH_HOST="${github_url#https://}"
        fi
        orgs_json=$(gh api /user/orgs --jq '.[].login' 2>/dev/null | tr '\n' ' ' || true)
    else
        # Use API with token
        orgs_json=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$api_url/user/orgs" 2>/dev/null | grep -o '"login":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ' || true)
    fi

    # Parse org names into array
    if [ -n "$orgs_json" ]; then
        read -ra discovered_orgs <<< "$orgs_json"
    fi

    # Collect organizations and fetch immediately
    while true; do
        echo ""

        if [ ${#discovered_orgs[@]} -gt 0 ]; then
            print_success "Found ${#discovered_orgs[@]} organization(s)"
            echo ""

            # Limit display to first 20 orgs to avoid overwhelming menus
            local max_display=20
            local -a display_orgs=()
            local display_count=${#discovered_orgs[@]}
            if [ $display_count -gt $max_display ]; then
                display_count=$max_display
                print_warning "Showing first $max_display of ${#discovered_orgs[@]} organizations"
                echo ""
            fi

            # Build options array with limited orgs + manual option + done option
            local -a select_options=()
            for (( i=0; i<$display_count; i++ )); do
                select_options+=("${discovered_orgs[$i]}")
                display_orgs+=("${discovered_orgs[$i]}")
            done
            select_options+=("Manually add organization/user")

            # Only show "Done" if at least one org has been added
            if [ ${#GITHUB_ORGS[@]} -gt 0 ]; then
                select_options+=("Done adding GitHub organizations")
            fi

            ask_choice "Select organization to fetch from:" "${select_options[@]}"

            # Process selection
            local selected_index=$CHOICE_RESULT
            local manual_add_idx=${#display_orgs[@]}
            local done_idx=$((${#display_orgs[@]} + 1))

            if [ $selected_index -eq $manual_add_idx ]; then
                # Manual add selected
                echo ""
                local org=$(ask_input "Organization name (or GitHub username for personal repos)")
                GITHUB_ORGS+=("$org")
                fetch_from_github "$github_url" "$org" "$token" "$api_url"
            elif [ ${#GITHUB_ORGS[@]} -gt 0 ] && [ $selected_index -eq $done_idx ]; then
                # Done adding - return to SCM selection menu
                clear
                return 0
            else
                # Discovered org selected
                local org="${display_orgs[$selected_index]}"
                GITHUB_ORGS+=("$org")
                fetch_from_github "$github_url" "$org" "$token" "$api_url"
            fi
        else
            # No orgs discovered, fall back to manual entry
            print_warning "No organizations found. Add manually:"
            echo ""
            local org=$(ask_input "Organization name (or GitHub username for personal repos)")
            GITHUB_ORGS+=("$org")
            fetch_from_github "$github_url" "$org" "$token" "$api_url"
        fi

        # Ask what to do next
        echo ""

        # Build menu options dynamically
        local -a next_options=("Add another GitHub organization")

        # Only show "Remove last" if at least one org has been added
        if [ ${#GITHUB_ORGS[@]} -gt 0 ]; then
            local last_org_idx=$((${#GITHUB_ORGS[@]}-1))
            next_options+=("Remove last added organization (${GITHUB_ORGS[$last_org_idx]})")
        fi

        next_options+=("Add a different SCM provider" "Finalize repos.csv")

        ask_choice "What's next?" "${next_options[@]}"

        # Map choice to action (accounting for optional "Remove last" option)
        local add_another_idx=0
        local remove_last_idx=-1
        local different_scm_idx=1
        local finalize_idx=2

        if [ ${#GITHUB_ORGS[@]} -gt 0 ]; then
            remove_last_idx=1
            different_scm_idx=2
            finalize_idx=3
        fi

        if [ $CHOICE_RESULT -eq $add_another_idx ]; then
            # Add another GitHub org
            continue
        elif [ ${#GITHUB_ORGS[@]} -gt 0 ] && [ $CHOICE_RESULT -eq $remove_last_idx ]; then
            # Remove last org
            local last_org_idx=$((${#GITHUB_ORGS[@]}-1))
            local last_org="${GITHUB_ORGS[$last_org_idx]}"

            # Rebuild array without last element (bash 3.2 compatible)
            local -a new_github_orgs=()
            for (( i=0; i<$last_org_idx; i++ )); do
                new_github_orgs+=("${GITHUB_ORGS[$i]}")
            done
            GITHUB_ORGS=("${new_github_orgs[@]}")

            # Remove CSV file
            rm -f "$TEMP_DIR/github_${last_org}.csv"

            # Remove from FETCH_RESULTS
            local -a new_fetch_results=()
            for result in "${FETCH_RESULTS[@]}"; do
                if [[ ! "$result" =~ ^"GitHub ($last_org)|" ]]; then
                    new_fetch_results+=("$result")
                fi
            done
            FETCH_RESULTS=("${new_fetch_results[@]}")

            # Clear ENABLE_GITHUB if no orgs left
            if [ ${#GITHUB_ORGS[@]} -eq 0 ]; then
                ENABLE_GITHUB=false
            fi

            print_success "Removed: $last_org"
            echo ""
            sleep 1

            # Go back to SCM selection menu
            clear
            return 0
        elif [ $CHOICE_RESULT -eq $different_scm_idx ]; then
            # Add different SCM
            clear
            return 0
        elif [ $CHOICE_RESULT -eq $finalize_idx ]; then
            # Done
            clear
            return 1
        fi
    done
}

# Fetch from GitHub
fetch_from_github() {
    local github_url="$1"
    local org="$2"
    local token="$3"
    local api_url="$4"

    print_section "Fetching from GitHub: $org"

    local csv_file="$TEMP_DIR/github_${org}.csv"

    # Build command arguments
    local cmd_args=(bash "$REPO_FETCHERS_DIR/github.sh" "$org")

    if [ -n "$token" ]; then
        cmd_args+=("$token" "$api_url")
    else
        if [[ "$github_url" != "https://github.com" ]]; then
            export GH_HOST="${github_url#https://}"
        fi
    fi

    if run_with_progress "Fetching repositories" "${cmd_args[@]}" "$csv_file"; then
        local count=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l | tr -d ' ')

        if [ "$count" -eq 0 ]; then
            print_error "No repositories found in GitHub organization: $org"
            FETCH_RESULTS+=("GitHub ($org)|Failed|0")
        else
            print_success "Fetched $count repositories from GitHub"

            # Show preview
            echo ""
            if [ "$count" -eq 1 ]; then
                echo -e "${CYAN}Preview:${RESET}"
            else
                echo -e "${CYAN}Preview (first 2 repos):${RESET}"
            fi
            tail -n +2 "$csv_file" | head -2 | while IFS=, read -r cloneUrl branch origin path; do
                cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
                branch=$(echo "$branch" | sed 's/^"//;s/"$//')
                origin=$(echo "$origin" | sed 's/^"//;s/"$//')
                path=$(echo "$path" | sed 's/^"//;s/"$//')
                echo -e "${GRAY}  • $path${RESET} ${CYAN}($branch)${RESET}"
            done

            REPO_SOURCES+=("$csv_file")
            FETCH_RESULTS+=("GitHub ($org)|Success|$count")
        fi
    else
        local error_detail=$(parse_error_message "$csv_file")
        print_error "Failed to fetch from GitHub"
        if [ -n "$error_detail" ]; then
            print_warning "$error_detail"
        else
            print_warning "Make sure your credentials are configured correctly"
        fi
        FETCH_RESULTS+=("GitHub ($org)|Failed|0")
    fi

    if [[ "$github_url" != "https://github.com" ]]; then
        unset GH_HOST
    fi

    echo ""
}

# GitLab configuration
configure_gitlab() {
    clear
    print_section "GitLab Configuration"

    print_context "We'll fetch repositories from GitLab group(s) or all accessible repositories."

    echo ""
    read -p "$(echo -e "${BOLD}GitLab URL${RESET} (press Enter for gitlab.com): ")" gitlab_url_input

    if [ -z "$gitlab_url_input" ]; then
        gitlab_domain="https://gitlab.com"
        print_success "Using GitLab.com"
    else
        # Add https:// if not present
        if [[ ! "$gitlab_url_input" =~ ^https?:// ]]; then
            gitlab_domain="https://$gitlab_url_input"
        else
            gitlab_domain="$gitlab_url_input"
        fi
        print_success "Using self-hosted GitLab: $gitlab_domain"
    fi

    GITLAB_DOMAIN="$gitlab_domain"

    # Personal Access Token
    echo ""
    echo -e "${BOLD}Supply a GitLab Personal Access Token.${RESET}"
    echo ""
    print_context "GitLab requires a Personal Access Token with 'read_api' and 'read_repository' scopes.
Create one at: ${gitlab_domain}/-/user_settings/personal_access_tokens"

    local token=$(ask_secret_or_env_var "GitLab Personal Access Token")
    export GITLAB_TOKEN="$token"

    # Decide: all accessible repos or specific groups?
    echo ""
    echo -e "${BOLD}Group Configuration${RESET}"
    if ask_yes_no "Fetch from specific groups?" "Yes, select groups" "No, fetch all"; then
        echo ""
        print_context "You can specify GitLab groups (including subgroups).
Example: openrewrite/recipes"

        # Collect groups and fetch immediately
        while true; do
            echo ""
            local group=$(ask_input "Group path (e.g., openrewrite/recipes)")
            GITLAB_GROUPS+=("$group")

            # Fetch immediately
            fetch_from_gitlab "$gitlab_domain" "$group" "$token"

            # Ask what to do next
            echo ""
            ask_choice "What's next?" \
                "Add another GitLab group" \
                "Add a different SCM provider" \
                "Finalize repos.csv"

            case $CHOICE_RESULT in
                0) # Add another GitLab group
                    continue
                    ;;
                1) # Add different SCM
                    unset GITLAB_TOKEN
                    clear
                    return 0
                    ;;
                2) # Done
                    unset GITLAB_TOKEN
                    clear
                    return 1
                    ;;
            esac
        done
    else
        # Fetch all accessible repositories
        fetch_from_gitlab "$gitlab_domain" "" "$token"
    fi

    unset GITLAB_TOKEN

    # Ask what to do next (for "all accessible" path)
    echo ""
    ask_choice "What's next?" \
        "Add a different SCM provider" \
        "Finalize repos.csv"

    case $CHOICE_RESULT in
        0) # Add different SCM
            clear
            return 0
            ;;
        1) # Done
            clear
            return 1
            ;;
    esac
}

# Fetch from GitLab
fetch_from_gitlab() {
    local gitlab_url="$1"
    local group="$2"
    local token="$3"

    local display_name="GitLab"
    if [ -n "$group" ]; then
        display_name="GitLab ($group)"
    else
        display_name="GitLab (all accessible)"
    fi

    print_section "Fetching from $display_name"

    local csv_file="$TEMP_DIR/gitlab_$(echo "$group" | tr '/' '_').csv"
    [ -z "$group" ] && csv_file="$TEMP_DIR/gitlab_all.csv"

    local cmd_args=(bash "$REPO_FETCHERS_DIR/gitlab.sh" -t "$token" -h "$gitlab_url")
    if [ -n "$group" ]; then
        cmd_args+=(-g "$group")
    fi

    if run_with_progress "Fetching repositories" "${cmd_args[@]}" "$csv_file"; then
        local count=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l | tr -d ' ')

        if [ "$count" -eq 0 ]; then
            print_error "No repositories found in $display_name"
            FETCH_RESULTS+=("$display_name|Failed|0")
        else
            print_success "Fetched $count repositories from GitLab"

            # Show preview
            echo ""
            if [ "$count" -eq 1 ]; then
                echo -e "${CYAN}Preview:${RESET}"
            else
                echo -e "${CYAN}Preview (first 2 repos):${RESET}"
            fi
            tail -n +2 "$csv_file" | head -2 | while IFS=, read -r cloneUrl branch origin path; do
                cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
                branch=$(echo "$branch" | sed 's/^"//;s/"$//')
                origin=$(echo "$origin" | sed 's/^"//;s/"$//')
                path=$(echo "$path" | sed 's/^"//;s/"$//')
                echo -e "${GRAY}  • $path${RESET} ${CYAN}($branch)${RESET}"
            done

            REPO_SOURCES+=("$csv_file")
            FETCH_RESULTS+=("$display_name|Success|$count")
        fi
    else
        local error_detail=$(parse_error_message "$csv_file")
        print_error "Failed to fetch from GitLab"
        if [ -n "$error_detail" ]; then
            print_warning "$error_detail"
        else
            print_warning "Check that your token has 'read_api' scope and is valid"
        fi
        echo ""
        FETCH_RESULTS+=("$display_name|Failed|0")
    fi

    echo ""
}

# Azure DevOps configuration
configure_azure_devops() {
    clear
    print_section "Azure DevOps Configuration"

    print_context "Azure DevOps organizes repositories into Organizations and Projects.
You'll need to specify both."

    # CLI detection and PAT fallback
    echo ""
    echo -e "${BOLD}Authentication Method${RESET}"

    local pat=""
    if [ "$FORCE_AZURE_API_MODE" = "true" ]; then
        echo ""
        print_warning "API mode forced (FORCE_AZURE_API_MODE=true)"
        echo ""
        echo -e "${BOLD}Supply an Azure DevOps Personal Access Token.${RESET}"
        echo ""
        print_context "You'll need a Personal Access Token (PAT) with 'Code (Read)' scope.
Create one at: https://dev.azure.com/{org}/_usersSettings/tokens"
        pat=$(ask_secret_or_env_var "Azure DevOps Personal Access Token")
    elif command -v az &> /dev/null; then
        echo ""
        print_context "Azure CLI (az) detected. We'll use it for authentication.
Make sure you've already run 'az login' and 'az devops configure --defaults organization=...'."
    else
        echo ""
        print_warning "Azure CLI (az) not found. Falling back to API mode."
        echo ""
        echo -e "${BOLD}Supply an Azure DevOps Personal Access Token.${RESET}"
        echo ""
        print_context "You'll need a Personal Access Token (PAT) with 'Code (Read)' scope.
Create one at: https://dev.azure.com/{org}/_usersSettings/tokens"
        pat=$(ask_secret_or_env_var "Azure DevOps Personal Access Token")
    fi

    # Store PAT in environment if provided
    if [ -n "$pat" ]; then
        export AZURE_DEVOPS_PAT="$pat"
    fi

    # Collect organization and project pairs and fetch immediately
    while true; do
        echo ""
        local org=$(ask_input "Organization name")
        local project=$(ask_input "Project name")

        AZURE_ORGS+=("$org")
        AZURE_PROJECTS+=("$project")

        # Fetch immediately
        fetch_from_azure "$org" "$project" "$pat"

        # Ask what to do next
        echo ""
        ask_choice "What's next?" \
            "Add another Azure DevOps organization/project" \
            "Add a different SCM provider" \
            "Finalize repos.csv"

        case $CHOICE_RESULT in
            0) # Add another Azure org/project
                continue
                ;;
            1) # Add different SCM
                unset AZURE_DEVOPS_PAT
                clear
                return 0
                ;;
            2) # Done
                unset AZURE_DEVOPS_PAT
                clear
                return 1
                ;;
        esac
    done
}

# Fetch from Azure DevOps
fetch_from_azure() {
    local org="$1"
    local project="$2"
    local pat="$3"

    print_section "Fetching from Azure DevOps: $org/$project"

    local csv_file="$TEMP_DIR/azure_${org}_${project}.csv"

    local cmd_args=(bash "$REPO_FETCHERS_DIR/azure-devops.sh" -o "$org" -p "$project")
    if [ -n "$pat" ]; then
        cmd_args+=(-t "$pat")
    fi

    if run_with_progress "Fetching repositories" "${cmd_args[@]}" "$csv_file"; then
        local count=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l | tr -d ' ')

        if [ "$count" -eq 0 ]; then
            print_error "No repositories found in Azure DevOps: $org/$project"
            FETCH_RESULTS+=("Azure DevOps ($org/$project)|Failed|0")
        else
            print_success "Fetched $count repositories from Azure DevOps"

            # Show preview
            echo ""
            if [ "$count" -eq 1 ]; then
                echo -e "${CYAN}Preview:${RESET}"
            else
                echo -e "${CYAN}Preview (first 2 repos):${RESET}"
            fi
            tail -n +2 "$csv_file" | head -2 | while IFS=, read -r cloneUrl branch origin path; do
                cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
                branch=$(echo "$branch" | sed 's/^"//;s/"$//')
                origin=$(echo "$origin" | sed 's/^"//;s/"$//')
                path=$(echo "$path" | sed 's/^"//;s/"$//')
                echo -e "${GRAY}  • $path${RESET} ${CYAN}($branch)${RESET}"
            done

            REPO_SOURCES+=("$csv_file")
            FETCH_RESULTS+=("Azure DevOps ($org/$project)|Success|$count")
        fi
    else
        local error_detail=$(parse_error_message "$csv_file")
        print_error "Failed to fetch from Azure DevOps"
        if [ -n "$error_detail" ]; then
            print_warning "$error_detail"
        else
            print_warning "Make sure your credentials are configured correctly"
        fi
        FETCH_RESULTS+=("Azure DevOps ($org/$project)|Failed|0")
    fi

    echo ""
}

# Bitbucket Cloud configuration
configure_bitbucket_cloud() {
    clear
    print_section "Bitbucket Cloud Configuration"

    print_context "Bitbucket Cloud requires an App Password with 'repository:read' scope.
Create one at: https://bitbucket.org/account/settings/app-passwords/"

    local username=$(ask_input "Bitbucket username")

    echo ""
    echo -e "${BOLD}Supply a Bitbucket App Password.${RESET}"
    echo ""
    print_context "Bitbucket Cloud requires an App Password with 'repository:read' scope.
Create one at: https://bitbucket.org/account/settings/app-passwords/"

    local app_password=$(ask_secret_or_env_var "Bitbucket App Password")

    export BITBUCKET_CLOUD_USERNAME="$username"
    export BITBUCKET_CLOUD_APP_PASSWORD="$app_password"

    echo ""
    print_context "Workspaces are the top-level containers for repositories in Bitbucket Cloud."

    # Collect workspaces and fetch immediately
    while true; do
        echo ""
        local workspace=$(ask_input "Workspace name")
        BITBUCKET_CLOUD_WORKSPACES+=("$workspace")

        # Fetch immediately
        fetch_from_bitbucket_cloud "$workspace" "$username" "$app_password"

        # Ask what to do next
        echo ""
        ask_choice "What's next?" \
            "Add another Bitbucket Cloud workspace" \
            "Add a different SCM provider" \
            "Finalize repos.csv"

        case $CHOICE_RESULT in
            0) # Add another workspace
                continue
                ;;
            1) # Add different SCM
                unset BITBUCKET_CLOUD_USERNAME
                unset BITBUCKET_CLOUD_APP_PASSWORD
                clear
                return 0
                ;;
            2) # Done
                unset BITBUCKET_CLOUD_USERNAME
                unset BITBUCKET_CLOUD_APP_PASSWORD
                clear
                return 1
                ;;
        esac
    done
}

# Fetch from Bitbucket Cloud
fetch_from_bitbucket_cloud() {
    local workspace="$1"
    local username="$2"
    local app_password="$3"

    print_section "Fetching from Bitbucket Cloud: $workspace"

    local csv_file="$TEMP_DIR/bitbucket_cloud_${workspace}.csv"

    if run_with_progress "Fetching repositories" bash "$REPO_FETCHERS_DIR/bitbucket-cloud.sh" "$username" "$app_password" "$workspace" "$csv_file"; then
        local count=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l | tr -d ' ')

        if [ "$count" -eq 0 ]; then
            print_error "No repositories found in Bitbucket Cloud: $workspace"
            FETCH_RESULTS+=("Bitbucket Cloud ($workspace)|Failed|0")
        else
            print_success "Fetched $count repositories from Bitbucket Cloud"

            # Show preview
            echo ""
            if [ "$count" -eq 1 ]; then
                echo -e "${CYAN}Preview:${RESET}"
            else
                echo -e "${CYAN}Preview (first 2 repos):${RESET}"
            fi
            tail -n +2 "$csv_file" | head -2 | while IFS=, read -r cloneUrl branch origin path; do
                cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
                branch=$(echo "$branch" | sed 's/^"//;s/"$//')
                origin=$(echo "$origin" | sed 's/^"//;s/"$//')
                path=$(echo "$path" | sed 's/^"//;s/"$//')
                echo -e "${GRAY}  • $path${RESET} ${CYAN}($branch)${RESET}"
            done

            REPO_SOURCES+=("$csv_file")
            FETCH_RESULTS+=("Bitbucket Cloud ($workspace)|Success|$count")
        fi
    else
        local error_detail=$(parse_error_message "$csv_file")
        print_error "Failed to fetch from Bitbucket Cloud"
        if [ -n "$error_detail" ]; then
            print_warning "$error_detail"
        else
            print_warning "Check that your App Password has repository read permissions"
        fi
        echo ""
        FETCH_RESULTS+=("Bitbucket Cloud ($workspace)|Failed|0")
    fi

    echo ""
}

# Bitbucket Data Center configuration
configure_bitbucket_data_center() {
    clear
    print_section "Bitbucket Data Center Configuration"

    print_context "We'll fetch repositories from your Bitbucket Server/Data Center instance."

    # Server URL
    BITBUCKET_DC_URL=$(ask_input "Bitbucket Data Center URL (e.g., https://bitbucket.company.com)")

    # Personal Access Token
    echo ""
    echo -e "${BOLD}Supply a Bitbucket Data Center Personal Access Token.${RESET}"
    echo ""
    print_context "Bitbucket Data Center requires a Personal Access Token with 'repository:read' scope.
Create one at: ${BITBUCKET_DC_URL}/plugins/servlet/access-tokens/manage"

    local token=$(ask_secret_or_env_var "Bitbucket Data Center Personal Access Token")
    export BITBUCKET_DC_TOKEN="$token"

    echo ""
    print_context "Projects are the top-level containers for repositories in Bitbucket Data Center."

    # Collect projects and fetch immediately
    while true; do
        echo ""
        local project=$(ask_input "Project key (e.g., PROJ)")
        BITBUCKET_DC_PROJECTS+=("$project")

        # Fetch immediately
        fetch_from_bitbucket_data_center "$BITBUCKET_DC_URL" "$token" "$project"

        # Ask what to do next
        echo ""
        ask_choice "What's next?" \
            "Add another Bitbucket Data Center project" \
            "Add a different SCM provider" \
            "Finalize repos.csv"

        case $CHOICE_RESULT in
            0) # Add another project
                continue
                ;;
            1) # Add different SCM
                unset BITBUCKET_DC_TOKEN
                clear
                return 0
                ;;
            2) # Done
                unset BITBUCKET_DC_TOKEN
                clear
                return 1
                ;;
        esac
    done
}

# Fetch from Bitbucket Data Center
fetch_from_bitbucket_data_center() {
    local bitbucket_url="$1"
    local token="$2"
    local project="$3"

    print_section "Fetching from Bitbucket Data Center: $project"

    local csv_file="$TEMP_DIR/bitbucket_dc_${project}.csv"

    if run_with_progress "Fetching repositories" bash "$REPO_FETCHERS_DIR/bitbucket-data-center.sh" "$bitbucket_url" "$token" "http" "$project" "$csv_file"; then
        local count=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l | tr -d ' ')

        if [ "$count" -eq 0 ]; then
            print_error "No repositories found in Bitbucket Data Center: $project"
            FETCH_RESULTS+=("Bitbucket DC ($project)|Failed|0")
        else
            print_success "Fetched $count repositories from Bitbucket Data Center"

            # Show preview
            echo ""
            if [ "$count" -eq 1 ]; then
                echo -e "${CYAN}Preview:${RESET}"
            else
                echo -e "${CYAN}Preview (first 2 repos):${RESET}"
            fi
            tail -n +2 "$csv_file" | head -2 | while IFS=, read -r cloneUrl branch origin path; do
                cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
                branch=$(echo "$branch" | sed 's/^"//;s/"$//')
                origin=$(echo "$origin" | sed 's/^"//;s/"$//')
                path=$(echo "$path" | sed 's/^"//;s/"$//')
                echo -e "${GRAY}  • $path${RESET} ${CYAN}($branch)${RESET}"
            done

            REPO_SOURCES+=("$csv_file")
            FETCH_RESULTS+=("Bitbucket DC ($project)|Success|$count")
        fi
    else
        local error_detail=$(parse_error_message "$csv_file")
        print_error "Failed to fetch from Bitbucket Data Center"
        if [ -n "$error_detail" ]; then
            print_warning "$error_detail"
        else
            print_warning "Check that your token has repository read permissions"
        fi
        echo ""
        FETCH_RESULTS+=("Bitbucket DC ($project)|Failed|0")
    fi

    echo ""
}

# Organization structure configuration
ask_csv_normalization() {
    clear
    print_section "Organization Structure"

    print_context "Repositories can be organized using org columns:
  - None: No organization columns
  - Simple: Use 'ALL' for a flat structure
  - Hierarchical: Extract org hierarchy from repository paths (excluding repo name)

Example hierarchical org columns for 'openrewrite/recipes/java/security':
  org1=java, org2=recipes, org3=openrewrite, org4=ALL

For GitHub (e.g., 'openrewrite/rewrite'):
  org1=openrewrite, org2=ALL"

    ask_choice "Organization structure?" \
        "None (no org columns)" \
        "Simple (flat structure with 'ALL')" \
        "Hierarchical (extract from repository paths)"

    case $CHOICE_RESULT in
        0) # None
            USE_HIERARCHICAL_ORGS="none"
            print_success "No organization columns will be added"
            ;;
        1) # Simple
            USE_HIERARCHICAL_ORGS=false
            print_success "Using simple organization structure (ALL)"
            ;;
        2) # Hierarchical
            USE_HIERARCHICAL_ORGS=true
            print_success "Using hierarchical organization structure"
            ;;
    esac

    # Only ask about normalization if using hierarchical org structure
    if [ "$USE_HIERARCHICAL_ORGS" = true ]; then
        echo ""

        print_context "CSV normalization pads all rows with empty columns to match the maximum depth.
Empty columns are added at the beginning so 'ALL' appears in the same column for filtering.
This ensures Excel and other tools can properly parse the file."

        if ask_yes_no "Normalize CSV for Excel compatibility?" "Yes, normalize" "No, keep as-is"; then
            NORMALIZE_CSV=true
            print_success "CSV will be normalized"
        else
            NORMALIZE_CSV=false
            print_success "CSV will not be normalized"
        fi
    else
        # No normalization needed for "none" or "simple" modes
        NORMALIZE_CSV=false
    fi

    clear
}

# Normalize CSV with organization hierarchy
normalize_csv() {
    local input_csv="$1"
    local temp_output=$(mktemp)

    # Find maximum depth
    local max_depth=0
    while IFS=',' read -r cloneUrl branch origin path; do
        # Skip header
        if [ "$cloneUrl" = "\"cloneUrl\"" ]; then
            continue
        fi

        # Remove quotes
        path=$(echo "$path" | tr -d '"')

        # Count depth
        local depth=$(echo "$path" | tr -cd '/' | wc -c | tr -d ' ')
        depth=$((depth + 1))  # Number of segments = slashes + 1

        if [ $depth -gt $max_depth ]; then
            max_depth=$depth
        fi
    done < "$input_csv"

    # Account for excluding repo name and adding ALL
    # If max_depth is 2 (org/repo), we have 1 org + ALL = 2 org columns
    # If max_depth is 3 (org/sub/repo), we have 2 orgs + ALL = 3 org columns
    local num_org_cols=$max_depth

    # Write header with org columns
    local header="\"cloneUrl\",\"branch\",\"origin\",\"path\""
    for ((i=1; i<=num_org_cols; i++)); do
        header="$header,\"org$i\""
    done
    echo "$header" > "$temp_output"

    # Process each repository
    while IFS=',' read -r cloneUrl branch origin path; do
        # Skip header
        if [ "$cloneUrl" = "\"cloneUrl\"" ]; then
            continue
        fi

        # Remove quotes from path for processing
        local clean_path=$(echo "$path" | tr -d '"')

        # Split path into segments
        IFS='/' read -ra parts <<< "$clean_path"

        # Build org columns (deepest first, excluding repo name)
        local org_columns=()

        # Add path components in reverse (deepest first), excluding the repo name
        # Start from second-to-last element (${#parts[@]}-2) to exclude repo name
        for ((j=${#parts[@]}-2; j>=0; j--)); do
            if [ -n "${parts[j]}" ]; then
                org_columns+=("${parts[j]}")
            fi
        done

        # Always end with ALL
        org_columns+=("ALL")

        # Build org column string with padding at beginning
        local org_string=""
        local num_actual_orgs=${#org_columns[@]}
        local padding_needed=$((num_org_cols - num_actual_orgs))

        # Add padding at the beginning (empty columns)
        if [ "$NORMALIZE_CSV" = true ]; then
            for ((j=0; j<padding_needed; j++)); do
                org_string="$org_string,"
            done
        fi

        # Add actual org values
        for ((j=0; j<num_actual_orgs; j++)); do
            org_string="$org_string,\"${org_columns[$j]}\""
        done

        # Write the row
        echo "$cloneUrl,$branch,$origin,$path$org_string" >> "$temp_output"

    done < "$input_csv"

    mv "$temp_output" "$OUTPUT_FILE"
}

# Generate repos.csv from collected sources
generate_repos_csv() {
    # Check if any repositories were fetched
    if [ ${#REPO_SOURCES[@]} -eq 0 ]; then
        print_error "No repositories were fetched"
        exit 1
    fi

    local temp_merged="$TEMP_DIR/merged.csv"
    local temp_data="$TEMP_DIR/data_with_orgs.txt"

    # First pass: Generate all data rows and track max org depth
    local max_org_depth=0
    if [ "$USE_HIERARCHICAL_ORGS" = false ]; then
        max_org_depth=1  # Simple mode has 1 org column (ALL)
    fi
    > "$temp_data"

    for csv_file in "${REPO_SOURCES[@]}"; do
        if [ ! -f "$csv_file" ]; then
            continue
        fi

        while IFS=, read -r cloneUrl branch origin path; do
            # Clean up quotes
            cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
            branch=$(echo "$branch" | sed 's/^"//;s/"$//')
            origin=$(echo "$origin" | sed 's/^"//;s/"$//')
            path=$(echo "$path" | sed 's/^"//;s/"$//')

            if [ "$USE_HIERARCHICAL_ORGS" = "none" ]; then
                # No org columns
                echo "$cloneUrl|$branch|$origin|$path" >> "$temp_data"
            elif [ "$USE_HIERARCHICAL_ORGS" = true ]; then
                # Extract org hierarchy from path (deepest to shallowest)
                # Exclude the last segment (repository name)
                IFS='/' read -ra parts <<< "$path"
                local org_columns=()

                # Add path components in reverse (deepest first), excluding the repo name
                # Start from second-to-last element (${#parts[@]}-2) to exclude repo name
                for ((j=${#parts[@]}-2; j>=0; j--)); do
                    if [ -n "${parts[j]}" ]; then
                        org_columns+=("${parts[j]}")
                    fi
                done

                # Always end with ALL
                org_columns+=("ALL")

                # Track max depth
                local depth=${#org_columns[@]}
                if [ $depth -gt $max_org_depth ]; then
                    max_org_depth=$depth
                fi

                # Store row data with org columns separated by |
                echo "$cloneUrl|$branch|$origin|$path|${org_columns[*]}" >> "$temp_data"
            else
                # Simple: just ALL
                echo "$cloneUrl|$branch|$origin|$path|ALL" >> "$temp_data"
            fi
        done < <(tail -n +2 "$csv_file")
    done

    # Determine number of org columns to use
    local num_org_cols=$max_org_depth

    # Generate header with correct number of org columns
    local header="cloneUrl,branch,origin,path"
    for ((i=1; i<=num_org_cols; i++)); do
        header="$header,org$i"
    done
    echo "$header" > "$temp_merged"

    # Second pass: Write data rows with appropriate padding
    while IFS='|' read -r cloneUrl branch origin path org_data; do
        IFS=' ' read -ra org_columns <<< "$org_data"

        # Build org column string with padding at beginning
        local org_string=""
        local num_actual_orgs=${#org_columns[@]}
        local padding_needed=$((num_org_cols - num_actual_orgs))

        # Add padding at the beginning (empty columns)
        if [ "$NORMALIZE_CSV" = true ]; then
            for ((j=0; j<padding_needed; j++)); do
                org_string="$org_string,"
            done
        fi

        # Add actual org values
        for ((j=0; j<num_actual_orgs; j++)); do
            org_string="$org_string,\"${org_columns[$j]}\""
        done

        echo "\"$cloneUrl\",\"$branch\",\"$origin\",\"$path\"$org_string" >> "$temp_merged"
    done < "$temp_data"

    # Copy to output file
    cp "$temp_merged" "$OUTPUT_FILE"
}

# Show fetch summary
show_repos_summary() {
    clear
    print_section "Generating repos.csv"
    echo ""

    # Show spinner while generating repos.csv in background
    (generate_repos_csv) &
    local pid=$!

    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    echo -n "  "
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r${CYAN}${spin:$i:1}${RESET} Processing repositories and generating CSV..."
        sleep 0.1
    done
    wait $pid

    # Clear spinner line
    printf "\r  "
    printf "\033[K"

    print_success "repos.csv generated successfully"
    echo ""
    sleep 0.5

    clear
    print_section "Repository Discovery Complete"

    # Show summary
    local total_repos=0
    for result in "${FETCH_RESULTS[@]}"; do
        IFS='|' read -r provider status count <<< "$result"

        if [ "$status" = "Success" ]; then
            echo -e "${GREEN}✓${RESET} $provider: $count repositories"
            total_repos=$((total_repos + count))
        else
            echo -e "${RED}✗${RESET} $provider: Failed"
        fi
    done

    echo ""
    echo -e "${BOLD}Total repositories:${RESET} $total_repos"
    print_success "Generated: $OUTPUT_FILE"
    echo ""

    # Show preview and ask if it looks OK
    echo "Here are the first 10 lines of the generated repos.csv:"
    echo ""
    echo -e "${GRAY}$(head -n 10 "$OUTPUT_FILE")${RESET}"
    echo ""

    ask_choice "Does this look correct?" \
        "Yes, continue to Docker configuration" \
        "No, add another SCM provider" \
        "No, start over from scratch"

    case $CHOICE_RESULT in
        0)
            # Continue
            clear
            ;;
        1)
            # Add another SCM - return code 10
            return 10
            ;;
        2)
            # Start over - return code 20
            return 20
            ;;
    esac
}

# ============================================================================
# Phase 2: Docker Environment (Dockerfile wizard)
# ============================================================================

# Introduction page for Docker environment
show_phase2_introduction() {
    clear
    print_section "Docker Environment - Configuration"

    echo "Now we'll configure your Docker environment for running Moderne CLI's mass-ingest."
    echo ""
    echo -e "${CYAN}${BOLD}What we'll create:${RESET}"
    echo ""
    echo -e "  ${CYAN}•${RESET} ${BOLD}Dockerfile${RESET} - Custom Docker image with all required tools and runtimes"
    echo -e "  ${CYAN}•${RESET} ${BOLD}docker-compose.yml${RESET} - Easy container management (optional)"
    echo -e "  ${CYAN}•${RESET} ${BOLD}.env${RESET} - Environment configuration with your credentials"
    echo ""
    echo -e "${CYAN}${BOLD}What we'll configure:${RESET}"
    echo ""
    echo -e "  ${CYAN}1.${RESET} ${BOLD}Base image type${RESET} - Debian or Alpine"
    echo -e "  ${CYAN}2.${RESET} ${BOLD}JDK versions${RESET} - Java Development Kits (8, 11, 17, 21, 25)"
    echo -e "  ${CYAN}3.${RESET} ${BOLD}Moderne CLI${RESET} - Version and source"
    echo -e "  ${CYAN}4.${RESET} ${BOLD}Moderne tenant${RESET} - Platform authentication (optional)"
    echo -e "  ${CYAN}5.${RESET} ${BOLD}Artifact repository${RESET} - Where to publish LST artifacts (Artifactory, etc.)"
    echo -e "  ${CYAN}6.${RESET} ${BOLD}Build tools${RESET} - Maven, Gradle, Bazel"
    echo -e "  ${CYAN}7.${RESET} ${BOLD}Language runtimes${RESET} - Node.js, Python, .NET, Android SDK"
    echo -e "  ${CYAN}8.${RESET} ${BOLD}Scalability options${RESET} - AWS CLI and AWS Batch support"
    echo -e "  ${CYAN}9.${RESET} ${BOLD}Security${RESET} - SSL certificates for HTTPS connections"
    echo -e "  ${CYAN}10.${RESET} ${BOLD}Git authentication${RESET} - For cloning private repositories"
    echo -e "  ${CYAN}11.${RESET} ${BOLD}Performance${RESET} - CPU and memory settings"
    echo -e "  ${CYAN}12.${RESET} ${BOLD}Docker Compose${RESET} - Container orchestration (optional)"
    echo ""
    echo -e "${CYAN}${BOLD}Why Docker?${RESET}"
    echo ""
    echo "Docker ensures consistent builds across environments and includes all dependencies"
    echo "needed to analyze your repositories. The container runs mass-ingest with your"
    echo "repos.csv to generate Lossless Semantic Trees (LSTs) for all your code."
    echo ""

    wait_for_enter
    clear
}

# Base image type selection
ask_base_image_type() {
    local progress="$1"
    while true; do
        print_section "Base Image Type" "$progress"

        print_context "Choose the base image type for your Docker environment.

${BOLD}Debian-based (eclipse-temurin:X-jdk):\033[22m${GRAY}
  • Broader compatibility with most tools and libraries
  • Uses glibc (standard C library)
  • Slightly larger image size (~50-100MB more per JDK)
  • Recommended for most use cases

${BOLD}Alpine-based (eclipse-temurin:X-jdk-alpine):\033[22m${GRAY}
  • Smaller image size (uses musl instead of glibc)
  • May have compatibility issues with some Java libraries using JNI
  • Good for production deployments where size matters
  • Some tools install differently"

        ask_choice "Select base image type:" \
            "Debian-based (recommended)" \
            "Alpine-based"

        case $CHOICE_RESULT in
            0)
                BASE_IMAGE_TYPE="debian"
                BASE_IMAGE_SUFFIX=""
                print_success "Using Debian-based images (eclipse-temurin:X-jdk)"
                ;;
            1)
                BASE_IMAGE_TYPE="alpine"
                BASE_IMAGE_SUFFIX="-alpine"
                print_success "Using Alpine-based images (eclipse-temurin:X-jdk-alpine)"
                ;;
        esac

        # Confirm selection
        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        echo -e "  Base image: ${BASE_IMAGE_TYPE}"
        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# JDK selection
ask_jdk_versions() {
    local progress="$1"
    while true; do
        print_section "JDK Versions" "$progress"

        echo "The Moderne CLI needs access to all JDK versions used by your Java projects to"
        echo "successfully build LSTs."
        echo ""

        print_context "${BOLD}Why multiple versions?\033[22m${GRAY} Ensures compatibility with projects targeting any Java version.
The additional disk space (~2GB) is worth avoiding build failures.

${BOLD}Deselect unused versions:\033[22m${GRAY} Use Space to uncheck JDK versions you definitely don't need."

        echo ""
        ask_multi_select "Select JDK versions to install:" --default-checked "JDK 8" "JDK 11" "JDK 17" "JDK 21" "JDK 25"

        # Extract just the version numbers from results
        ENABLED_JDKS=()
        for item in "${MULTI_SELECT_RESULT[@]}"; do
            # Extract number from "JDK XX"
            local version=$(echo "$item" | grep -o '[0-9]\+')
            ENABLED_JDKS+=("$version")
        done

        if [ ${#ENABLED_JDKS[@]} -eq 0 ]; then
            echo ""
            echo -e "${RED}Error: At least one JDK version must be selected!${RESET}"
            echo -e "${YELLOW}Please select at least one JDK version.${RESET}"
            echo ""
            wait_for_enter "Press Enter to try again..."
            clear
            continue
        fi

        print_success "Selected JDK versions: ${ENABLED_JDKS[*]}"

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
    local progress="$1"
    while true; do
        # Reset for restart (preserve environment variables)
        CLI_SOURCE="${CLI_SOURCE:-download}"
        CLI_VERSION_TYPE="${CLI_VERSION_TYPE:-stable}"
        CLI_SPECIFIC_VERSION="${CLI_SPECIFIC_VERSION:-}"
        CLI_JAR_PATH="${CLI_JAR_PATH:-}"

        print_section "Moderne CLI Configuration" "$progress"

        print_context "Choose how to provide the Moderne CLI to the container.

${BOLD}Download options:\033[22m${GRAY} Automatically fetches from Maven Central during build.
  • Latest stable: Recommended for production use
  • Latest staging: Pre-release version with newest features
  • Specific version: Pin to a known version for reproducibility

${BOLD}Supply JAR directly:\033[22m${GRAY} You provide mod.jar in the build context (faster builds, version control)."

        ask_choice "How do you want to provide the Moderne CLI?" \
            "Download latest stable (recommended)" \
            "Download latest staging" \
            "Download specific version" \
            "Supply JAR directly"

        case $CHOICE_RESULT in
            0)
                CLI_SOURCE="download"
                CLI_VERSION_TYPE="stable"
                print_success "Will download: latest stable"
                ;;
            1)
                CLI_SOURCE="download"
                CLI_VERSION_TYPE="staging"
                print_success "Will download: latest staging"
                ;;
            2)
                CLI_SOURCE="download"
                CLI_VERSION_TYPE="specific"
                echo ""
                read -p "$(echo -e "${BOLD}Enter version number${RESET} (e.g., 3.0.0): ")" CLI_SPECIFIC_VERSION
                if [ -z "$CLI_SPECIFIC_VERSION" ]; then
                    echo -e "${YELLOW}No version specified, defaulting to latest stable${RESET}"
                    CLI_VERSION_TYPE="stable"
                    print_success "Will download: latest stable"
                else
                    print_success "Will download: $CLI_SPECIFIC_VERSION"
                fi
                ;;
            3)
                CLI_SOURCE="local"
                echo ""
                CLI_JAR_PATH=$(ask_optional_path "Enter path to mod.jar file (default: mod.jar in build context)")
                if [ -z "$CLI_JAR_PATH" ]; then
                    CLI_JAR_PATH="mod.jar"
                    print_success "Will use mod.jar from build context"
                else
                    print_success "Will use JAR from: $CLI_JAR_PATH"
                fi
                ;;
        esac

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

# Moderne tenant configuration
ask_moderne_tenant_config() {
    local progress="$1"
    while true; do
        # Reset for restart (preserve environment variables)
        MODERNE_TENANT="${MODERNE_TENANT:-}"
        MODERNE_TOKEN="${MODERNE_TOKEN:-}"

        print_section "Moderne Tenant Configuration (Optional)" "$progress"

        print_context "Connect to Moderne platform to upload code analysis results and run
automated refactorings across your repositories."
        echo ""

        MODERNE_TENANT=$(ask_optional_input "Moderne tenant name (e.g., 'acme' for acme.moderne.io)")

        if [ -n "$MODERNE_TENANT" ]; then
            local tenant_url="https://${MODERNE_TENANT}.moderne.io"
            local api_url="https://api.${MODERNE_TENANT}.moderne.io"
            print_success "Tenant URL: $tenant_url"
            echo ""

            echo -e "${BOLD}Moderne API token${RESET}"
            echo ""
            echo -e "${CYAN}You can create a token at:${RESET}"
            echo -e "  ${tenant_url}/settings/access-token"
            echo ""

            # Token entry loop - allows retrying with different method
            local token_configured=false
            while ! $token_configured; do
                ask_choice "How do you want to provide the Moderne API token?" \
                    "Enter secret directly" \
                    "Use environment variable" \
                    "Skip (tenant will NOT be configured)"

                case $CHOICE_RESULT in
                    0|1)
                        # Enter directly or use env var
                        local provide_directly=$([[ $CHOICE_RESULT -eq 0 ]] && echo "true" || echo "false")

                        echo ""
                        # Use a temp variable to avoid shadowing environment variables
                        local token_input
                        if $provide_directly; then
                            token_input=$(ask_secret "Moderne API token")
                        else
                            token_input=$(ask_env_var_name "Moderne API token")
                        fi
                        token_input=$(clean_value "$token_input")

                        if [ -n "$token_input" ]; then
                            # Validate the token (expand env var references first for validation)
                            local token_to_validate="$token_input"
                            local is_env_var=false

                            if is_env_var_reference "$token_input"; then
                                is_env_var=true
                                # Expand BEFORE assigning to MODERNE_TOKEN to avoid shadowing
                                token_to_validate=$(expand_env_var "$token_input")

                                if [ -z "$token_to_validate" ]; then
                                    # Env var not set - that's okay, they can set it later
                                    print_warning "Environment variable $token_input is not currently set"
                                    print_success "Will use $token_input (set this before running docker-compose)"
                                    MODERNE_TOKEN="$token_input"
                                    token_configured=true
                                else
                                    echo ""
                                    echo -e "${CYAN}Found $token_input in environment, validating...${RESET}"
                                fi
                            fi

                            # Validate the token
                            if ! $token_configured; then
                                if ! $is_env_var; then
                                    echo ""
                                    echo -e "${CYAN}Validating token...${RESET}"
                                fi

                                if validate_moderne_token "$api_url" "$token_to_validate"; then
                                    if $is_env_var; then
                                        print_success "Token from $token_input validated successfully"
                                    else
                                        print_success "Token validated successfully"
                                    fi
                                    MODERNE_TOKEN="$token_input"
                                    token_configured=true
                                else
                                    if $is_env_var; then
                                        print_error "Token validation failed for $token_input"
                                        print_warning "The token in $token_input may be invalid or expired"
                                        echo -e "${GRAY}Current value: ${token_to_validate:0:20}...${RESET}"
                                    else
                                        print_error "Token validation failed"
                                        print_warning "The token may be invalid or the tenant URL may be incorrect"
                                    fi
                                    echo ""
                                    if ! ask_yes_no "Retry token entry?" "Yes, try again" "No, skip token"; then
                                        MODERNE_TOKEN=""
                                        print_warning "You can add the token to .env later"
                                        token_configured=true
                                    fi
                                    # If retry is yes, loop continues and re-asks for method
                                fi
                            fi
                        else
                            MODERNE_TOKEN=""
                            print_warning "You can add the token to .env later"
                            token_configured=true
                        fi
                        ;;
                    2)
                        # Skip - clear tenant configuration
                        MODERNE_TENANT=""
                        MODERNE_TOKEN=""
                        print_warning "Tenant configuration skipped - Moderne platform will NOT be configured"
                        echo ""
                        print_context "To use Moderne later, you'll need to:
  1. Set MODERNE_TENANT in .env
  2. Set MODERNE_TOKEN in .env
  3. Rebuild the Docker image"
                        token_configured=true
                        ;;
                esac
            done
        else
            MODERNE_TOKEN=""
            print_success "Skipping Moderne platform configuration"
        fi

        # Confirm configuration
        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        if [ -n "$MODERNE_TENANT" ]; then
            echo -e "  Tenant: https://${MODERNE_TENANT}.moderne.io"
            if [ -n "$MODERNE_TOKEN" ]; then
                if is_env_var_reference "$MODERNE_TOKEN"; then
                    local token_value=$(expand_env_var "$MODERNE_TOKEN")
                    if [ -n "$token_value" ]; then
                        echo -e "  Token: ${GREEN}✓${RESET} ${MODERNE_TOKEN} (set)"
                    else
                        echo -e "  Token: ${GREEN}✓${RESET} ${MODERNE_TOKEN} (not yet set)"
                    fi
                else
                    echo -e "  Token: ${GREEN}✓${RESET} Validated"
                fi
            else
                echo -e "  Token: ${GRAY}(not configured)${RESET}"
            fi
        else
            echo -e "  Tenant: ${GRAY}(not configured)${RESET}"
        fi

        echo ""
        if ask_yes_no "Is this correct?"; then
            break
        fi
        clear
    done

    clear
}

# Artifact repository configuration
ask_artifact_repository_config() {
    local progress="$1"
    while true; do
        # Reset for restart
        PUBLISH_URL=""
        PUBLISH_AUTH_METHOD="userpass"
        PUBLISH_USER=""
        PUBLISH_PASSWORD=""
        PUBLISH_TOKEN=""

        print_section "Artifact Repository Configuration" "$progress"

        print_context "Configure where Moderne CLI will publish the generated LST artifacts.
This must be a ${BOLD}Maven 2 format/layout${RESET} repository (e.g., JFrog Artifactory with Maven 2 layout)."

        echo ""
        echo -e "${BOLD}Supply Maven 2 repository URL.${RESET}"
        echo ""
        print_context "Example: https://artifactory.company.com/artifactory/moderne-ingest"

        local url_input=$(ask_input_or_env_var "Maven 2 repository URL")
        url_input=$(clean_value "$url_input")

        if [ -z "$url_input" ]; then
            print_error "Artifact repository URL is required"
            echo ""
            if ! ask_yes_no "Retry?" "Yes, try again" "No, skip configuration"; then
                print_warning "Skipping artifact repository configuration - you'll need to configure .env manually"
                break
            fi
            clear
            continue
        fi

        PUBLISH_URL="$url_input"
        if is_env_var_reference "$PUBLISH_URL"; then
            print_success "Using repository URL: $PUBLISH_URL"
        else
            print_success "Using repository: $PUBLISH_URL"
        fi

        # Ask for authentication method
        echo ""
        print_context "Choose authentication method for the artifact repository.

${BOLD}Username/Password:\033[22m${GRAY} Standard authentication with credentials.
${BOLD}Token:\033[22m${GRAY} API token or access token (e.g., JFrog API key)."

        ask_choice "Authentication method" \
            "Username and password" \
            "Token (API key)"

        case $CHOICE_RESULT in
            0)
                PUBLISH_AUTH_METHOD="userpass"
                echo ""
                echo -e "${BOLD}Supply artifact repository username.${RESET}"

                local user_input=$(ask_input_or_env_var "Username")
                user_input=$(clean_value "$user_input")

                if [ -z "$user_input" ]; then
                    print_error "Username is required"
                    echo ""
                    if ! ask_yes_no "Retry?" "Yes, try again" "No, skip configuration"; then
                        print_warning "Skipping artifact repository configuration"
                        break
                    fi
                    clear
                    continue
                fi

                PUBLISH_USER="$user_input"
                echo ""
                echo -e "${BOLD}Supply artifact repository password.${RESET}"

                local password_input=$(ask_secret_or_env_var_ref "Password")
                password_input=$(clean_value "$password_input")

                if [ -z "$password_input" ]; then
                    print_error "Password is required"
                    echo ""
                    if ! ask_yes_no "Retry?" "Yes, try again" "No, skip configuration"; then
                        print_warning "Skipping artifact repository configuration"
                        break
                    fi
                    clear
                    continue
                fi

                PUBLISH_PASSWORD="$password_input"

                # Test connection (don't fail on errors, just log)
                echo ""
                echo -e "${CYAN}Testing connection...${RESET}"

                # Expand env vars for testing
                local test_url=$(expand_env_var "$PUBLISH_URL")
                local test_user=$(expand_env_var "$PUBLISH_USER")
                local test_password=$(expand_env_var "$PUBLISH_PASSWORD")

                if [ -n "$test_url" ] && [ -n "$test_user" ] && [ -n "$test_password" ]; then
                    if validate_artifact_repository "$test_url" "userpass" "$test_user" "$test_password" ""; then
                        print_success "Connection test successful"
                    else
                        print_warning "Connection test failed - please verify credentials before running"
                    fi
                else
                    print_warning "Environment variables not set - skipping connection test"
                fi
                ;;
            1)
                PUBLISH_AUTH_METHOD="token"
                echo ""
                echo -e "${BOLD}Supply artifact repository API token.${RESET}"
                echo ""
                local token_input=$(ask_secret_or_env_var_ref "API token")
                token_input=$(clean_value "$token_input")

                if [ -z "$token_input" ]; then
                    print_error "Token is required"
                    echo ""
                    if ! ask_yes_no "Retry?" "Yes, try again" "No, skip configuration"; then
                        print_warning "Skipping artifact repository configuration"
                        break
                    fi
                    clear
                    continue
                fi

                PUBLISH_TOKEN="$token_input"

                # Test connection (don't fail on errors, just log)
                echo ""
                echo -e "${CYAN}Testing connection...${RESET}"

                # Expand env vars for testing
                local test_url=$(expand_env_var "$PUBLISH_URL")
                local test_token=$(expand_env_var "$PUBLISH_TOKEN")

                if [ -n "$test_url" ] && [ -n "$test_token" ]; then
                    if validate_artifact_repository "$test_url" "token" "" "" "$test_token"; then
                        print_success "Connection test successful"
                    else
                        print_warning "Connection test failed - please verify credentials before running"
                    fi
                else
                    print_warning "Environment variables not set - skipping connection test"
                fi
                ;;
        esac

        # Confirm configuration
        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        echo -e "  Repository URL: $PUBLISH_URL"
        if [ "$PUBLISH_AUTH_METHOD" = "userpass" ]; then
            echo -e "  Authentication: Username/Password"
            echo -e "  Username: $PUBLISH_USER"
        else
            echo -e "  Authentication: Token"
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
ask_build_tools_config() {
    local progress="$1"
    while true; do
        # Reset for restart
        ENABLE_MAVEN=false
        ENABLE_GRADLE=false
        ENABLE_BAZEL=false
        MAVEN_SETTINGS_FILE=""
        MAVEN_VERSION="3.9.11"
        GRADLE_VERSION="8.14"

        print_section "Build Tools Configuration" "$progress"

        echo "Java build tools needed for your projects."
        echo ""

        print_context "${BOLD}Maven wrapper (mvnw):\033[22m${GRAY} If ALL your Maven projects use mvnw, you can skip Maven
installation to save ~100MB and get faster builds.
${BOLD}Gradle wrapper (gradlew):\033[22m${GRAY} If ALL your Gradle projects use gradlew, you can skip Gradle
installation to save space and ensure version consistency.
${BOLD}Bazel:\033[22m${GRAY} Google's build system, mainly for monorepos or Google-style projects."

        echo ""
        ask_multi_select "Select build tools to install (if needed):" --default-unchecked \
            "Maven" \
            "Gradle" \
            "Bazel"

        # Process selections
        for item in "${MULTI_SELECT_RESULT[@]}"; do
            case "$item" in
                "Maven")
                    ENABLE_MAVEN=true
                    ;;
                "Gradle")
                    ENABLE_GRADLE=true
                    ;;
                "Bazel")
                    ENABLE_BAZEL=true
                    ;;
            esac
        done

        # Ask for custom versions if selected
        if [ "$ENABLE_MAVEN" = true ]; then
            echo ""
            read -p "$(echo -e "${BOLD}Maven version${RESET} (press Enter for 3.9.11): ")" user_maven_version
            if [ -n "$user_maven_version" ]; then
                # Validate semver format (MAJOR.MINOR.PATCH)
                if [[ "$user_maven_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    MAVEN_VERSION="$user_maven_version"
                    print_success "Maven $MAVEN_VERSION will be installed"
                else
                    echo -e "${RED}Invalid version format. Using default 3.9.11${RESET}"
                    MAVEN_VERSION="3.9.11"
                fi
            else
                print_success "Maven 3.9.11 will be installed"
            fi
        fi

        if [ "$ENABLE_GRADLE" = true ]; then
            echo ""
            read -p "$(echo -e "${BOLD}Gradle version${RESET} (press Enter for 8.14): ")" user_gradle_version
            if [ -n "$user_gradle_version" ]; then
                GRADLE_VERSION="$user_gradle_version"
                print_success "Gradle $GRADLE_VERSION will be installed"
            else
                print_success "Gradle 8.14 will be installed"
            fi
        fi

        if [ "$ENABLE_BAZEL" = true ]; then
            print_success "Bazelisk will be installed (auto-detects Bazel version per project)"
        fi

        # Maven settings.xml configuration (applies to both Maven and mvnw)
        echo ""
        echo -e "${BOLD}Maven Settings${RESET}"
        print_context "Maven and mvnw (wrapper) projects can use custom settings.xml for private repositories,
mirrors, profiles, or authentication.

${BOLD}What this does:\033[22m${GRAY} Copies your settings.xml to /root/.m2/ and configures mod CLI to use it.
${BOLD}Applies to:\033[22m${GRAY} Both pre-installed Maven and Maven wrapper (mvnw) projects."

        if ask_yes_no "Do you need custom Maven settings.xml?" "Yes, configure settings" "No, skip"; then
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
                    if ! ask_yes_no "Retry?" "Yes, enter different path" "No, skip settings"; then
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
                    if ask_yes_no "Use this path anyway?" "Yes, use path" "No, enter different path"; then
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
        fi
        if [ "$ENABLE_GRADLE" = true ]; then
            echo -e "  Gradle: Version $GRADLE_VERSION will be installed"
        fi
        if [ "$ENABLE_BAZEL" = true ]; then
            echo -e "  Bazel: Bazelisk will be installed (auto-detects version per project)"
        fi
        if [ "$ENABLE_MAVEN" = false ] && [ "$ENABLE_GRADLE" = false ] && [ "$ENABLE_BAZEL" = false ]; then
            echo -e "  No build tools will be installed (projects use wrappers)"
        fi
        if [ -n "$MAVEN_SETTINGS_FILE" ]; then
            echo -e "  Maven settings: $MAVEN_SETTINGS_FILE"
        elif [ "$ENABLE_MAVEN" = true ]; then
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

# Development platforms & runtimes
ask_language_runtimes() {
    local progress="$1"
    while true; do
        # Initialize all to false for restart
        ENABLE_ANDROID=false
        ENABLE_NODE=false
        ENABLE_PYTHON=false
        ENABLE_DOTNET=false

        print_section "Development Platforms & Runtimes" "$progress"

        print_context "Some Java projects include JavaScript, Python, or other components. Select the
runtimes needed to build your projects successfully. Missing runtimes will cause build failures.

Leave all unchecked if not needed."

        echo ""
        ask_multi_select "Select language runtimes to install:" --default-unchecked \
            "Android SDK (API 25-33, ~5GB)" \
            "Node.js 20.x" \
            "Python 3.11" \
            ".NET SDK 8.0"

        # Parse results
        for item in "${MULTI_SELECT_RESULT[@]}"; do
            case "$item" in
                "Android SDK"*)
                    ENABLE_ANDROID=true
                    ;;
                "Node.js"*)
                    ENABLE_NODE=true
                    ;;
                "Python"*)
                    ENABLE_PYTHON=true
                    ;;
                ".NET SDK"*)
                    ENABLE_DOTNET=true
                    ;;
            esac
        done

        echo ""
        echo -e "${BOLD}Selected configuration:${RESET}"
        local any_selected=false
        [ "$ENABLE_ANDROID" = true ] && echo -e "  Android SDK: Will be installed" && any_selected=true
        [ "$ENABLE_NODE" = true ] && echo -e "  Node.js 20.x: Will be installed" && any_selected=true
        [ "$ENABLE_PYTHON" = true ] && echo -e "  Python 3.11: Will be installed" && any_selected=true
        [ "$ENABLE_DOTNET" = true ] && echo -e "  .NET SDK 8.0: Will be installed" && any_selected=true
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
    local progress="$1"
    while true; do
        # Reset for restart
        ENABLE_AWS_CLI=false
        ENABLE_AWS_BATCH=false

        print_section "Scalability Options" "$progress"

        echo "AWS integrations for scalable processing."
        echo ""

        print_context "${BOLD}AWS CLI for S3:\033[22m${GRAY} Allows S3 URLs in repos.csv and access to AWS resources.
${BOLD}AWS Batch support:\033[22m${GRAY} Includes chunk.sh script for job parallelization at scale."

        echo ""
        ask_multi_select "Select AWS integrations (if needed):" --default-unchecked \
            "AWS CLI (for S3 artifact storage)" \
            "AWS Batch support (for distributed processing)"

        # Process selections
        for item in "${MULTI_SELECT_RESULT[@]}"; do
            case "$item" in
                "AWS CLI (for S3 artifact storage)")
                    ENABLE_AWS_CLI=true
                    ;;
                "AWS Batch support (for distributed processing)")
                    ENABLE_AWS_BATCH=true
                    ;;
            esac
        done

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
    local progress="$1"
    while true; do
        # Reset for restart
        CERT_FILE=""

        print_section "Security Configuration" "$progress"

        # Self-signed certificates
        echo "If you use self-signed SSL certificates for artifact storage, Git servers, or"
        echo "Moderne platform, the Java runtime needs to trust them to make HTTPS connections."
        echo ""

        print_context "${BOLD}What this does:\033[22m${GRAY} Imports your certificate into all JDK keystores and configures wget
for Maven wrapper scripts."

        if ! ask_yes_no "Do you use self-signed certificates?" "Yes, configure certificate" "No, skip"; then
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
                    if ! ask_yes_no "Use this file anyway?" "Yes, use file" "No, enter different path"; then
                        continue
                    fi
                fi

                if [ -f "$CERT_FILE" ]; then
                    print_success "Certificate file found: $CERT_FILE"
                    break
                else
                    print_error "Warning: File not found, but will include in Dockerfile anyway"
                    echo -e "${YELLOW}        Make sure to provide the certificate before building.${RESET}"
                    if ask_yes_no "Use this path anyway?" "Yes, use path" "No, enter different path"; then
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
    local progress="$1"
    while true; do
        # Reset for restart
        ENABLE_GIT_SSH=false
        ENABLE_GIT_HTTPS=false
        CREATE_GIT_CREDENTIALS_TEMPLATE=false

        print_section "Git Authentication" "$progress"

        echo "Configure Git authentication for accessing private repositories."
        echo ""

        print_context "${BOLD}SSH authentication:\033[22m${GRAY} Uses SSH keys for Git operations. Place your SSH keys in a .ssh/ directory.
${BOLD}HTTPS authentication:\033[22m${GRAY} Uses a .git-credentials file with personal access tokens.

You can select both, one, or neither."

        echo ""
        ask_multi_select "Select Git authentication methods (if needed):" --default-unchecked \
            "SSH authentication" \
            "HTTPS authentication"

        # Process selections
        ENABLE_GIT_SSH=false
        ENABLE_GIT_HTTPS=false

        for item in "${MULTI_SELECT_RESULT[@]}"; do
            case "$item" in
                "SSH authentication")
                    ENABLE_GIT_SSH=true
                    # Create .ssh directory
                    local build_dir=$(dirname "$OUTPUT_DOCKERFILE")
                    local ssh_dir="$build_dir/.ssh"
                    if [ ! -d "$ssh_dir" ]; then
                        mkdir -p "$ssh_dir"
                        print_success "Created .ssh/ directory in build context"
                    fi
                    ;;
                "HTTPS authentication")
                    ENABLE_GIT_HTTPS=true
                    ;;
            esac
        done

        # If HTTPS was selected, ask about existing .git-credentials file
        if [ "$ENABLE_GIT_HTTPS" = true ]; then
            echo ""
            if ask_yes_no "Do you already have a .git-credentials file?" "Yes, I have one" "No, create template"; then
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
    local progress="$1"
    while true; do
        print_section "Runtime Configuration" "$progress"

        # Java options
        echo -e "${BOLD}JVM Options${RESET}"
        print_context "Configure JVM options for the Moderne CLI runtime. These affect memory allocation
and stack size for LST processing."
        echo "Default: -XX:MaxRAMPercentage=60.0 -Xss3m (60% of container memory, 3MB stack size)"
        echo ""

        local default_java_opts="-XX:MaxRAMPercentage=60.0 -Xss3m"
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

# Docker Compose configuration
ask_docker_compose() {
    local progress="$1"
    print_section "Docker Compose" "$progress"

    echo "Docker Compose simplifies container management with configuration files."
    echo ""

    print_context "${BOLD}What you get:\033[22m${GRAY} A docker-compose.yml and .env.example file for easier startup.
Just edit .env with your credentials and run 'docker compose up'."

    if ask_yes_no "Generate Docker Compose files?" "Yes, generate files" "No, skip"; then
        GENERATE_DOCKER_COMPOSE=true
        print_success "Docker Compose files will be generated"
    else
        print_success "Will use manual docker commands instead"
    fi

    echo ""
    echo ""

    # Ask about data persistence
    print_section "Data Persistence"

    echo "The mass-ingest process generates LST artifacts and metadata during processing."
    echo ""

    print_context "${BOLD}Persist data:\033[22m${GRAY} Mount a local directory to save generated LSTs and processing state.
This allows you to stop and restart the container without losing progress.

${BOLD}No persistence:\033[22m${GRAY} Data stays inside the container. Useful for testing or one-time runs."

    if ask_yes_no "Mount a data directory for persistence?" "Yes, mount directory" "No, skip"; then
        echo ""
        echo -e "${BOLD}Enter data directory path (default: ./data):${RESET}"
        read -r dir_input
        if [ -z "$dir_input" ]; then
            DATA_MOUNT_DIR="./data"
        else
            DATA_MOUNT_DIR="$dir_input"
        fi
        print_success "Will mount $DATA_MOUNT_DIR to /var/moderne"
    else
        DATA_MOUNT_DIR=""
        print_success "No data directory mount (ephemeral storage)"
    fi

    clear
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

    # Generate FROM statements for selected JDKs with base image suffix
    for jdk in "${ENABLED_JDKS[@]}"; do
        echo "FROM eclipse-temurin:${jdk}-jdk${BASE_IMAGE_SUFFIX} AS jdk${jdk}" >> "$output"
    done
    echo "" >> "$output"

    # Install dependencies (using highest JDK as base)
    echo "# Install dependencies for \`mod\` cli" >> "$output"
    echo "FROM jdk${highest_jdk} AS dependencies" >> "$output"

    # Use appropriate package manager based on base image type
    if [ "$BASE_IMAGE_TYPE" = "alpine" ]; then
        echo "RUN apk update && apk add --no-cache curl git git-lfs jq libxml2-utils unzip wget zip vim && git lfs install" >> "$output"
    else
        echo "RUN apt-get -y update && apt-get install -y curl git git-lfs jq libxml2-utils unzip wget zip vim && git lfs install" >> "$output"
    fi
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
            echo "RUN /usr/lib/jvm/temurin-${jdk}-jdk/bin/keytool -import -noprompt -storepass changeit -file /root/${cert_basename} -keystore /usr/lib/jvm/temurin-${jdk}-jdk/jre/lib/security/cacerts" >> "$output"
        else
            echo "RUN /usr/lib/jvm/temurin-${jdk}-jdk/bin/keytool -import -noprompt -storepass changeit -file /root/${cert_basename} -keystore /usr/lib/jvm/temurin-${jdk}-jdk/lib/security/cacerts" >> "$output"
        fi
    done

    echo "RUN mod config http trust-store edit java-home" >> "$output"
    echo "" >> "$output"
    echo "# mvnw scripts in maven projects may attempt to download maven-wrapper jars using wget." >> "$output"
    echo "RUN echo \"ca_certificate = /root/${cert_basename}\" > /root/.wgetrc" >> "$output"
}

# Get template file path - check shared/ first, then base image type directory
get_template() {
    local template_name="$1"
    local shared_path="$TEMPLATES_DIR/shared/$template_name"
    local specific_path="$TEMPLATES_DIR/$BASE_IMAGE_TYPE/$template_name"

    if [ -f "$shared_path" ]; then
        echo "$shared_path"
    elif [ -f "$specific_path" ]; then
        echo "$specific_path"
    else
        print_error "Template not found: $template_name (checked shared/ and $BASE_IMAGE_TYPE/)"
        exit 1
    fi
}

# Generate the Dockerfile
generate_dockerfile() {
    print_section "Generating Dockerfile"

    local output="$OUTPUT_DOCKERFILE"

    # Backup existing Dockerfile if it exists
    if [ -f "$output" ]; then
        mv "$output" "${output}.original"
        echo -e "${GRAY}Backed up existing $output to ${output}.original${RESET}"
    fi

    # Start fresh
    > "$output"

    # Generate base section with selected JDKs
    generate_base_section "$output"
    echo "" >> "$output"

    # Add Moderne CLI (download or local)
    if [ "$CLI_SOURCE" = "local" ]; then
        sed -e "s|{{CLI_JAR_PATH}}|$CLI_JAR_PATH|g" \
            "$(get_template '00-modcli-local.Dockerfile')" >> "$output"
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
            "$(get_template '00-modcli-download.Dockerfile')" >> "$output"
    fi
    echo "" >> "$output"

    # Add build tools
    if [ "$ENABLE_GRADLE" = true ]; then
        # Replace hardcoded Gradle version with user's chosen version
        sed "s/8\.14/$GRADLE_VERSION/g" "$(get_template '10-gradle.Dockerfile')" >> "$output"
        echo "" >> "$output"
    fi

    if [ "$ENABLE_MAVEN" = true ]; then
        # Replace hardcoded Maven version with user's chosen version
        sed "s/ENV MAVEN_VERSION=.*/ENV MAVEN_VERSION=$MAVEN_VERSION/" "$(get_template '11-maven.Dockerfile')" >> "$output"
        echo "" >> "$output"
    fi

    # Add language runtimes
    if [ "$ENABLE_ANDROID" = true ]; then
        cat "$(get_template '20-android.Dockerfile')" >> "$output"
        echo "" >> "$output"
    fi

    if [ "$ENABLE_BAZEL" = true ]; then
        cat "$(get_template '21-bazel.Dockerfile')" >> "$output"
        echo "" >> "$output"
    fi

    if [ "$ENABLE_NODE" = true ]; then
        cat "$(get_template '22-node.Dockerfile')" >> "$output"
        echo "" >> "$output"
    fi

    if [ "$ENABLE_PYTHON" = true ]; then
        cat "$(get_template '23-python.Dockerfile')" >> "$output"
        echo "" >> "$output"
    fi

    if [ "$ENABLE_DOTNET" = true ]; then
        cat "$(get_template '24-dotnet.Dockerfile')" >> "$output"
        echo "" >> "$output"
    fi

    # Add AWS CLI
    if [ "$ENABLE_AWS_CLI" = true ]; then
        cat "$(get_template '15-aws-cli.Dockerfile')" >> "$output"
        echo "" >> "$output"
    fi

    # Add AWS Batch support
    if [ "$ENABLE_AWS_BATCH" = true ]; then
        cat "$(get_template '16-aws-batch.Dockerfile')" >> "$output"
        echo "" >> "$output"
    fi

    # Add Maven settings
    if [ -n "$MAVEN_SETTINGS_FILE" ]; then
        # Replace placeholder with actual filename
        local settings_basename=$(basename "$MAVEN_SETTINGS_FILE")
        sed "s|{{SETTINGS_FILE}}|$settings_basename|g" "$(get_template '32-maven-settings.Dockerfile')" >> "$output"
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
            echo "RUN chmod 700 /root/.ssh && find /root/.ssh -type f -exec chmod 600 {} +" >> "$output"
        fi

        if [ "$ENABLE_GIT_HTTPS" = true ]; then
            echo "COPY .git-credentials /root/.git-credentials" >> "$output"
            echo "RUN chmod 600 /root/.git-credentials && git config --global credential.helper store" >> "$output"
        fi

        echo "" >> "$output"
    fi

    # Always include runner (with placeholder replacement)
    # Format Java options: escape leading dashes and quote each option separately
    local formatted_java_options=""
    for opt in $JAVA_OPTIONS; do
        # Escape leading dash
        local escaped_opt="${opt/#-/\\-}"
        formatted_java_options="$formatted_java_options \"$escaped_opt\""
    done
    formatted_java_options="${formatted_java_options# }" # Trim leading space

    sed -e "s|{{JAVA_OPTIONS}}|$formatted_java_options|g" \
        -e "s|{{DATA_DIR}}|$DATA_DIR|g" \
        "$(get_template '99-runner.Dockerfile')" >> "$output"

    print_success "Dockerfile generated: $output"
}

# Generate docker-compose.yml and .env.example files
generate_docker_compose() {
    local output_dir=$(dirname "$OUTPUT_DOCKERFILE")
    local compose_file="$output_dir/$OUTPUT_DOCKER_COMPOSE"
    local env_file="$output_dir/$OUTPUT_ENV"

    echo ""
    echo -e "${CYAN}${BOLD}Generating Docker Compose files...${RESET}"
    echo ""

    # Generate docker-compose.yml
    cat > "$compose_file" << 'EOF'
services:
  mass-ingest:
    build:
      context: .
EOF

    # Add build args if downloading CLI from Maven
    if [ "$MODCLI_SOURCE" = "maven" ]; then
        cat >> "$compose_file" << 'EOF'
      args:
        MODERNE_CLI_VERSION: ${MODERNE_CLI_VERSION:-}
EOF
    fi

    cat >> "$compose_file" << 'EOF'
    env_file:
      - .env
    restart: unless-stopped
    ports:
      - "8080:8080"
EOF

    # Add data volume mount if configured
    if [ -n "$DATA_MOUNT_DIR" ]; then
        cat >> "$compose_file" << EOF
    volumes:
      - $DATA_MOUNT_DIR:/var/moderne
EOF
    else
        cat >> "$compose_file" << 'EOF'
    volumes:
EOF
    fi

    # Add Git authentication volume mounts
    if [ "$ENABLE_GIT_HTTPS" = true ]; then
        cat >> "$compose_file" << 'EOF'
      # Git HTTPS credentials (ensure .git-credentials exists)
      - ./.git-credentials:/root/.git-credentials:ro
EOF
    fi

    if [ "$ENABLE_GIT_SSH" = true ]; then
        cat >> "$compose_file" << 'EOF'
      # Git SSH keys (ensure .ssh directory exists)
      - ./.ssh:/root/.ssh:ro
EOF
    fi

    # Generate .env with actual values
    cat > "$env_file" << EOF
# ==============================================================================
# Mass-ingest configuration
# Generated by setup wizard - all values configured
# ==============================================================================

# Artifact repository configuration
EOF

    # Add publish URL and authentication
    if [ -n "$PUBLISH_URL" ]; then
        printf '%s\n' "PUBLISH_URL=$PUBLISH_URL" >> "$env_file"
        echo "" >> "$env_file"

        if [ "$PUBLISH_AUTH_METHOD" = "userpass" ]; then
            echo "# Username/password authentication" >> "$env_file"
            printf '%s\n' "PUBLISH_USER=$PUBLISH_USER" >> "$env_file"
            printf '%s\n' "PUBLISH_PASSWORD=$PUBLISH_PASSWORD" >> "$env_file"
        else
            echo "# Token authentication" >> "$env_file"
            printf '%s\n' "PUBLISH_TOKEN=$PUBLISH_TOKEN" >> "$env_file"
        fi
    else
        cat >> "$env_file" << 'EOF'
# Configure your artifact repository
PUBLISH_URL=https://your-artifactory.com/artifactory/moderne-ingest
PUBLISH_USER=your-username
PUBLISH_PASSWORD=your-password
# PUBLISH_TOKEN=your-token
EOF
    fi

    # Add Moderne platform configuration
    echo "" >> "$env_file"
    if [ -n "$MODERNE_TENANT" ]; then
        echo "# Moderne platform configuration" >> "$env_file"
        echo "MODERNE_TENANT=https://${MODERNE_TENANT}.moderne.io" >> "$env_file"
        if [ -n "$MODERNE_TOKEN" ]; then
            echo "MODERNE_TOKEN=${MODERNE_TOKEN}" >> "$env_file"
        else
            echo "# MODERNE_TOKEN=your-moderne-token" >> "$env_file"
        fi
    else
        echo "# Optional: Moderne platform configuration" >> "$env_file"
        echo "# MODERNE_TENANT=https://app.moderne.io" >> "$env_file"
        echo "# MODERNE_TOKEN=your-moderne-token" >> "$env_file"
    fi

    # Add CLI version option if downloading from Maven
    if [ "$MODCLI_SOURCE" = "maven" ]; then
        cat >> "$env_file" << 'EOF'

# Optional: CLI version (defaults to latest stable if not set)
# MODERNE_CLI_VERSION=3.50.0
EOF
    fi

    # Add repository index range
    echo "" >> "$env_file"
    echo "# Repository processing range (1-indexed, inclusive)" >> "$env_file"
    echo "START_INDEX=1" >> "$env_file"

    # Calculate END_INDEX based on repos.csv size (subtract 1 for header)
    local output_dir=$(dirname "$OUTPUT_DOCKERFILE")
    local repos_file="$output_dir/$OUTPUT_FILE"
    if [ -f "$repos_file" ]; then
        local repo_count=$(($(wc -l < "$repos_file") - 1))
        echo "END_INDEX=$repo_count" >> "$env_file"
    else
        echo "# END_INDEX=<will be set based on repos.csv size>" >> "$env_file"
    fi

    echo -e "${GREEN}✓ Generated $compose_file${RESET}"
    echo -e "${GREEN}✓ Generated $env_file${RESET}"
    echo ""
}

# ============================================================================
# Combined Summary and Next Steps
# ============================================================================

show_combined_summary() {
    print_header "Setup Complete!"

    echo -e "${GREEN}${BOLD}Your mass-ingest environment is ready!${RESET}"
    echo ""
    echo -e "${BOLD}Generated files:${RESET}"
    echo -e "  ${CYAN}✓ $OUTPUT_FILE${RESET} - Repository list"
    echo -e "  ${CYAN}✓ $OUTPUT_DOCKERFILE${RESET} - Docker image configuration"
    if [ "$GENERATE_DOCKER_COMPOSE" = true ]; then
        echo -e "  ${CYAN}✓ $OUTPUT_DOCKER_COMPOSE${RESET} - Docker Compose configuration"
        echo -e "  ${CYAN}✓ $OUTPUT_ENV${RESET} - Environment configuration (ready to use)"
    fi
    echo ""

    print_section "Next Steps"

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

    # Different instructions based on whether docker-compose was generated
    if [ "$GENERATE_DOCKER_COMPOSE" = true ]; then
        # Docker Compose workflow
        local output_dir=$(dirname "$OUTPUT_DOCKERFILE")

        # Only show configuration step if credentials weren't fully configured
        if [ -z "$PUBLISH_URL" ]; then
            echo -e "$step. ${BOLD}Configure environment:${RESET}"
            echo -e "   Edit $output_dir/.env and fill in your credentials"
            echo ""
            ((step++))
        fi

        echo -e "$step. ${BOLD}Start the container:${RESET}"
        echo -e "   ${CYAN}docker compose up${RESET}"
        echo ""
        echo -e "   ${GRAY}The container will build automatically and start processing${RESET}"
        echo ""
    else
        # Manual docker workflow
        echo -e "$step. ${BOLD}Build your container image:${RESET}"
        echo -e "   ${CYAN}docker build -f $OUTPUT_DOCKERFILE -t moderne/mass-ingest:latest .${RESET}"
        echo ""
        ((step++))

        echo -e "$step. ${BOLD}Run the container with repos.csv:${RESET}"
        echo ""
        echo -e "     ${GRAY}docker run -v \$(pwd):/workspace moderne/moderne-cli:latest${RESET} \\"
        echo -e "       ${GRAY}mass-ingest --repos /workspace/$OUTPUT_FILE${RESET} \\"
        echo -e "       ${GRAY}--output /workspace/output${RESET}"
        echo ""
    fi

    echo -e "${BOLD}Documentation:${RESET}"
    echo "  • Moderne CLI: https://docs.moderne.io/user-documentation/moderne-cli"
    echo "  • Mass Ingest: https://github.com/moderneinc/mass-ingest-example"
    echo ""
}

# ============================================================================
# Main Flow
# ============================================================================

main() {
    # Create temp directory for CSV files
    TEMP_DIR=$(mktemp -d)

    show_welcome

    # Phase 1: Repository Discovery
    print_header "Phase 1 of 2: Repository Discovery"
    echo ""

    # Show repos.csv introduction and check for existing file
    # Returns 0 if using existing file, 1 if need to generate
    if ! show_repos_csv_introduction; then
        # Loop to allow adding more SCM providers or starting over
        while true; do
            # Add and configure SCM providers (loops with menu)
            # Each configure function will fetch immediately
            add_scm_providers

            # Ask about CSV normalization
            ask_csv_normalization

            # Show summary and generate repos.csv
            # Temporarily disable set -e to capture return codes
            set +e
            show_repos_summary
            local summary_result=$?
            set -e

            if [ $summary_result -eq 10 ]; then
                # User wants to add another SCM provider
                clear
                continue
            elif [ $summary_result -eq 20 ]; then
                # User wants to start over - reset everything
                clear
                ENABLE_GITHUB=false
                ENABLE_GITLAB=false
                ENABLE_AZURE_DEVOPS=false
                ENABLE_BITBUCKET_CLOUD=false
                ENABLE_BITBUCKET_DATA_CENTER=false
                unset FETCH_RESULTS
                FETCH_RESULTS=()
                continue
            else
                # User accepted, continue to Phase 2
                break
            fi
        done
    fi

    # Phase 2: Docker Environment
    print_header "Phase 2 of 2: Docker Environment"
    echo ""

    # Show Phase 2 introduction
    show_phase2_introduction

    ask_base_image_type "Step 1/12"
    ask_jdk_versions "Step 2/12"
    ask_modcli_config "Step 3/12"
    ask_moderne_tenant_config "Step 4/12"
    ask_artifact_repository_config "Step 5/12"
    ask_build_tools_config "Step 6/12"
    ask_language_runtimes "Step 7/12"
    ask_scalability_options "Step 8/12"
    ask_security_config "Step 9/12"
    ask_git_auth "Step 10/12"
    ask_runtime_config "Step 11/12"
    ask_docker_compose "Step 12/12"

    # Show configuration preview
    clear
    print_section "Configuration Summary"
    echo ""

    # repos.csv summary
    echo -e "${BOLD}Repository Discovery:${RESET}"
    local total_repos=0

    # Check if we have fetch results or are reusing existing file
    if [ ${#FETCH_RESULTS[@]} -gt 0 ]; then
        for result in "${FETCH_RESULTS[@]}"; do
            IFS='|' read -r provider status count <<< "$result"
            if [ "$status" = "Success" ]; then
                echo -e "  ${GREEN}✓${RESET} $provider: $count repositories"
                total_repos=$((total_repos + count))
            fi
        done
    else
        # Reusing existing repos.csv - count lines
        if [ -f "$OUTPUT_FILE" ]; then
            total_repos=$(tail -n +2 "$OUTPUT_FILE" 2>/dev/null | wc -l | tr -d ' ')
            echo -e "  ${GREEN}✓${RESET} Reusing existing repos.csv"
        fi
    fi

    echo -e "  ${BOLD}Total: $total_repos repositories${RESET}"
    echo ""

    # Dockerfile summary
    echo -e "${BOLD}Docker Environment:${RESET}"
    echo -e "  ${GREEN}✓${RESET} JDK versions: ${ENABLED_JDKS[*]}"

    if [ "$CLI_SOURCE" = "local" ]; then
        echo -e "  ${GREEN}✓${RESET} Moderne CLI (from local mod.jar)"
    else
        if [ "$CLI_VERSION_TYPE" = "stable" ]; then
            echo -e "  ${GREEN}✓${RESET} Moderne CLI (latest stable)"
        elif [ "$CLI_VERSION_TYPE" = "staging" ]; then
            echo -e "  ${GREEN}✓${RESET} Moderne CLI (latest staging)"
        else
            echo -e "  ${GREEN}✓${RESET} Moderne CLI (version $CLI_SPECIFIC_VERSION)"
        fi
    fi

    if [ -n "$MODERNE_TENANT" ]; then
        echo -e "  ${GREEN}✓${RESET} Moderne tenant: https://${MODERNE_TENANT}.moderne.io"
        if [ -n "$MODERNE_TOKEN" ]; then
            echo -e "  ${GREEN}✓${RESET} Moderne token: configured"
        fi
    fi

    if [ -n "$PUBLISH_URL" ]; then
        echo -e "  ${GREEN}✓${RESET} Artifact repository: configured"
        if [ "$PUBLISH_AUTH_METHOD" = "userpass" ]; then
            echo -e "  ${GREEN}✓${RESET} Authentication: username/password"
        else
            echo -e "  ${GREEN}✓${RESET} Authentication: token"
        fi
    fi

    [ "$ENABLE_MAVEN" = true ] && echo -e "  ${GREEN}✓${RESET} Apache Maven $MAVEN_VERSION"
    [ "$ENABLE_GRADLE" = true ] && echo -e "  ${GREEN}✓${RESET} Gradle $GRADLE_VERSION"
    [ "$ENABLE_BAZEL" = true ] && echo -e "  ${GREEN}✓${RESET} Bazel"
    [ "$ENABLE_ANDROID" = true ] && echo -e "  ${GREEN}✓${RESET} Android SDK"
    [ "$ENABLE_NODE" = true ] && echo -e "  ${GREEN}✓${RESET} Node.js 20.x"
    [ "$ENABLE_PYTHON" = true ] && echo -e "  ${GREEN}✓${RESET} Python 3.11"
    [ "$ENABLE_DOTNET" = true ] && echo -e "  ${GREEN}✓${RESET} .NET SDK 6.0/8.0"
    [ "$ENABLE_AWS_CLI" = true ] && echo -e "  ${GREEN}✓${RESET} AWS CLI v2"
    [ "$ENABLE_AWS_BATCH" = true ] && echo -e "  ${GREEN}✓${RESET} AWS Batch support"

    if [ "$ENABLE_GIT_SSH" = true ] || [ "$ENABLE_GIT_HTTPS" = true ]; then
        local auth_types=()
        [ "$ENABLE_GIT_SSH" = true ] && auth_types+=("SSH")
        [ "$ENABLE_GIT_HTTPS" = true ] && auth_types+=("HTTPS")
        echo -e "  ${GREEN}✓${RESET} Git authentication: ${auth_types[*]}"
    fi

    [ "$GENERATE_DOCKER_COMPOSE" = true ] && echo -e "  ${GREEN}✓${RESET} Docker Compose configuration"

    echo ""

    # Generate files
    if ask_yes_no "Generate Docker environment with this configuration?" "Yes, generate now" "No, cancel"; then
        clear
        generate_dockerfile

        if [ "$GENERATE_DOCKER_COMPOSE" = true ]; then
            generate_docker_compose
        fi

        show_combined_summary
    else
        echo -e "\n${YELLOW}Docker environment generation cancelled.${RESET}\n"
        if [ "$REPOS_CSV_REUSED" = true ]; then
            echo "Using existing repos.csv at: $OUTPUT_FILE"
        else
            echo "repos.csv was generated successfully at: $OUTPUT_FILE"
        fi
        exit 0
    fi
}

# Run main
main "$@"
