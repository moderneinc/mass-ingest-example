#!/bin/bash
# Network checks: connectivity to configured endpoints

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../diagnose.sh" --functions-only
fi

section "Network"

# Helper to check URL and report latency
# Args: name, url, [auth_type: "basic"|"bearer"|""]
check_url() {
    local name="$1"
    local url="$2"
    local auth_type="${3:-}"

    local START END HTTP_CODE LATENCY
    local CURL_ARGS=(-s -o /dev/null -w '%{http_code}' --connect-timeout 5)

    # Add auth based on type
    if [ "$auth_type" = "basic" ] && [ -n "${PUBLISH_USER:-}" ] && [ -n "${PUBLISH_PASSWORD:-}" ]; then
        CURL_ARGS+=(-u "${PUBLISH_USER}:${PUBLISH_PASSWORD}")
    elif [ "$auth_type" = "bearer" ] && [ -n "${PUBLISH_TOKEN:-}" ]; then
        CURL_ARGS+=(-H "Authorization: Bearer ${PUBLISH_TOKEN}")
    fi

    START=$(date +%s.%N)
    HTTP_CODE=$(curl "${CURL_ARGS[@]}" "$url" 2>/dev/null || echo "000")
    END=$(date +%s.%N)
    LATENCY=$(awk "BEGIN {printf \"%d\", ($END - $START) * 1000}" 2>/dev/null || echo "?")

    if [[ "$HTTP_CODE" =~ ^[23] ]]; then
        pass "$name: reachable (${LATENCY}ms)"
        return 0
    elif [ "$HTTP_CODE" = "000" ]; then
        fail "$name: unreachable (connection failed)"
        return 1
    elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
        fail "$name: authentication failed (HTTP $HTTP_CODE)"
        return 1
    else
        warn "$name: HTTP $HTTP_CODE (${LATENCY}ms)"
        return 0
    fi
}

# Check PUBLISH_URL connectivity (auth tested separately in auth-publish)
if [ -n "${PUBLISH_URL:-}" ]; then
    if [[ "$PUBLISH_URL" == "s3://"* ]]; then
        if check_command aws; then
            if aws s3 ls "$PUBLISH_URL" --max-items 1 >/dev/null 2>&1; then
                pass "PUBLISH_URL: $PUBLISH_URL (S3 accessible)"
            else
                warn "PUBLISH_URL: $PUBLISH_URL (S3 - cannot list, check credentials)"
            fi
        else
            info "PUBLISH_URL: $PUBLISH_URL (S3 - aws cli not available to test)"
        fi
    else
        # Just check connectivity - 401/403 means server is reachable (auth tested in auth-publish)
        START=$(date +%s.%N)
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$PUBLISH_URL" 2>/dev/null || echo "000")
        END=$(date +%s.%N)
        LATENCY=$(awk "BEGIN {printf \"%d\", ($END - $START) * 1000}" 2>/dev/null || echo "?")

        if [ "$HTTP_CODE" = "000" ]; then
            fail "PUBLISH_URL: unreachable (connection failed)"
        elif [[ "$HTTP_CODE" =~ ^[2345] ]]; then
            # 2xx, 3xx, 4xx, 5xx all mean the server responded
            pass "PUBLISH_URL: reachable (${LATENCY}ms)"
        else
            warn "PUBLISH_URL: HTTP $HTTP_CODE (${LATENCY}ms)"
        fi
    fi
else
    warn "PUBLISH_URL: not set"
fi

# Check SCM hosts from repos.csv
CSV_FILE="${REPOS_CSV:-/app/repos.csv}"
if [ ! -f "$CSV_FILE" ]; then
    CSV_FILE="repos.csv"
fi

if [ -f "$CSV_FILE" ]; then
    # Find cloneUrl column dynamically
    HEADER=$(head -1 "$CSV_FILE")
    CLONEURL_COL=$(echo "$HEADER" | tr ',' '\n' | grep -ni "^cloneUrl$" | cut -d: -f1)

    if [ -n "$CLONEURL_COL" ]; then
        HOSTS=$(tail -n +2 "$CSV_FILE" | cut -d',' -f"$CLONEURL_COL" | sed 's|.*://||' | cut -d/ -f1 | cut -d@ -f2 | sort -u | head -10)
    else
        HOSTS=""
    fi

    if [ -n "$HOSTS" ]; then
        info ""
        info "SCM hosts (from repos.csv):"
        for host in $HOSTS; do
            if [ -n "$host" ]; then
                START=$(date +%s.%N)
                HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "https://$host" 2>/dev/null || echo "000")
                END=$(date +%s.%N)
                LATENCY=$(awk "BEGIN {printf \"%d\", ($END - $START) * 1000}" 2>/dev/null || echo "?")

                if [[ "$HTTP_CODE" =~ ^[23] ]]; then
                    pass "$host: reachable (${LATENCY}ms)"
                elif [ "$HTTP_CODE" = "000" ]; then
                    fail "$host: unreachable"
                else
                    info "$host: HTTP $HTTP_CODE (${LATENCY}ms)"
                fi
            fi
        done
    fi
fi

# Proxy info (env vars)
if [ -n "${http_proxy:-}" ] || [ -n "${HTTP_PROXY:-}" ] || [ -n "${https_proxy:-}" ] || [ -n "${HTTPS_PROXY:-}" ]; then
    info ""
    info "Proxy configured:"
    [ -n "${http_proxy:-}" ] && info "  http_proxy=$http_proxy"
    [ -n "${HTTP_PROXY:-}" ] && info "  HTTP_PROXY=$HTTP_PROXY"
    [ -n "${https_proxy:-}" ] && info "  https_proxy=$https_proxy"
    [ -n "${HTTPS_PROXY:-}" ] && info "  HTTPS_PROXY=$HTTPS_PROXY"
fi
