#!/bin/bash
# Authentication checks for publish URL: write, read, overwrite, delete test

# Source shared functions if run directly
if [[ -z "$SCRIPT_DIR" ]]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

section "Authentication - Publish"

# Skip if no publish URL
if [[ -z "${PUBLISH_URL:-}" ]]; then
    info "Skipped: PUBLISH_URL not configured"
    return 0 2>/dev/null || exit 0
fi

# Skip if S3 (different auth mechanism)
case "$PUBLISH_URL" in
    s3://*)
        if check_command aws; then
            # Test S3 write access
            TEST_KEY="io/moderne/.diagnostic-test-$(date +%s).txt"
            TEST_FILE=$(mktemp)
            echo "diagnostic test $(date)" > "$TEST_FILE"

            # Build S3 options
            S3_CMD_BASE="aws s3"
            [[ -n "${S3_PROFILE:-}" ]] && S3_CMD_BASE="$S3_CMD_BASE --profile $S3_PROFILE"
            [[ -n "${S3_REGION:-}" ]] && S3_CMD_BASE="$S3_CMD_BASE --region $S3_REGION"
            [[ -n "${S3_ENDPOINT:-}" ]] && S3_CMD_BASE="$S3_CMD_BASE --endpoint-url $S3_ENDPOINT"

            # Write test
            if eval "$S3_CMD_BASE cp \"$TEST_FILE\" \"$PUBLISH_URL/$TEST_KEY\"" >/dev/null 2>&1; then
                pass "S3 write: succeeded"

                # Read test
                READ_FILE=$(mktemp)
                if eval "$S3_CMD_BASE cp \"$PUBLISH_URL/$TEST_KEY\" \"$READ_FILE\"" >/dev/null 2>&1; then
                    pass "S3 read: succeeded"
                    rm -f "$READ_FILE"
                else
                    fail "S3 read: failed"
                fi

                # Delete test
                if eval "$S3_CMD_BASE rm \"$PUBLISH_URL/$TEST_KEY\"" >/dev/null 2>&1; then
                    pass "S3 delete: succeeded"
                else
                    warn "S3 delete: failed (may need manual cleanup)"
                fi
            else
                fail "S3 write: failed"
                info "Check AWS credentials and bucket permissions"
            fi

            rm -f "$TEST_FILE"
        else
            info "Skipped: aws cli not available"
        fi
        return 0 2>/dev/null || exit 0
        ;;
esac

# HTTP(S) publish URL tests
# Build auth options as array (safe for special characters in credentials)
CURL_AUTH=()
HAS_CREDS=false
if [[ -n "${PUBLISH_USER:-}" ]] && [[ -n "${PUBLISH_PASSWORD:-}" ]]; then
    CURL_AUTH+=(-u "${PUBLISH_USER}:${PUBLISH_PASSWORD}")
    HAS_CREDS=true
elif [[ -n "${PUBLISH_TOKEN:-}" ]]; then
    CURL_AUTH+=(-H "Authorization: Bearer ${PUBLISH_TOKEN}")
    HAS_CREDS=true
fi

if [[ "$HAS_CREDS" == false ]]; then
    warn "No credentials configured (PUBLISH_USER/PASSWORD or PUBLISH_TOKEN)"
    info "Testing anonymous access..."
fi

# Test path - use a unique path to avoid conflicts
TEST_PATH="io/moderne/.diagnostic-test-$(date +%s).txt"
TEST_URL="$PUBLISH_URL/$TEST_PATH"
TEST_CONTENT="diagnostic test $(date)"
TEST_CONTENT2="diagnostic test update $(date)"

# Write test
WRITE_RESULT=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_AUTH[@]}" -X PUT "$TEST_URL" -d "$TEST_CONTENT" 2>/dev/null)
case "$WRITE_RESULT" in
    2*)
        pass "Test write: succeeded (HTTP $WRITE_RESULT)"
        ;;
    *)
        fail "Test write: failed (HTTP $WRITE_RESULT)"
        info "Check credentials and repository permissions"
        return 0 2>/dev/null || exit 0
        ;;
esac

# Read test
READ_RESULT=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_AUTH[@]}" "$TEST_URL" 2>/dev/null)
case "$READ_RESULT" in
    2*)
        pass "Test read: succeeded (HTTP $READ_RESULT)"
        ;;
    *)
        warn "Test read: failed (HTTP $READ_RESULT)"
        ;;
esac

# Overwrite test
OVERWRITE_RESULT=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_AUTH[@]}" -X PUT "$TEST_URL" -d "$TEST_CONTENT2" 2>/dev/null)
case "$OVERWRITE_RESULT" in
    2*)
        pass "Test overwrite: succeeded (HTTP $OVERWRITE_RESULT)"
        ;;
    *)
        warn "Test overwrite: failed (HTTP $OVERWRITE_RESULT)"
        info "Some repositories may not allow overwrites"
        ;;
esac

# Delete test (cleanup)
DELETE_RESULT=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_AUTH[@]}" -X DELETE "$TEST_URL" 2>/dev/null)
case "$DELETE_RESULT" in
    2*)
        pass "Test delete: succeeded (HTTP $DELETE_RESULT)"
        ;;
    *)
        warn "Test delete: failed (HTTP $DELETE_RESULT)"
        info "Cleanup may be needed: $TEST_PATH"
        ;;
esac
