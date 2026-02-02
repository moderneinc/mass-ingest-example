#!/bin/bash
# SSL/Certificate checks for configured endpoints

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

section "SSL/Certificates"

# Function to check SSL certificate
check_ssl() {
    local host="$1"
    local port="${2:-443}"

    # Check DNS first - no point checking SSL if host doesn't resolve
    if ! check_dns "$host"; then
        fail "$host: DNS resolution failed"
        info "Hostname does not resolve - check DNS configuration or hostname spelling"
        return
    fi

    if ! check_command openssl; then
        info "$host: cannot check (openssl not available)"
        return
    fi

    # Get certificate info and capture any errors
    local ssl_output ssl_error
    ssl_output=$(echo | openssl s_client -servername "$host" -connect "$host:$port" 2>&1)
    CERT_INFO=$(echo "$ssl_output" | openssl x509 -noout -dates -subject 2>/dev/null)

    if [ -z "$CERT_INFO" ]; then
        # Check if it's a connection issue vs SSL issue
        if echo "$ssl_output" | grep -qiE "connection refused|connection timed out|no route"; then
            fail "$host: connection failed"
            info "Host resolves but connection failed - check if service is running on port $port"
            return
        fi

        fail "$host: SSL handshake failed"

        # Extract the actual error from openssl output
        ssl_error=$(echo "$ssl_output" | grep -iE "error|unable|failed|refused|timeout" | head -1)
        if [ -n "$ssl_error" ]; then
            info "Error: $ssl_error"
        fi

        # Extract verify error if present
        verify_error=$(echo "$ssl_output" | grep "verify error" | head -1)
        if [ -n "$verify_error" ]; then
            info "$verify_error"
        fi

        info ""
        info "Possible causes:"
        info "  - Self-signed or internal CA certificate"
        info "  - Certificate not trusted by system"
        info "  - Proxy intercepting HTTPS traffic"
        info ""
        info "To fix, add the CA certificate to:"
        info "  - JVM trust store: keytool -import -trustcacerts -keystore \$JAVA_HOME/lib/security/cacerts"
        info "  - System trust store (Linux): /etc/ssl/certs/ or /etc/pki/ca-trust/"
        info "  - Docker: mount CA cert and update-ca-certificates"
        return
    fi

    # Extract expiry date
    NOT_AFTER=$(echo "$CERT_INFO" | grep notAfter | cut -d= -f2)
    if [ -n "$NOT_AFTER" ]; then
        # Convert to epoch for comparison
        EXPIRY_EPOCH=$(date -d "$NOT_AFTER" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$NOT_AFTER" +%s 2>/dev/null || echo "")
        NOW_EPOCH=$(date +%s)

        if [ -n "$EXPIRY_EPOCH" ]; then
            DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

            if [ "$DAYS_LEFT" -lt 0 ]; then
                fail "$host: certificate EXPIRED"
            elif [ "$DAYS_LEFT" -lt 30 ]; then
                warn "$host: certificate expires in $DAYS_LEFT days"
            else
                pass "$host: SSL OK (expires in $DAYS_LEFT days)"
            fi
        else
            pass "$host: SSL OK (expires $NOT_AFTER)"
        fi
    else
        pass "$host: SSL OK"
    fi
}

CHECKED_HOSTS=""

# Check Publish URL (if HTTPS)
case "${PUBLISH_URL:-}" in
    https://*)
        PUBLISH_URL_IS_HTTPS=true
        ;;
    *)
        PUBLISH_URL_IS_HTTPS=false
        ;;
esac

if [ -n "${PUBLISH_URL:-}" ] && [ "$PUBLISH_URL_IS_HTTPS" = true ]; then
    PUBLISH_HOST=$(echo "$PUBLISH_URL" | sed 's|https://||' | cut -d/ -f1 | cut -d: -f1)
    if [ -n "$PUBLISH_HOST" ]; then
        check_ssl "$PUBLISH_HOST"
        CHECKED_HOSTS="$CHECKED_HOSTS $PUBLISH_HOST"
    fi
fi

# Check SCM hosts from repos.csv (HTTPS only)
CSV_FILE="${REPOS_CSV:-/app/repos.csv}"
if [ ! -f "$CSV_FILE" ]; then
    CSV_FILE="repos.csv"
fi

if [ -f "$CSV_FILE" ]; then
    # Dynamically find cloneUrl column index
    HEADER=$(head -1 "$CSV_FILE")
    CLONEURL_COL=$(echo "$HEADER" | tr ',' '\n' | grep -ni "^cloneUrl$" | cut -d: -f1)

    # Extract unique HTTPS hosts from cloneUrl
    if [ -n "$CLONEURL_COL" ]; then
        HOSTS=$(tail -n +2 "$CSV_FILE" | cut -d',' -f"$CLONEURL_COL" | grep "^https://" | sed 's|https://||' | cut -d/ -f1 | cut -d@ -f2 | sort -u | head -5)
    else
        HOSTS=""
    fi

    for host in $HOSTS; do
        if [ -n "$host" ] && ! echo "$CHECKED_HOSTS" | grep -q "$host"; then
            check_ssl "$host"
            CHECKED_HOSTS="$CHECKED_HOSTS $host"
        fi
    done
fi

# If nothing was checked, note that
if [ -z "$CHECKED_HOSTS" ]; then
    info "No HTTPS endpoints configured to check"
fi
