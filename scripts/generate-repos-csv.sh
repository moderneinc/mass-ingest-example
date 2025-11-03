#!/bin/bash

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCHERS_DIR="$SCRIPT_DIR/repository-fetchers"

# Colors for better UX
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
GRAY='\033[2m'
RESET='\033[0m'
BOLD='\033[1m'

# Configuration storage
declare -a REPO_SOURCES
declare -a FETCH_RESULTS
OUTPUT_FILE="repos.csv"
USE_HIERARCHICAL_ORGS=false
NORMALIZE_CSV=true

# Temp directory for CSV files
TEMP_DIR=""

# Helper variable for choice results
CHOICE_RESULT=0

# Helper functions
print_header() {
    echo -e "${CYAN}${BOLD}$1${RESET}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

print_section() {
    echo -e "\n${CYAN}${BOLD}▶ $1${RESET}\n"
}

print_context() {
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
    local response

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

ask_input() {
    local prompt="$1"
    local default="$2"
    local value

    if [ -n "$default" ]; then
        read -p "$(echo -e "${BOLD}$prompt${RESET} [$default]: ")" value
        value=$(echo "$value" | xargs)
        echo "${value:-$default}"
    else
        while true; do
            read -p "$(echo -e "${BOLD}$prompt${RESET}: ")" value
            value=$(echo "$value" | xargs)
            if [ -n "$value" ]; then
                echo "$value"
                return
            fi
            echo -e "${RED}This field cannot be empty. Please enter a value.${RESET}"
        done
    fi
}

ask_secret() {
    local prompt="$1"
    local value

    while true; do
        read -s -p "$(echo -e "${BOLD}$prompt${RESET}: ")" value
        echo "" >&2  # newline after hidden input (to stderr, not return value)
        value=$(echo "$value" | xargs)
        if [ -n "$value" ]; then
            echo "$value"
            return
        fi
        echo -e "${RED}This field cannot be empty. Please enter a value.${RESET}" >&2
    done
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
        error_msg=$(grep -m 1 "Error:" "$output_file" | sed 's/^Error: //')
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
    local cmd_args=("${@:1:$(($#-1))}")  # All arguments except last

    # Run command in background
    "${cmd_args[@]}" > "$output_file" 2>&1 &
    local pid=$!

    # Show spinner while running
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

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# Welcome screen
show_welcome() {
    clear

    # Moderne logo
    echo "   ▛▀▀▚▖  ▗▄▟▜"
    echo "   ▌   ▜▄▟▀  ▐"
    echo "   ▛▀▀█▀▛▀▀▀▀▜"
    echo "   ▌▟▀  ▛▀▀▀▀▜"
    echo "   ▀▀▀▀▀▀▀▀▀▀▀"
    echo ""

    print_header "Mass Ingest - repos.csv Generator"

    echo -e "Ready to build your repository catalog? This wizard creates a repos.csv file"
    echo -e "that tells Moderne CLI exactly which repositories to process."
    echo ""
    echo -e "${CYAN}${BOLD}What is repos.csv?${RESET}"
    echo ""
    echo -e "A CSV file that lists all repositories you want to analyze and transform."
    echo -e "Each row describes a single repository with its clone URL, branch, and"
    echo -e "organizational structure."
    echo ""
    echo -e "${CYAN}${BOLD}Example repos.csv:${RESET}"
    echo ""
    echo -e "${GRAY}  cloneUrl,branch,origin,path,org1,org2${RESET}"
    echo -e "${GRAY}  https://github.com/openrewrite/rewrite,main,github.com,openrewrite/rewrite,openrewrite,ALL${RESET}"
    echo -e "${GRAY}  https://github.com/openrewrite/rewrite-spring,main,github.com,openrewrite/rewrite-spring,openrewrite,ALL${RESET}"
    echo ""
    echo -e "${CYAN}${BOLD}How it works:${RESET}"
    echo ""
    echo -e "  ${CYAN}1.${RESET} ${BOLD}Choose SCM providers${RESET} - GitHub, GitLab, Azure DevOps, Bitbucket"
    echo -e "  ${CYAN}2.${RESET} ${BOLD}Authenticate${RESET} - provide access tokens or credentials"
    echo -e "  ${CYAN}3.${RESET} ${BOLD}Fetch repositories${RESET} - automatically discover all your repos"
    echo -e "  ${CYAN}4.${RESET} ${BOLD}Generate CSV${RESET} - create repos.csv ready for mass-ingest"
    echo ""

    read -p "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

# GitHub configuration
configure_github() {
    clear
    print_section "GitHub Configuration"

    print_context "We'll fetch all repositories from a GitHub organization.

GitHub CLI (gh) will be used for authentication.
Make sure you've already run 'gh auth login'.
Learn more: https://cli.github.com/manual/gh_auth_login"

    ask_choice "Which GitHub service?" "GitHub.com (cloud)" "GitHub Enterprise Server (on-prem)"

    local github_url="https://github.com"
    if [ "$CHOICE_RESULT" -eq 1 ]; then
        github_url=$(ask_input "GitHub Enterprise Server URL")
    fi

    local org=$(ask_input "Organization or user name")

    echo ""
    print_success "GitHub configuration complete"

    # Fetch immediately
    fetch_from_github "$github_url" "$org"
}

fetch_from_github() {
    local github_url="$1"
    local org="$2"

    print_section "Fetching from GitHub: $org"

    local csv_file="$TEMP_DIR/github_${org}.csv"

    if [[ "$github_url" != "https://github.com" ]]; then
        export GH_HOST="${github_url#https://}"
    fi

    if run_with_progress "Fetching repositories" bash "$FETCHERS_DIR/github.sh" "$org" "$csv_file"; then
        local count=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l | tr -d ' ')
        print_success "Fetched $count repositories from GitHub"

        # Show formatted preview
        echo ""
        echo -e "${CYAN}Preview (first 2 repos):${RESET}"
        tail -n +2 "$csv_file" | head -2 | while IFS=, read -r cloneUrl branch origin path; do
            # Remove quotes for display
            cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
            branch=$(echo "$branch" | sed 's/^"//;s/"$//')
            origin=$(echo "$origin" | sed 's/^"//;s/"$//')
            path=$(echo "$path" | sed 's/^"//;s/"$//')
            echo -e "${GRAY}  • $path${RESET} ${CYAN}($branch)${RESET}"
        done

        REPO_SOURCES+=("$csv_file")
        FETCH_RESULTS+=("GitHub:success:$count")
    else
        local error_detail=$(parse_error_message "$csv_file")
        print_error "Failed to fetch repositories from GitHub"
        if [ -n "$error_detail" ]; then
            print_warning "$error_detail"
        else
            print_warning "Make sure 'gh auth login' is configured correctly"
        fi
        FETCH_RESULTS+=("GitHub:failure:0")
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

    print_context "We'll fetch repositories from GitLab.
You can fetch from a specific group or all accessible repositories."

    ask_choice "Which GitLab service?" "GitLab.com (cloud)" "Self-hosted GitLab"

    local gitlab_url="https://gitlab.com"
    if [ "$CHOICE_RESULT" -eq 1 ]; then
        gitlab_url=$(ask_input "GitLab instance URL")
    fi

    local group=""
    if ask_yes_no "Fetch from a specific group?"; then
        group=$(ask_input "Group path (e.g., moderneinc/nested)")
    fi

    print_context "You'll need a GitLab Personal Access Token with 'read_api' scope.
Create one at: ${gitlab_url}/-/profile/personal_access_tokens"

    local token=$(ask_secret "GitLab access token")

    echo ""
    print_success "GitLab configuration complete"

    # Fetch immediately
    fetch_from_gitlab "$gitlab_url" "$group" "$token"
}

fetch_from_gitlab() {
    local gitlab_url="$1"
    local group="$2"
    local token="$3"

    local display_name="GitLab"
    if [ -n "$group" ]; then
        display_name="GitLab: $group"
    fi

    print_section "Fetching from $display_name"

    local csv_file="$TEMP_DIR/gitlab_$(echo "$group" | tr '/' '_').csv"

    local cmd_args=(bash "$FETCHERS_DIR/gitlab.sh" -t "$token" -h "$gitlab_url")
    if [ -n "$group" ]; then
        cmd_args+=(-g "$group")
    fi

    if run_with_progress "Fetching repositories" "${cmd_args[@]}" "$csv_file"; then
        local count=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l | tr -d ' ')
        print_success "Fetched $count repositories from GitLab"

        # Show formatted preview
        echo ""
        echo -e "${CYAN}Preview (first 2 repos):${RESET}"
        tail -n +2 "$csv_file" | head -2 | while IFS=, read -r cloneUrl branch origin path; do
            # Remove quotes for display
            cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
            branch=$(echo "$branch" | sed 's/^"//;s/"$//')
            origin=$(echo "$origin" | sed 's/^"//;s/"$//')
            path=$(echo "$path" | sed 's/^"//;s/"$//')
            echo -e "${GRAY}  • $path${RESET} ${CYAN}($branch)${RESET}"
        done

        REPO_SOURCES+=("$csv_file")
        FETCH_RESULTS+=("$display_name:success:$count")
    else
        local error_detail=$(parse_error_message "$csv_file")
        print_error "Failed to fetch repositories from GitLab"
        if [ -n "$error_detail" ]; then
            print_warning "$error_detail"
        else
            print_warning "Check that your token has 'read_api' scope and is valid"
        fi
        FETCH_RESULTS+=("$display_name:failure:0")
    fi

    unset AUTH_TOKEN
    echo ""
}

# Azure DevOps configuration
configure_azure() {
    clear
    print_section "Azure DevOps Configuration"

    print_context "We'll fetch repositories from an Azure DevOps project.
The Azure CLI (az) will be used for authentication.

Make sure you've already run 'az login' to authenticate.
Learn more: https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli"

    local organization=$(ask_input "Organization name")
    local project=$(ask_input "Project name")

    local use_ssh=false
    if ask_yes_no "Use SSH URLs instead of HTTPS?"; then
        use_ssh=true
    fi

    echo ""
    print_success "Azure DevOps configuration complete"

    # Fetch immediately
    fetch_from_azure "$organization" "$project" "$use_ssh"
}

fetch_from_azure() {
    local organization="$1"
    local project="$2"
    local use_ssh="$3"

    print_section "Fetching from Azure DevOps: $organization/$project"

    local csv_file="$TEMP_DIR/azure_${organization}_${project}.csv"

    local cmd_args=(bash "$FETCHERS_DIR/azure-devops.sh" -o "$organization" -p "$project")
    if [ "$use_ssh" = true ]; then
        cmd_args+=(-s)
    fi

    if run_with_progress "Fetching repositories" "${cmd_args[@]}" "$csv_file"; then
        local count=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l | tr -d ' ')
        print_success "Fetched $count repositories from Azure DevOps"

        # Show formatted preview
        echo ""
        echo -e "${CYAN}Preview (first 2 repos):${RESET}"
        tail -n +2 "$csv_file" | head -2 | while IFS=, read -r cloneUrl branch origin path; do
            # Remove quotes for display
            cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
            branch=$(echo "$branch" | sed 's/^"//;s/"$//')
            origin=$(echo "$origin" | sed 's/^"//;s/"$//')
            path=$(echo "$path" | sed 's/^"//;s/"$//')
            echo -e "${GRAY}  • $path${RESET} ${CYAN}($branch)${RESET}"
        done

        REPO_SOURCES+=("$csv_file")
        FETCH_RESULTS+=("Azure DevOps:success:$count")
    else
        local error_detail=$(parse_error_message "$csv_file")
        print_error "Failed to fetch repositories from Azure DevOps"
        if [ -n "$error_detail" ]; then
            print_warning "$error_detail"
        else
            print_warning "Make sure 'az login' is configured correctly"
        fi
        FETCH_RESULTS+=("Azure DevOps:failure:0")
    fi

    echo ""
}

# Bitbucket Data Center configuration
configure_bitbucket_datacenter() {
    clear
    print_section "Bitbucket Data Center Configuration"

    print_context "We'll fetch all repositories from your Bitbucket Server/Data Center instance."

    local bitbucket_url=$(ask_input "Bitbucket Server URL")

    local use_ssh=false
    if ask_yes_no "Use SSH URLs instead of HTTPS?"; then
        use_ssh=true
    fi

    echo ""
    print_context "You'll need a Bitbucket HTTP Access Token with repository read permissions.
To create one: go to your profile > Manage account > Http access tokens"

    local token=$(ask_secret "Bitbucket access token")

    echo ""
    print_success "Bitbucket Data Center configuration complete"

    # Fetch immediately
    fetch_from_bitbucket_datacenter "$bitbucket_url" "$token" "$use_ssh"
}

fetch_from_bitbucket_datacenter() {
    local bitbucket_url="$1"
    local token="$2"
    local use_ssh="$3"

    print_section "Fetching from Bitbucket Data Center"

    local csv_file="$TEMP_DIR/bitbucket_datacenter.csv"

    local protocol="http"
    if [ "$use_ssh" = true ]; then
        protocol="ssh"
    fi

    if run_with_progress "Fetching repositories" bash "$FETCHERS_DIR/bitbucket-data-center.sh" "$bitbucket_url" "$token" "$protocol" "$csv_file"; then
        local count=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l | tr -d ' ')
        print_success "Fetched $count repositories from Bitbucket"

        # Show formatted preview
        echo ""
        echo -e "${CYAN}Preview (first 2 repos):${RESET}"
        tail -n +2 "$csv_file" | head -2 | while IFS=, read -r cloneUrl branch origin path; do
            # Remove quotes for display
            cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
            branch=$(echo "$branch" | sed 's/^"//;s/"$//')
            origin=$(echo "$origin" | sed 's/^"//;s/"$//')
            path=$(echo "$path" | sed 's/^"//;s/"$//')
            echo -e "${GRAY}  • $path${RESET} ${CYAN}($branch)${RESET}"
        done

        REPO_SOURCES+=("$csv_file")
        FETCH_RESULTS+=("Bitbucket Data Center:success:$count")
    else
        local error_detail=$(parse_error_message "$csv_file")
        print_error "Failed to fetch repositories from Bitbucket"
        if [ -n "$error_detail" ]; then
            print_warning "$error_detail"
        else
            print_warning "Check that your HTTP Access Token has repository read permissions"
        fi
        FETCH_RESULTS+=("Bitbucket Data Center:failure:0")
    fi

    unset AUTH_TOKEN
    unset CLONE_PROTOCOL
    echo ""
}

# Bitbucket Cloud configuration
configure_bitbucket_cloud() {
    clear
    print_section "Bitbucket Cloud Configuration"

    print_context "We'll fetch repositories from a Bitbucket Cloud workspace."

    local workspace=$(ask_input "Workspace name")

    print_context "You'll need a Bitbucket API token with repository read permissions.
Create one at: https://bitbucket.org/account/settings/api-tokens/"

    local username=$(ask_input "Bitbucket username")
    local api_token=$(ask_secret "Bitbucket API token")

    local use_ssh=false
    if ask_yes_no "Use SSH URLs instead of HTTPS?"; then
        use_ssh=true
    fi

    echo ""
    print_success "Bitbucket Cloud configuration complete"

    # Fetch immediately
    fetch_from_bitbucket_cloud "$workspace" "$username" "$api_token" "$use_ssh"
}

fetch_from_bitbucket_cloud() {
    local workspace="$1"
    local username="$2"
    local api_token="$3"
    local use_ssh="$4"

    print_section "Fetching from Bitbucket Cloud: $workspace"

    local csv_file="$TEMP_DIR/bitbucket_cloud_${workspace}.csv"

    local protocol="https"
    if [ "$use_ssh" = true ]; then
        protocol="ssh"
    fi

    if run_with_progress "Fetching repositories" bash "$FETCHERS_DIR/bitbucket-cloud.sh" -u "$username" -p "$api_token" -c "$protocol" "$workspace" "$csv_file"; then
        local count=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l | tr -d ' ')
        print_success "Fetched $count repositories from Bitbucket Cloud"

        # Show formatted preview
        echo ""
        echo -e "${CYAN}Preview (first 2 repos):${RESET}"
        tail -n +2 "$csv_file" | head -2 | while IFS=, read -r cloneUrl branch origin path; do
            # Remove quotes for display
            cloneUrl=$(echo "$cloneUrl" | sed 's/^"//;s/"$//')
            branch=$(echo "$branch" | sed 's/^"//;s/"$//')
            origin=$(echo "$origin" | sed 's/^"//;s/"$//')
            path=$(echo "$path" | sed 's/^"//;s/"$//')
            echo -e "${GRAY}  • $path${RESET} ${CYAN}($branch)${RESET}"
        done

        REPO_SOURCES+=("$csv_file")
        FETCH_RESULTS+=("Bitbucket Cloud:success:$count")
    else
        local error_detail=$(parse_error_message "$csv_file")
        print_error "Failed to fetch repositories from Bitbucket Cloud"
        if [ -n "$error_detail" ]; then
            print_warning "$error_detail"
        else
            print_warning "Check that your API token has repository read permissions and username is correct"
        fi
        FETCH_RESULTS+=("Bitbucket Cloud:failure:0")
    fi

    unset CLONE_PROTOCOL
    echo ""
}

# SCM provider selection
add_scm_providers() {
    while true; do
        clear
        print_section "SCM Provider Selection"

        ask_choice "Select an SCM provider to add:" \
            "GitHub" \
            "GitLab" \
            "Azure DevOps" \
            "Bitbucket Data Center / Server" \
            "Bitbucket Cloud"

        case $CHOICE_RESULT in
            0) configure_github ;;
            1) configure_gitlab ;;
            2) configure_azure ;;
            3) configure_bitbucket_datacenter ;;
            4) configure_bitbucket_cloud ;;
        esac

        echo ""
        if ! ask_yes_no "Do you want to add another SCM provider?"; then
            break
        fi
    done

    if [ ${#REPO_SOURCES[@]} -eq 0 ]; then
        print_error "No repositories were fetched. Exiting."
        exit 1
    fi
}

# Organization structure configuration
configure_org_structure() {
    clear
    print_section "Organization Structure"

    print_context "Repositories can be organized using org columns:
  - Simple: Use 'ALL' for a flat structure
  - Hierarchical: Extract org hierarchy from repository paths

Example hierarchical org columns for 'moderneinc/nested/sub/repo':
  org1=sub, org2=nested, org3=moderneinc, org4=ALL"

    if ask_yes_no "Use hierarchical organization structure?"; then
        USE_HIERARCHICAL_ORGS=true
        print_success "Using hierarchical organization structure"
    else
        USE_HIERARCHICAL_ORGS=false
        print_success "Using simple organization structure (ALL)"
    fi

    echo ""

    print_context "CSV normalization pads all rows with empty columns to match the maximum depth.
This ensures Excel and other tools can properly parse the file."

    if ask_yes_no "Normalize CSV for Excel compatibility?" "n"; then
        NORMALIZE_CSV=true
    else
        NORMALIZE_CSV=false
    fi
}

# Show fetch summary
show_fetch_summary() {
    if [ ${#FETCH_RESULTS[@]} -eq 0 ]; then
        return
    fi

    clear
    print_section "Fetch Summary"

    local total_success=0
    local total_failure=0
    local total_repos=0

    echo ""
    for result in "${FETCH_RESULTS[@]}"; do
        IFS=':' read -r provider status count <<< "$result"
        if [ "$status" = "success" ]; then
            echo -e "${GREEN}✓${RESET} ${BOLD}$provider${RESET}: $count repositories"
            ((total_success++))
            ((total_repos+=count))
        else
            echo -e "${RED}✗${RESET} ${BOLD}$provider${RESET}: Failed"
            ((total_failure++))
        fi
    done

    echo ""
    echo -e "${CYAN}Summary:${RESET}"
    echo -e "  • Successful providers: ${GREEN}$total_success${RESET}"
    if [ $total_failure -gt 0 ]; then
        echo -e "  • Failed providers: ${RED}$total_failure${RESET}"
    fi
    echo -e "  • Total repositories: ${BOLD}$total_repos${RESET}"
    echo ""

    read -p "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

# Generate the final repos.csv
generate_repos_csv() {
    print_section "Generating repos.csv"

    local temp_merged="$TEMP_DIR/merged.csv"
    local temp_data="$TEMP_DIR/data_with_orgs.txt"

    # First pass: Generate all data rows and track max org depth
    local max_org_depth=1
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

            if [ "$USE_HIERARCHICAL_ORGS" = true ]; then
                # Extract org hierarchy from path (deepest to shallowest)
                IFS='/' read -ra parts <<< "$path"
                local org_columns=()

                # Add path components in reverse (deepest first)
                for ((j=${#parts[@]}-1; j>=0; j--)); do
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

        # Build org column string
        local org_string=""
        for ((j=0; j<num_org_cols; j++)); do
            if [ $j -lt ${#org_columns[@]} ]; then
                org_string="$org_string,\"${org_columns[$j]}\""
            else
                # Only add empty columns if normalizing
                if [ "$NORMALIZE_CSV" = true ]; then
                    org_string="$org_string,"
                fi
            fi
        done

        echo "\"$cloneUrl\",\"$branch\",\"$origin\",\"$path\"$org_string" >> "$temp_merged"
    done < "$temp_data"

    # Copy to output file
    cp "$temp_merged" "$OUTPUT_FILE"

    local total_repos=$(tail -n +2 "$OUTPUT_FILE" | wc -l | tr -d ' ')

    echo ""
    print_success "Generated $OUTPUT_FILE with $total_repos repositories"
    echo ""
}

# Show next steps
show_next_steps() {
    clear
    print_header "Success! Your repos.csv is ready"

    echo -e "${GREEN}✓${RESET} Generated: ${BOLD}$OUTPUT_FILE${RESET}"
    echo ""
    echo -e "${CYAN}${BOLD}Next steps:${RESET}"
    echo ""
    echo -e "  ${CYAN}1.${RESET} Review the generated file:"
    echo -e "     ${GRAY}head $OUTPUT_FILE${RESET}"
    echo ""
    echo -e "  ${CYAN}2.${RESET} Use with Moderne CLI mass-ingest:"
    echo -e "     ${GRAY}docker run -v \$(pwd):/workspace moderne/moderne-cli:latest \\${RESET}"
    echo -e "     ${GRAY}  mass-ingest --repos /workspace/$OUTPUT_FILE \\${RESET}"
    echo -e "     ${GRAY}  --output /workspace/output${RESET}"
    echo ""
    echo -e "${CYAN}${BOLD}Learn more:${RESET}"
    echo -e "  https://docs.moderne.io/user-documentation/moderne-cli/how-to-guides/mass-ingest"
    echo ""
}

# Main flow
main() {
    # Create temp directory
    TEMP_DIR=$(mktemp -d)

    show_welcome
    add_scm_providers
    show_fetch_summary
    configure_org_structure
    generate_repos_csv
    show_next_steps
}

# Only run main if not being sourced for testing
if [ -z "$SKIP_MAIN" ]; then
    main "$@"
fi
