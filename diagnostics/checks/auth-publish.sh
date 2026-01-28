#!/bin/bash
# Authentication checks for publish URL: write, read, overwrite, delete test

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../diagnose.sh" --functions-only
fi

section "Authentication - Publish"

# Skip if no publish URL
if [ -z "${PUBLISH_URL:-}" ]; then
    info "Skipped: PUBLISH_URL not configured"
    return 0 2>/dev/null || exit 0
fi

# Skip if S3 (different auth mechanism)
if [[ "$PUBLISH_URL" == "s3://"* ]]; then
    if check_command aws; then
        # Test S3 write access
        TEST_KEY="io/moderne/.diagnostic-test-$(date +%s).txt"
        TEST_FILE=$(mktemp)
        echo "diagnostic test $(date)" > "$TEST_FILE"

        # Build S3 options as array to avoid command injection
        S3_ARGS=()
        [ -n "${S3_PROFILE:-}" ] && S3_ARGS+=(--profile "$S3_PROFILE")
        [ -n "${S3_REGION:-}" ] && S3_ARGS+=(--region "$S3_REGION")
        [ -n "${S3_ENDPOINT:-}" ] && S3_ARGS+=(--endpoint-url "$S3_ENDPOINT")

        # Write test
        if aws s3 cp "$TEST_FILE" "$PUBLISH_URL/$TEST_KEY" "${S3_ARGS[@]}" >/dev/null 2>&1; then
            pass "S3 write: succeeded"

            # Read test
            READ_FILE=$(mktemp)
            if aws s3 cp "$PUBLISH_URL/$TEST_KEY" "$READ_FILE" "${S3_ARGS[@]}" >/dev/null 2>&1; then
                pass "S3 read: succeeded"
                rm -f "$READ_FILE"
            else
                fail "S3 read: failed"
            fi

            # Delete test
            if aws s3 rm "$PUBLISH_URL/$TEST_KEY" "${S3_ARGS[@]}" >/dev/null 2>&1; then
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
fi

# HTTP(S) publish URL tests
# Build auth options as array to avoid command injection
CURL_AUTH_ARGS=()
if [ -n "${PUBLISH_USER:-}" ] && [ -n "${PUBLISH_PASSWORD:-}" ]; then
    CURL_AUTH_ARGS+=(-u "${PUBLISH_USER}:${PUBLISH_PASSWORD}")
elif [ -n "${PUBLISH_TOKEN:-}" ]; then
    CURL_AUTH_ARGS+=(-H "Authorization: Bearer ${PUBLISH_TOKEN}")
fi

if [ ${#CURL_AUTH_ARGS[@]} -eq 0 ]; then
    warn "No credentials configured (PUBLISH_USER/PASSWORD or PUBLISH_TOKEN)"
    info "Testing anonymous access..."
fi

# Test path - use a unique path to avoid conflicts
TEST_PATH="io/moderne/.diagnostic-test-$(date +%s).txt"
TEST_URL="$PUBLISH_URL/$TEST_PATH"
TEST_CONTENT="diagnostic test $(date)"
TEST_CONTENT2="diagnostic test update $(date)"

# Write test
WRITE_RESULT=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_AUTH_ARGS[@]}" -X PUT "$TEST_URL" -d "$TEST_CONTENT" 2>/dev/null)
if [[ "$WRITE_RESULT" =~ ^2 ]]; then
    pass "Test write: succeeded (HTTP $WRITE_RESULT)"
else
    fail "Test write: failed (HTTP $WRITE_RESULT)"
    info "Check credentials and repository permissions"
    return 0 2>/dev/null || exit 0
fi

# Read test
READ_RESULT=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_AUTH_ARGS[@]}" "$TEST_URL" 2>/dev/null)
if [[ "$READ_RESULT" =~ ^2 ]]; then
    pass "Test read: succeeded (HTTP $READ_RESULT)"
else
    warn "Test read: failed (HTTP $READ_RESULT)"
fi

# Overwrite test
OVERWRITE_RESULT=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_AUTH_ARGS[@]}" -X PUT "$TEST_URL" -d "$TEST_CONTENT2" 2>/dev/null)
if [[ "$OVERWRITE_RESULT" =~ ^2 ]]; then
    pass "Test overwrite: succeeded (HTTP $OVERWRITE_RESULT)"
else
    warn "Test overwrite: failed (HTTP $OVERWRITE_RESULT)"
    info "Some repositories may not allow overwrites"
fi

# Delete test (cleanup)
DELETE_RESULT=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_AUTH_ARGS[@]}" -X DELETE "$TEST_URL" 2>/dev/null)
if [[ "$DELETE_RESULT" =~ ^2 ]]; then
    pass "Test delete: succeeded (HTTP $DELETE_RESULT)"
else
    warn "Test delete: failed (HTTP $DELETE_RESULT)"
    info "Cleanup may be needed: $TEST_PATH"
fi
