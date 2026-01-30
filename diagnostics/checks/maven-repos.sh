#!/bin/bash
# Maven repository checks: connectivity to dependency repositories
#
# Tests connectivity and latency to Maven repositories configured in settings.xml.
# This helps identify network issues that could slow down or fail builds.
#
# Environment variables:
#   MAVEN_SETTINGS       Path to settings.xml (overrides default locations)
#   SKIP_MAVEN_REPOS     Skip this check entirely

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../diagnose.sh" --functions-only
fi

# Source latency testing library
source "$(dirname "$0")/../lib/latency.sh"

section "Maven repositories"

# Allow skipping
if [ "${SKIP_MAVEN_REPOS:-}" = "true" ]; then
    info "Skipped: SKIP_MAVEN_REPOS=true"
    return 0 2>/dev/null || exit 0
fi

# Try to get settings.xml path from mod CLI config
get_cli_settings_path() {
    if check_command mod; then
        # mod config build maven settings show outputs the path
        local cli_output
        cli_output=$(mod config build maven settings show 2>/dev/null)
        # Extract path from output (usually last line or after "Maven settings:")
        echo "$cli_output" | grep -oE '(/[^ ]+settings\.xml|~/.m2/settings\.xml)' | head -1 | sed "s|^~|$HOME|"
    fi
}

# Find settings.xml
find_settings_xml() {
    # Priority order:
    # 1. MAVEN_SETTINGS env var
    # 2. mod CLI configured path
    # 3. Standard locations
    local paths=(
        "${MAVEN_SETTINGS:-}"
        "$(get_cli_settings_path)"
        "$HOME/.m2/settings.xml"
        "/root/.m2/settings.xml"
        "${MAVEN_HOME:-/usr/share/maven}/conf/settings.xml"
        "/app/maven/settings.xml"
        "./maven/settings.xml"
    )

    for path in "${paths[@]}"; do
        if [ -n "$path" ] && [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

SETTINGS_XML=$(find_settings_xml)

if [ -z "$SETTINGS_XML" ]; then
    info "Skipped: No settings.xml found"
    info "Searched: ~/.m2/settings.xml, \$MAVEN_HOME/conf/settings.xml, ./maven/settings.xml"
    return 0 2>/dev/null || exit 0
fi

info "Using: $SETTINGS_XML"

# Simple XML value extraction (works without xmllint)
# Usage: xml_value "tag" "content"
xml_value() {
    local tag="$1"
    local content="$2"
    echo "$content" | sed -n "s/.*<${tag}>\([^<]*\)<\/${tag}>.*/\1/p" | head -1
}

# Extract all values for a tag
xml_values() {
    local tag="$1"
    local content="$2"
    echo "$content" | sed -n "s/.*<${tag}>\([^<]*\)<\/${tag}>.*/\1/p"
}

# Read settings.xml
SETTINGS_CONTENT=$(cat "$SETTINGS_XML" | tr -d '\n' | tr -s ' ')

# Extract active profiles
ACTIVE_PROFILES=$(xml_values "activeProfile" "$SETTINGS_CONTENT")

# Extract mirrors (these override repository URLs)
# Format: mirrorOf -> url mapping
declare -A MIRRORS
declare -A MIRROR_IDS
while read -r mirror_block; do
    if [ -n "$mirror_block" ]; then
        mirror_id=$(xml_value "id" "$mirror_block")
        mirror_url=$(xml_value "url" "$mirror_block")
        mirror_of=$(xml_value "mirrorOf" "$mirror_block")
        if [ -n "$mirror_url" ] && [ -n "$mirror_of" ]; then
            MIRRORS["$mirror_of"]="$mirror_url"
            MIRROR_IDS["$mirror_of"]="$mirror_id"
        fi
    fi
done < <(echo "$SETTINGS_CONTENT" | grep -oP '<mirror>.*?</mirror>' 2>/dev/null || echo "$SETTINGS_CONTENT" | sed 's/<mirror>/\n<mirror>/g' | grep '<mirror>')

# Extract servers (credentials)
declare -A SERVER_USERS
declare -A SERVER_PASSWORDS
while read -r server_block; do
    if [ -n "$server_block" ]; then
        server_id=$(xml_value "id" "$server_block")
        server_user=$(xml_value "username" "$server_block")
        server_pass=$(xml_value "password" "$server_block")
        if [ -n "$server_id" ]; then
            SERVER_USERS["$server_id"]="$server_user"
            SERVER_PASSWORDS["$server_id"]="$server_pass"
        fi
    fi
done < <(echo "$SETTINGS_CONTENT" | grep -oP '<server>.*?</server>' 2>/dev/null || echo "$SETTINGS_CONTENT" | sed 's/<server>/\n<server>/g' | grep '<server>')

# Extract repositories from profiles
declare -A REPOS
while read -r profile_block; do
    if [ -n "$profile_block" ]; then
        profile_id=$(xml_value "id" "$profile_block")
        # Check if this profile is active
        is_active=false
        for active in $ACTIVE_PROFILES; do
            if [ "$profile_id" = "$active" ]; then
                is_active=true
                break
            fi
        done

        # Also check for activeByDefault
        if echo "$profile_block" | grep -q "<activeByDefault>true</activeByDefault>"; then
            is_active=true
        fi

        if [ "$is_active" = true ]; then
            # Extract repositories from this profile
            while read -r repo_block; do
                if [ -n "$repo_block" ]; then
                    repo_id=$(xml_value "id" "$repo_block")
                    repo_url=$(xml_value "url" "$repo_block")
                    if [ -n "$repo_id" ] && [ -n "$repo_url" ]; then
                        REPOS["$repo_id"]="$repo_url"
                    fi
                fi
            done < <(echo "$profile_block" | grep -oP '<repository>.*?</repository>' 2>/dev/null || echo "$profile_block" | sed 's/<repository>/\n<repository>/g' | grep '<repository>')
        fi
    fi
done < <(echo "$SETTINGS_CONTENT" | grep -oP '<profile>.*?</profile>' 2>/dev/null || echo "$SETTINGS_CONTENT" | sed 's/<profile>/\n<profile>/g' | grep '<profile>')

# Add Maven Central as default (always checked)
REPOS["central"]="https://repo.maven.apache.org/maven2"

# Check for * mirror (mirrors all repositories)
if [ -n "${MIRRORS["*"]:-}" ]; then
    info "Mirror configured for all repositories: ${MIRRORS["*"]}"
fi

# Test each repository with comprehensive latency measurement
test_repo() {
    local repo_id="$1"
    local repo_url="$2"
    local effective_url="$repo_url"
    local effective_id="$repo_id"
    local display_name="$repo_id"

    # Check if this repo is mirrored
    if [ -n "${MIRRORS["$repo_id"]:-}" ]; then
        effective_url="${MIRRORS["$repo_id"]}"
        effective_id="${MIRROR_IDS["$repo_id"]}"
        display_name="$repo_id (via mirror: $effective_id)"
    elif [ -n "${MIRRORS["*"]:-}" ]; then
        effective_url="${MIRRORS["*"]}"
        effective_id="${MIRROR_IDS["*"]}"
        display_name="$repo_id (via mirror: $effective_id)"
    fi

    # Get credentials if available
    local user="${SERVER_USERS["$effective_id"]:-}"
    local pass="${SERVER_PASSWORDS["$effective_id"]:-}"

    # Build curl args for auth
    local curl_args=()

    if [ -n "$user" ] && [ -n "$pass" ]; then
        # Check for Maven encrypted password
        if [[ "$pass" == "{"*"}" ]]; then
            info "$repo_id: encrypted password detected (cannot test auth)"
        else
            curl_args+=(-u "${user}:${pass}")
        fi
    fi

    # Quick connectivity check first
    local test_url="${effective_url%/}/org/apache/maven/plugins/maven-metadata.xml"
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "${curl_args[@]}" "$test_url" 2>/dev/null)
    local curl_exit=$?

    if [ $curl_exit -ne 0 ] || [ "$http_code" = "000" ]; then
        fail "$display_name: unreachable"
        info "URL: $effective_url"
        return 1
    elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        if [ -n "$user" ]; then
            fail "$display_name: authentication failed (HTTP $http_code)"
        else
            warn "$display_name: requires authentication (HTTP $http_code)"
            info "Configure server credentials in settings.xml"
        fi
        return 1
    fi

    # Run comprehensive latency test
    run_comprehensive_latency_test "$display_name" "$effective_url" "${curl_args[@]}"
}

# Test all discovered repositories
REPO_COUNT=0
TESTED_URLS=()

for repo_id in "${!REPOS[@]}"; do
    repo_url="${REPOS[$repo_id]}"

    # Determine effective URL (after mirror resolution)
    effective_url="$repo_url"
    if [ -n "${MIRRORS["$repo_id"]:-}" ]; then
        effective_url="${MIRRORS["$repo_id"]}"
    elif [ -n "${MIRRORS["*"]:-}" ]; then
        effective_url="${MIRRORS["*"]}"
    fi

    # Skip if we've already tested this URL (mirrors can cause duplicates)
    skip=false
    for tested in "${TESTED_URLS[@]}"; do
        if [ "$tested" = "$effective_url" ]; then
            skip=true
            break
        fi
    done

    if [ "$skip" = false ]; then
        test_repo "$repo_id" "$repo_url"
        TESTED_URLS+=("$effective_url")
        ((REPO_COUNT++))
    fi
done

if [ "$REPO_COUNT" -eq 0 ]; then
    info "No repositories found in active profiles"
    info "Only Maven Central will be used"
fi
