#!/bin/bash
# SCM repository connectivity checks: git ls-remote latency per origin
#
# Tests git connectivity to each unique SCM origin by running git ls-remote.
# This validates that git credentials work and measures actual git protocol latency.
#
# Environment variables:
#   SKIP_SCM_REPOS    Skip this check entirely

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

section "SCM repositories"

# Allow skipping
if [ "${SKIP_SCM_REPOS:-}" = "true" ]; then
    info "Skipped: SKIP_SCM_REPOS=true"
    return 0 2>/dev/null || exit 0
fi

# Find repos.csv
CSV_FILE="${REPOS_CSV:-/app/repos.csv}"
if [ ! -f "$CSV_FILE" ]; then
    CSV_FILE="repos.csv"
fi

if [ ! -f "$CSV_FILE" ]; then
    info "Skipped: repos.csv not found"
    return 0 2>/dev/null || exit 0
fi

# Parse header to find column indices
HEADER=$(head -1 "$CSV_FILE")

get_col_index() {
    echo "$HEADER" | tr ',' '\n' | grep -ni "^$1$" | cut -d: -f1
}

CLONEURL_COL=$(get_col_index "cloneUrl")
ORIGIN_COL=$(get_col_index "origin")

if [ -z "$CLONEURL_COL" ]; then
    fail "cloneUrl column not found in CSV header"
    return 0 2>/dev/null || exit 0
fi

# Get unique origins with first URL for each - single awk pass for efficiency
# Format: origin|cloneUrl (pipe-separated to handle URLs with special chars)
ORIGIN_DATA=$(awk -F',' -v origin_col="$ORIGIN_COL" -v url_col="$CLONEURL_COL" '
    NR > 1 && $url_col != "" {
        origin = (origin_col != "") ? $origin_col : $url_col
        # If no origin column, extract host from URL
        if (origin_col == "") {
            gsub(/.*:\/\//, "", origin)
            gsub(/\/.*/, "", origin)
            gsub(/.*@/, "", origin)
        }
        if (origin != "" && !seen[origin]++) {
            print origin "|" $url_col
        }
    }
' "$CSV_FILE")
ORIGIN_COUNT=$(echo "$ORIGIN_DATA" | grep -c '|' 2>/dev/null || echo "0")

if [ "$ORIGIN_COUNT" -eq 0 ]; then
    info "No origins found in repos.csv"
    return 0 2>/dev/null || exit 0
fi

info "Testing git connectivity to $ORIGIN_COUNT origin(s)..."
info ""

# Test each origin with git ls-remote
# Use here-string to avoid subshell (pipe creates subshell where exported functions may not work)
while IFS='|' read -r origin clone_url; do
    [ -z "$origin" ] && continue

    # Extract host from clone URL for DNS check
    host=$(echo "$clone_url" | sed 's|.*://||' | sed 's|.*@||' | cut -d/ -f1 | cut -d: -f1)

    # Check DNS first - git ls-remote can hang forever on DNS failures
    if [ -n "$host" ] && ! check_dns "$host"; then
        fail "$origin: DNS resolution failed"
        info "Hostname '$host' does not resolve"
        continue
    fi

    # Use GIT_TERMINAL_PROMPT=0 to fail fast on auth issues
    START=$(get_time_ms)

    # git ls-remote with timeout (15 seconds should be plenty)
    if check_command timeout; then
        OUTPUT=$(GIT_TERMINAL_PROMPT=0 timeout 15 git ls-remote --heads "$clone_url" 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$clone_url" 2>&1)
        EXIT_CODE=$?
    fi

    END=$(get_time_ms)
    LATENCY=$((END - START))

    if [ $EXIT_CODE -eq 0 ]; then
        # Count refs returned
        REF_COUNT=$(echo "$OUTPUT" | grep -c "refs/heads/" 2>/dev/null || echo "0")

        if [ "$LATENCY" -gt 5000 ]; then
            warn "$origin: ${LATENCY}ms (slow, found $REF_COUNT branches)"
        elif [ "$LATENCY" -gt 2000 ]; then
            pass "$origin: ${LATENCY}ms (found $REF_COUNT branches)"
        else
            pass "$origin: ${LATENCY}ms"
        fi
    elif [ $EXIT_CODE -eq 124 ]; then
        fail "$origin: timed out after 15s"
        info "Check network connectivity to: $clone_url"
    else
        # Check if it's an auth failure
        if echo "$OUTPUT" | grep -qiE "authentication|credential|permission|401|403|could not read"; then
            fail "$origin: authentication failed"
            info "Configure git credentials for: $clone_url"
        else
            fail "$origin: git ls-remote failed"
            # Show first line of error
            ERROR_LINE=$(echo "$OUTPUT" | grep -v "^$" | head -1)
            if [ -n "$ERROR_LINE" ]; then
                info "$ERROR_LINE"
            fi
        fi
    fi
done << EOF
$ORIGIN_DATA
EOF
