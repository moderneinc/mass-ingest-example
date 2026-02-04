#!/bin/bash
# Dependency repository checks: connectivity to user-specified repositories
#
# Tests connectivity and latency to dependency repositories listed in a CSV file.
# Use this for Gradle repos or any Maven repos not covered by settings.xml.
#
# CSV format (dependency-repos.csv):
#   url,username,password,token
#   https://nexus.example.com/releases,user,pass,
#   https://artifactory.example.com/libs,,,bearer-token
#   https://public-repo.example.com,,,
#
# Credentials can use environment variable references: ${ENV_VAR}
#
# Environment variables:
#   DEPENDENCY_REPOS_CSV   Path to CSV file (default: ./dependency-repos.csv)
#   SKIP_DEPENDENCY_REPOS  Skip this check entirely

# Source shared functions if run directly
if [[ -z "$SCRIPT_DIR" ]]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

# Source latency testing library
source "${SCRIPT_DIR:-$(dirname "$0")/..}/lib/latency.sh"

section "Dependency repositories"

# Allow skipping
if [[ "${SKIP_DEPENDENCY_REPOS:-}" == "true" ]]; then
    info "Skipped: SKIP_DEPENDENCY_REPOS=true"
    return 0 2>/dev/null || exit 0
fi

# Find the dependency repos CSV file
find_dependency_repos_csv() {
    for path in \
        "${DEPENDENCY_REPOS_CSV:-}" \
        "./dependency-repos.csv" \
        "/app/dependency-repos.csv"
    do
        if [[ -n "$path" ]] && [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

DEP_REPOS_CSV=$(find_dependency_repos_csv)

if [[ -z "$DEP_REPOS_CSV" ]]; then
    info "Skipped: No dependency-repos.csv found"
    info "Create dependency-repos.csv to test Gradle/Maven dependency repositories"
    return 0 2>/dev/null || exit 0
fi

info "Using: $DEP_REPOS_CSV"

# Expand environment variable references in a string
# Supports ${VAR} syntax using safe bash indirect expansion
expand_env_vars() {
    local value="$1"
    # Match ${VAR} pattern and replace with env var value
    while [[ "$value" =~ \$\{([^}]+)\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value="${!var_name:-}"
        value="${value/\$\{$var_name\}/$var_value}"
    done
    echo "$value"
}

# Test a single repository with comprehensive latency measurement
test_repo() {
    url="$1"
    username="$2"
    password="$3"
    token="$4"

    # Expand env vars in credentials
    username=$(expand_env_vars "$username")
    password=$(expand_env_vars "$password")
    token=$(expand_env_vars "$token")

    # Build curl auth args as array (safe for special characters)
    local -a curl_auth=()

    if [[ -n "$token" ]]; then
        curl_auth+=(-H "Authorization: Bearer $token")
    elif [[ -n "$username" ]] && [[ -n "$password" ]]; then
        curl_auth+=(-u "${username}:${password}")
    fi

    # Extract host for display
    host=$(echo "$url" | sed 's|.*://||' | cut -d/ -f1)

    # Quick connectivity check first
    test_url="${url%/}/org/apache/maven/plugins/maven-metadata.xml"
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "${curl_auth[@]}" "$test_url" 2>/dev/null)
    curl_exit=$?

    if [[ $curl_exit -ne 0 ]] || [[ "$http_code" == "000" ]]; then
        fail "$host: unreachable"
        info "URL: $url"
        return 1
    elif [[ "$http_code" == "401" ]] || [[ "$http_code" == "403" ]]; then
        if [[ -n "$username" ]] || [[ -n "$token" ]]; then
            fail "$host: authentication failed (HTTP $http_code)"
        else
            warn "$host: requires authentication (HTTP $http_code)"
            info "Add credentials to dependency-repos.csv"
        fi
        return 1
    fi

    # Run comprehensive latency test
    run_comprehensive_latency_test "$host" "$url"
}

# Parse CSV and test each repository
REPO_COUNT=0
HEADER_SKIPPED=false

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    case "$line" in
        ''|'#'*|' '*'#'*) continue ;;
    esac

    # Skip header row
    if [[ "$HEADER_SKIPPED" == false ]]; then
        case "$line" in
            url,*) HEADER_SKIPPED=true; continue ;;
        esac
        HEADER_SKIPPED=true
    fi

    # Parse CSV fields (handle quoted fields with commas)
    # Simple parsing - assumes no commas within fields
    # Use sed to trim leading/trailing whitespace (safer than xargs with special chars)
    url=$(echo "$line" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    username=$(echo "$line" | cut -d',' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    password=$(echo "$line" | cut -d',' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    token=$(echo "$line" | cut -d',' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ -n "$url" ]]; then
        test_repo "$url" "$username" "$password" "$token"
        REPO_COUNT=$((REPO_COUNT + 1))
    fi
done < "$DEP_REPOS_CSV"

if [[ "$REPO_COUNT" -eq 0 ]]; then
    info "No repositories found in $DEP_REPOS_CSV"
fi
