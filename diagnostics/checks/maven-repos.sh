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
if [[ -z "$SCRIPT_DIR" ]]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

# Source latency testing library
source "${SCRIPT_DIR:-$(dirname "$0")/..}/lib/latency.sh"

section "Maven repositories"

# Allow skipping
if [[ "${SKIP_MAVEN_REPOS:-}" == "true" ]]; then
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
        if [[ -n "$path" ]] && [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

SETTINGS_XML=$(find_settings_xml)

# Test a repository URL
test_maven_repo() {
    local name="$1"
    local url="$2"
    local user="${3:-}"
    local repo_pass="${4:-}"

    local -a curl_auth=()
    if [[ -n "$user" ]] && [[ -n "$repo_pass" ]]; then
        case "$repo_pass" in
            '{'*'}')
                info "$name: encrypted password detected (skipping auth test)"
                ;;
            *)
                curl_auth+=(-u "${user}:${repo_pass}")
                ;;
        esac
    fi

    # Quick connectivity check
    local test_url="${url%/}/org/apache/maven/plugins/maven-metadata.xml"
    local http_code curl_exit
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "${curl_auth[@]}" "$test_url" 2>/dev/null)
    curl_exit=$?

    if [[ $curl_exit -ne 0 ]] || [[ "$http_code" == "000" ]]; then
        fail "$name: unreachable"
        info "URL: $url"
        return 1
    elif [[ "$http_code" == "401" ]] || [[ "$http_code" == "403" ]]; then
        if [[ -n "$user" ]]; then
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
if [[ -n "$SETTINGS_XML" ]]; then
    info ""
    info "Parsing: $SETTINGS_XML"

    # Require xmllint for XML parsing
    if ! check_command xmllint; then
        warn "xmllint not found - cannot parse settings.xml"
        info "Install libxml2-utils or libxml2 for your platform"
    else
        # Extract mirrors that override central or all repos
        MIRROR_COUNT=$(xmllint --xpath "count(//mirror)" "$SETTINGS_XML" 2>/dev/null || echo "0")
        for ((i=1; i<=MIRROR_COUNT; i++)); do
            mirror_of=$(xmllint --xpath "string(//mirror[$i]/mirrorOf)" "$SETTINGS_XML" 2>/dev/null || true)
            if [[ "$mirror_of" == "*" ]] || [[ "$mirror_of" == "central" ]]; then
                mirror_url=$(xmllint --xpath "string(//mirror[$i]/url)" "$SETTINGS_XML" 2>/dev/null || true)
                mirror_id=$(xmllint --xpath "string(//mirror[$i]/id)" "$SETTINGS_XML" 2>/dev/null || true)
                if [[ -n "$mirror_url" ]]; then
                    info ""
                    info "Mirror configured: $mirror_id"
                    test_maven_repo "$mirror_id (mirror)" "$mirror_url"
                fi
                break
            fi
        done

        # Extract repository URLs from profiles
        REPO_URLS=$(xmllint --xpath "//repository/url/text()" "$SETTINGS_XML" 2>/dev/null | tr ' ' '\n' | sort -u | grep -v "repo.maven.apache.org" | head -5 || true)

        if [[ -n "$REPO_URLS" ]]; then
            info ""
            info "Additional repositories from profiles:"
            echo "$REPO_URLS" | while read -r url; do
                [[ -z "$url" ]] && continue
                # Extract host for display name
                name=$(echo "$url" | sed 's|.*://||' | cut -d/ -f1)
                test_maven_repo "$name" "$url"
            done
        fi
    fi
else
    info ""
    info "No settings.xml found - only Maven Central tested"
    info "Searched: ~/.m2/settings.xml, \$MAVEN_HOME/conf/settings.xml"
fi
