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
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../diagnose.sh" --functions-only
fi

section "Dependency repositories"

# Allow skipping
if [ "${SKIP_DEPENDENCY_REPOS:-}" = "true" ]; then
    info "Skipped: SKIP_DEPENDENCY_REPOS=true"
    return 0 2>/dev/null || exit 0
fi

# Find the CSV file
find_repos_csv() {
    local paths=(
        "${DEPENDENCY_REPOS_CSV:-}"
        "./dependency-repos.csv"
        "/app/dependency-repos.csv"
    )

    for path in "${paths[@]}"; do
        if [ -n "$path" ] && [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

REPOS_CSV=$(find_repos_csv)

if [ -z "$REPOS_CSV" ]; then
    info "Skipped: No dependency-repos.csv found"
    info "Create dependency-repos.csv to test Gradle/Maven dependency repositories"
    return 0 2>/dev/null || exit 0
fi

info "Using: $REPOS_CSV"

# Expand environment variable references in a string
# Supports ${VAR} syntax
expand_env_vars() {
    local value="$1"
    # Replace ${VAR} with actual env var values
    while [[ "$value" =~ \$\{([^}]+)\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value="${!var_name:-}"
        value="${value/\$\{$var_name\}/$var_value}"
    done
    echo "$value"
}

# Test a single repository with latency measurement
test_repo() {
    local url="$1"
    local username="$2"
    local password="$3"
    local token="$4"

    # Expand env vars in credentials
    username=$(expand_env_vars "$username")
    password=$(expand_env_vars "$password")
    token=$(expand_env_vars "$token")

    # Build curl args for auth
    local curl_args=()
    local auth_info=""

    if [ -n "$token" ]; then
        curl_args+=(-H "Authorization: Bearer $token")
        auth_info=" (bearer auth)"
    elif [ -n "$username" ] && [ -n "$password" ]; then
        curl_args+=(-u "${username}:${password}")
        auth_info=" (basic auth)"
    fi

    # Extract host for display
    local host
    host=$(echo "$url" | sed 's|.*://||' | cut -d/ -f1)

    # Quick connectivity check first
    local test_path="org/apache/maven/plugins/maven-metadata.xml"
    local test_url="${url%/}/$test_path"
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "${curl_args[@]}" "$test_url" 2>/dev/null)
    local curl_exit=$?

    if [ $curl_exit -ne 0 ] || [ "$http_code" = "000" ]; then
        fail "$host: unreachable"
        info "URL: $url"
        return 1
    elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        if [ -n "$username" ] || [ -n "$token" ]; then
            fail "$host: authentication failed (HTTP $http_code)"
        else
            warn "$host: requires authentication (HTTP $http_code)"
            info "Add credentials to dependency-repos.csv"
        fi
        return 1
    fi

    # Run full latency test
    test_repo_latency "$host" "$url" "$test_path" "${curl_args[@]}"

    case "$LATENCY_RESULT" in
        failed)
            fail "$host: latency test failed"
            return 1
            ;;
        high)
            warn "$host: HIGH latency avg=${LATENCY_AVG}ms (min=${LATENCY_MIN}ms max=${LATENCY_MAX}ms)${auth_info}"
            info "Consider using a closer mirror"
            ;;
        elevated)
            pass "$host: avg=${LATENCY_AVG}ms (min=${LATENCY_MIN}ms max=${LATENCY_MAX}ms)${auth_info}"
            info "Latency slightly elevated"
            ;;
        *)
            pass "$host: avg=${LATENCY_AVG}ms (min=${LATENCY_MIN}ms max=${LATENCY_MAX}ms)${auth_info}"
            ;;
    esac
    return 0
}

# Parse CSV and test each repository
REPO_COUNT=0
HEADER_SKIPPED=false

while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Skip header row
    if [ "$HEADER_SKIPPED" = false ]; then
        if [[ "$line" =~ ^url, ]]; then
            HEADER_SKIPPED=true
            continue
        fi
        HEADER_SKIPPED=true
    fi

    # Parse CSV fields (handle quoted fields with commas)
    # Simple parsing - assumes no commas within fields
    IFS=',' read -r url username password token <<< "$line"

    # Trim whitespace
    url=$(echo "$url" | xargs)
    username=$(echo "$username" | xargs)
    password=$(echo "$password" | xargs)
    token=$(echo "$token" | xargs)

    if [ -n "$url" ]; then
        test_repo "$url" "$username" "$password" "$token"
        ((REPO_COUNT++))
    fi
done < "$REPOS_CSV"

if [ "$REPO_COUNT" -eq 0 ]; then
    info "No repositories found in $REPOS_CSV"
fi
