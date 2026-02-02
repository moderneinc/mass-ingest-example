#!/bin/sh
# Network checks: connectivity to configured endpoints

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    . "$(dirname "$0")/../lib/core.sh"
fi

section "Network"

# Check PUBLISH_URL connectivity (auth tested separately in auth-publish)
if [ -n "${PUBLISH_URL:-}" ]; then
    case "$PUBLISH_URL" in
        s3://*)
            if check_command aws; then
                # Build S3 options
                S3_CMD="aws s3 ls $PUBLISH_URL --max-items 1"
                [ -n "${S3_PROFILE:-}" ] && S3_CMD="$S3_CMD --profile $S3_PROFILE"
                [ -n "${S3_REGION:-}" ] && S3_CMD="$S3_CMD --region $S3_REGION"
                [ -n "${S3_ENDPOINT:-}" ] && S3_CMD="$S3_CMD --endpoint-url $S3_ENDPOINT"

                if eval "$S3_CMD" >/dev/null 2>&1; then
                    pass "PUBLISH_URL: $PUBLISH_URL (S3 accessible)"
                else
                    warn "PUBLISH_URL: $PUBLISH_URL (S3 - cannot list, check credentials)"
                fi
            else
                info "PUBLISH_URL: $PUBLISH_URL (S3 - aws cli not available to test)"
            fi
            ;;
        *)
            # Just check connectivity - 401/403 means server is reachable (auth tested in auth-publish)
            START=$(get_time_ms)
            HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$PUBLISH_URL" 2>/dev/null)
            CURL_EXIT=$?
            END=$(get_time_ms)
            LATENCY=$((END - START))

            if [ $CURL_EXIT -ne 0 ] || [ "$HTTP_CODE" = "000" ]; then
                fail "PUBLISH_URL: unreachable (connection failed or DNS error)"
                info "Check network connectivity and DNS resolution"
            else
                # Any HTTP response means server is reachable
                case "$HTTP_CODE" in
                    2*|3*|4*|5*)
                        pass "PUBLISH_URL: reachable (${LATENCY}ms)"
                        ;;
                    *)
                        warn "PUBLISH_URL: unexpected response (HTTP $HTTP_CODE)"
                        ;;
                esac
            fi
            ;;
    esac
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
                # Check DNS first for clearer error messages
                if ! check_dns "$host"; then
                    fail "$host: DNS resolution failed"
                    info "Hostname does not resolve - check DNS or hostname spelling"
                    continue
                fi

                START=$(get_time_ms)
                HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "https://$host" 2>/dev/null)
                CURL_EXIT=$?
                END=$(get_time_ms)
                LATENCY=$((END - START))

                if [ $CURL_EXIT -ne 0 ] || [ "$HTTP_CODE" = "000" ]; then
                    fail "$host: connection failed"
                    info "Host resolves but connection failed - check firewall or service availability"
                else
                    case "$HTTP_CODE" in
                        2*|3*|4*|5*)
                            pass "$host: reachable (${LATENCY}ms)"
                            ;;
                        *)
                            warn "$host: unexpected response (HTTP $HTTP_CODE)"
                            ;;
                    esac
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
