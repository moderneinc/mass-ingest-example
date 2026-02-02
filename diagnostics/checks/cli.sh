#!/bin/bash
# Moderne CLI checks

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

section "Moderne CLI"

if ! check_command mod; then
    fail "CLI not installed"
    return 0 2>/dev/null || exit 0
fi

# Get version
MOD_VERSION=$(mod --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
pass "CLI installed: v$MOD_VERSION"

# Helper to strip ANSI codes from output
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# Helper to parse mod config output and extract the configured value
parse_mod_config() {
    local output="$1"
    local clean
    clean=$(echo "$output" | strip_ansi)

    # Check for "not configured" / "No " patterns
    if echo "$clean" | grep -qiE "^No |no currently configured|not found|not configured"; then
        echo ""
        return
    fi

    # Look for the value line after "Set globally" or "Set for"
    local value
    value=$(echo "$clean" | grep -A1 "Set globally\|Set for" | tail -1 | sed 's/^[[:space:]]*//' | grep -v "^$" || echo "")
    if [ -n "$value" ]; then
        echo "$value"
        return
    fi

    echo ""
}

# Configuration details section
info ""
info "Configuration:"

# Trust store
TRUST_OUTPUT=$(mod config http trust-store show 2>&1)
TRUST_CLEAN=$(echo "$TRUST_OUTPUT" | strip_ansi)
if echo "$TRUST_CLEAN" | grep -q "no currently configured truststore"; then
    info "  Trust store: default JVM"
else
    TRUST_FILE=$(echo "$TRUST_CLEAN" | grep -A1 "Set globally\|Set for" | tail -1 | sed 's/^[[:space:]]*//' || echo "")
    if [ -n "$TRUST_FILE" ]; then
        info "  Trust store: $TRUST_FILE"
    else
        info "  Trust store: custom"
    fi
fi

# Proxy configuration
PROXY_OUTPUT=$(mod config http proxy show 2>&1)
PROXY_CLEAN=$(echo "$PROXY_OUTPUT" | strip_ansi)
if echo "$PROXY_CLEAN" | grep -qiE "no proxy|not configured" || ! echo "$PROXY_CLEAN" | grep -q "Set globally\|Set for"; then
    info "  Proxy: not configured"
else
    PROXY_HOST=$(echo "$PROXY_CLEAN" | grep -A1 "Set globally\|Set for" | tail -1 | sed 's/^[[:space:]]*//' || echo "configured")
    info "  Proxy: $PROXY_HOST"
fi

# LST artifacts configuration
LST_OUTPUT=$(mod config lsts artifacts show 2>&1)
LST_CLEAN=$(echo "$LST_OUTPUT" | strip_ansi)
if echo "$LST_CLEAN" | grep -qi "maven"; then
    LST_URL=$(echo "$LST_CLEAN" | grep -oE 'https?://[^ ]+' | head -1 || echo "")
    if [ -n "$LST_URL" ]; then
        info "  LST artifacts: Maven ($LST_URL)"
    else
        info "  LST artifacts: Maven repository"
    fi
elif echo "$LST_CLEAN" | grep -qi "s3\|aws"; then
    info "  LST artifacts: S3"
else
    info "  LST artifacts: via PUBLISH_URL env var"
fi

# Build timeouts (combine into one line if both set)
GRADLE_TIMEOUT=$(parse_mod_config "$(mod config build gradle timeout show 2>&1)")
MAVEN_TIMEOUT=$(parse_mod_config "$(mod config build maven timeout show 2>&1)")

if [ -n "$GRADLE_TIMEOUT" ] && [ -n "$MAVEN_TIMEOUT" ]; then
    info "  Build timeouts: Gradle $GRADLE_TIMEOUT, Maven $MAVEN_TIMEOUT"
elif [ -n "$GRADLE_TIMEOUT" ]; then
    info "  Gradle timeout: $GRADLE_TIMEOUT"
elif [ -n "$MAVEN_TIMEOUT" ]; then
    info "  Maven timeout: $MAVEN_TIMEOUT"
else
    info "  Build timeouts: default"
fi

# Java options
JAVA_OPTS=$(parse_mod_config "$(mod config java options show 2>&1)")
if [ -n "$JAVA_OPTS" ]; then
    HEAP=$(echo "$JAVA_OPTS" | grep -oE '\-Xmx[0-9]+[gGmM]' | head -1 || echo "")
    if [ -n "$HEAP" ]; then
        info "  Java heap: $HEAP"
    else
        info "  Java options: custom"
    fi
fi

# Gradle build arguments (only show if configured)
GRADLE_ARGS=$(parse_mod_config "$(mod config build gradle arguments show 2>&1)")
if [ -n "$GRADLE_ARGS" ]; then
    info "  Gradle arguments: $GRADLE_ARGS"
fi

# Maven build arguments (only show if configured)
MAVEN_ARGS=$(parse_mod_config "$(mod config build maven arguments show 2>&1)")
if [ -n "$MAVEN_ARGS" ]; then
    info "  Maven arguments: $MAVEN_ARGS"
fi

# Maven settings (only show if non-default)
MAVEN_SETTINGS_OUTPUT=$(mod config build maven settings show 2>&1)
MAVEN_SETTINGS_CLEAN=$(echo "$MAVEN_SETTINGS_OUTPUT" | strip_ansi)
if ! echo "$MAVEN_SETTINGS_CLEAN" | grep -q "No Maven settings"; then
    MAVEN_SETTINGS=$(parse_mod_config "$MAVEN_SETTINGS_OUTPUT")
    if [ -n "$MAVEN_SETTINGS" ]; then
        info "  Maven settings: $MAVEN_SETTINGS"
    fi
fi
