#!/bin/sh
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
    . "$(dirname "$0")/../lib/core.sh"
fi

# Source latency testing library
. "${SCRIPT_DIR:-$(dirname "$0")/..}/lib/latency.sh"

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
case "$PUBLISH_URL" in
    s3://*)
        info "Skipped: S3 latency testing not implemented"
        return 0 2>/dev/null || exit 0
        ;;
esac

# Run comprehensive latency test (auth handled by latency.sh or not needed for read tests)
run_comprehensive_latency_test "PUBLISH_URL" "$PUBLISH_URL"
