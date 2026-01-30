#!/bin/bash
# Publish URL latency and rate limiting checks
#
# Tests read latency and parallel throughput to detect:
# - High latency
# - Rate limiting (HTTP 429, throttling headers)
# - Latency degradation under load
#
# Environment variables:
#   SKIP_LATENCY_TEST=true    Skip this check entirely
#   LATENCY_PARALLEL_COUNT    Number of concurrent requests (default: 20)
#   LATENCY_TIMEOUT           Timeout per batch in seconds (default: 30)

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../diagnose.sh" --functions-only
fi

# Source latency testing library
source "$(dirname "$0")/../lib/latency.sh"

section "Publish latency"

# Allow skipping this test
if [ "${SKIP_LATENCY_TEST:-}" = "true" ]; then
    info "Skipped: SKIP_LATENCY_TEST=true"
    return 0 2>/dev/null || exit 0
fi

if [ -z "${PUBLISH_URL:-}" ]; then
    info "Skipped: PUBLISH_URL not set"
    return 0 2>/dev/null || exit 0
fi

# Skip for S3
if [[ "$PUBLISH_URL" == "s3://"* ]]; then
    info "Skipped: S3 latency testing not implemented"
    return 0 2>/dev/null || exit 0
fi

# Build curl auth args
CURL_ARGS=()
if [ -n "${PUBLISH_USER:-}" ] && [ -n "${PUBLISH_PASSWORD:-}" ]; then
    CURL_ARGS+=(-u "${PUBLISH_USER}:${PUBLISH_PASSWORD}")
elif [ -n "${PUBLISH_TOKEN:-}" ]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${PUBLISH_TOKEN}")
fi

# Run comprehensive latency test
run_comprehensive_latency_test "PUBLISH_URL" "$PUBLISH_URL" "${CURL_ARGS[@]}"
