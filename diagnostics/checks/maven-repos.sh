#!/bin/sh
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
    . "$(dirname "$0")/../lib/core.sh"
fi

# Source latency testing library
. "${SCRIPT_DIR:-$(dirname "$0")/..}/lib/latency.sh"

section "Maven repositories"

# Allow skipping
if [ "${SKIP_MAVEN_REPOS:-}" = "true" ]; then
    info "Skipped: SKIP_MAVEN_REPOS=true"
    return 0 2>/dev/null || exit 0
fi

# Try to get settings.xml path from mod CLI config
get_cli_settings_path() {
    if check_command mod; then
        cli_output=$(mod config build maven settings show 2>/dev/null)
        echo "$cli_output" | grep -oE '(/[^ ]+settings\.xml|~/.m2/settings\.xml)' | head -1 | sed "s|^~|$HOME|"
    fi
}

# Find settings.xml
find_settings_xml() {
    # Check paths in order
    for path in \
        "${MAVEN_SETTINGS:-}" \
        "$(get_cli_settings_path)" \
        "$HOME/.m2/settings.xml" \
        "/root/.m2/settings.xml" \
        "${MAVEN_HOME:-/usr/share/maven}/conf/settings.xml" \
        "/app/maven/settings.xml" \
        "./maven/settings.xml"
    do
        if [ -n "$path" ] && [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

SETTINGS_XML=$(find_settings_xml)

# Simple XML value extraction
xml_value() {
    tag="$1"
    content="$2"
    echo "$content" | sed -n "s/.*<${tag}>\([^<]*\)<\/${tag}>.*/\1/p" | head -1
}

# Test a repository URL
test_maven_repo() {
    name="$1"
    url="$2"
    user="${3:-}"
    pass="${4:-}"

    curl_auth=""
    if [ -n "$user" ] && [ -n "$pass" ]; then
        case "$pass" in
            '{'*'}')
                info "$name: encrypted password detected (skipping auth test)"
                ;;
            *)
                curl_auth="-u ${user}:${pass}"
                ;;
        esac
    fi

    # Quick connectivity check
    test_url="${url%/}/org/apache/maven/plugins/maven-metadata.xml"
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 $curl_auth "$test_url" 2>/dev/null)
    curl_exit=$?

    if [ $curl_exit -ne 0 ] || [ "$http_code" = "000" ]; then
        fail "$name: unreachable"
        info "URL: $url"
        return 1
    elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        if [ -n "$user" ]; then
            fail "$name: authentication failed (HTTP $http_code)"
        else
            warn "$name: requires authentication (HTTP $http_code)"
            info "Configure server credentials in settings.xml"
        fi
        return 1
    fi

    # Run comprehensive latency test
    run_comprehensive_latency_test "$name" "$url"
}

# Always test Maven Central
info "Testing Maven Central..."
test_maven_repo "central" "https://repo.maven.apache.org/maven2"

# Parse settings.xml if found
if [ -n "$SETTINGS_XML" ]; then
    info ""
    info "Parsing: $SETTINGS_XML"

    SETTINGS_CONTENT=$(cat "$SETTINGS_XML" | tr -d '\n' | tr -s ' ')

    # Check for mirror that overrides all repos
    MIRROR_ALL_URL=""
    MIRROR_ALL_ID=""

    # Extract mirrors - look for mirrorOf containing * or "central"
    echo "$SETTINGS_CONTENT" | sed 's/<mirror>/\n<mirror>/g' | grep '<mirror>' | while IFS= read -r mirror_block; do
        [ -z "$mirror_block" ] && continue
        mirror_of=$(xml_value "mirrorOf" "$mirror_block")
        if [ "$mirror_of" = "*" ] || [ "$mirror_of" = "central" ]; then
            mirror_url=$(xml_value "url" "$mirror_block")
            mirror_id=$(xml_value "id" "$mirror_block")
            if [ -n "$mirror_url" ]; then
                echo "$mirror_id|$mirror_url"
            fi
            break
        fi
    done | head -1 | {
        IFS='|' read -r MIRROR_ALL_ID MIRROR_ALL_URL
        if [ -n "$MIRROR_ALL_URL" ]; then
            info ""
            info "Mirror configured: $MIRROR_ALL_ID"
            test_maven_repo "$MIRROR_ALL_ID (mirror)" "$MIRROR_ALL_URL"
        fi
    }

    # Extract repository URLs from profiles (simplified - just grab URLs)
    REPO_URLS=$(echo "$SETTINGS_CONTENT" | sed 's/<repository>/\n<repository>/g' | grep '<repository>' | while read -r block; do
        url=$(xml_value "url" "$block")
        [ -n "$url" ] && echo "$url"
    done | sort -u | grep -v "repo.maven.apache.org" | head -5)

    if [ -n "$REPO_URLS" ]; then
        info ""
        info "Additional repositories from profiles:"
        echo "$REPO_URLS" | while read -r url; do
            [ -z "$url" ] && continue
            # Extract host for display name
            name=$(echo "$url" | sed 's|.*://||' | cut -d/ -f1)
            test_maven_repo "$name" "$url"
        done
    fi
else
    info ""
    info "No settings.xml found - only Maven Central tested"
    info "Searched: ~/.m2/settings.xml, \$MAVEN_HOME/conf/settings.xml"
fi
