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

# Configurable parameters
PARALLEL_COUNT="${LATENCY_PARALLEL_COUNT:-20}"
BATCH_TIMEOUT="${LATENCY_TIMEOUT:-30}"

# Build curl auth options
do_curl() {
    if [ -n "${PUBLISH_USER:-}" ] && [ -n "${PUBLISH_PASSWORD:-}" ]; then
        curl -s -u "${PUBLISH_USER}:${PUBLISH_PASSWORD}" "$@"
    elif [ -n "${PUBLISH_TOKEN:-}" ]; then
        curl -s -H "Authorization: Bearer ${PUBLISH_TOKEN}" "$@"
    else
        curl -s "$@"
    fi
}

# Test artifacts - common POMs that likely exist in any Maven repo mirror
TEST_ARTIFACTS=(
    "org/slf4j/slf4j-api/2.0.9/slf4j-api-2.0.9.pom"
    "com/google/guava/guava/31.1-jre/guava-31.1-jre.pom"
    "junit/junit/4.13.2/junit-4.13.2.pom"
    "org/apache/commons/commons-lang3/3.12.0/commons-lang3-3.12.0.pom"
    "com/fasterxml/jackson/core/jackson-core/2.15.2/jackson-core-2.15.2.pom"
)

# Check rate limit headers
RATE_HEADERS=$(do_curl -I "$PUBLISH_URL/${TEST_ARTIFACTS[0]}" 2>/dev/null | grep -iE "x-ratelimit|retry-after|x-throttle" || true)
if [ -n "$RATE_HEADERS" ]; then
    warn "Rate limit headers detected"
    info "$(echo "$RATE_HEADERS" | head -1)"
fi

# Sequential latency test - 10 requests
info "Running sequential latency test (10 requests)..."
LATENCIES=()
HTTP_429_COUNT=0
ARTIFACT_COUNT=${#TEST_ARTIFACTS[@]}

for i in $(seq 1 10); do
    ARTIFACT="${TEST_ARTIFACTS[$((i % ARTIFACT_COUNT))]}"
    START=$(get_time_ms)
    HTTP_CODE=$(do_curl -o /dev/null -w "%{http_code}" "$PUBLISH_URL/$ARTIFACT" 2>/dev/null)
    END=$(get_time_ms)
    LATENCY=$((END - START))

    if [ "$HTTP_CODE" = "429" ]; then
        ((HTTP_429_COUNT++))
    elif [ "$HTTP_CODE" = "404" ]; then
        # Artifact doesn't exist in this repo - that's OK, we still measured latency
        :
    fi

    [ -n "$LATENCY" ] && LATENCIES+=("$LATENCY")
done

if [ ${#LATENCIES[@]} -eq 0 ]; then
    fail "All latency tests failed"
    return 0 2>/dev/null || exit 0
fi

# Calculate sequential stats
SORTED=($(printf '%s\n' "${LATENCIES[@]}" | sort -n))
COUNT=${#SORTED[@]}
MIN=${SORTED[0]}
MAX=${SORTED[$((COUNT-1))]}
SUM=0
for lat in "${LATENCIES[@]}"; do
    SUM=$((SUM + lat))
done
AVG=$((SUM / COUNT))

info "Sequential: min=${MIN}ms avg=${AVG}ms max=${MAX}ms"

# Check for concerning latency
if [ "$AVG" -gt 2000 ]; then
    warn "High average latency: ${AVG}ms"
elif [ "$AVG" -gt 500 ]; then
    pass "Average latency: ${AVG}ms (elevated but acceptable)"
else
    pass "Average latency: ${AVG}ms"
fi

# First 5 vs last 5 comparison (throttling detection) - only if we have enough samples
if [ "$COUNT" -ge 10 ]; then
    FIRST_5_SUM=0
    LAST_5_SUM=0
    for i in 0 1 2 3 4; do
        FIRST_5_SUM=$((FIRST_5_SUM + ${LATENCIES[$i]}))
        LAST_5_SUM=$((LAST_5_SUM + ${LATENCIES[$((COUNT - 5 + i))]}))
    done
    FIRST_5_AVG=$((FIRST_5_SUM / 5))
    LAST_5_AVG=$((LAST_5_SUM / 5))

    if [ "$LAST_5_AVG" -gt $((FIRST_5_AVG * 2)) ] && [ "$FIRST_5_AVG" -gt 0 ]; then
        warn "Possible throttling: latency increased from ${FIRST_5_AVG}ms to ${LAST_5_AVG}ms"
    fi
fi

# Parallel throughput test - 3 batches of concurrent requests
info "Running parallel throughput test (3 × $PARALLEL_COUNT concurrent)..."
BATCH_TIMES=()
PARALLEL_FAILED=false

# Run parallel test with timeout
run_parallel_batch() {
    local batch_pids=()
    for i in $(seq 1 $PARALLEL_COUNT); do
        ARTIFACT="${TEST_ARTIFACTS[$((i % ARTIFACT_COUNT))]}"
        do_curl -o /dev/null --connect-timeout 10 --max-time 20 "$PUBLISH_URL/$ARTIFACT" &
        batch_pids+=($!)
    done
    # Wait for all with timeout
    local waited=0
    while [ $waited -lt $BATCH_TIMEOUT ]; do
        local still_running=false
        for pid in "${batch_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                still_running=true
                break
            fi
        done
        if [ "$still_running" = false ]; then
            return 0
        fi
        sleep 1
        ((waited++))
    done
    # Timeout - kill remaining processes
    for pid in "${batch_pids[@]}"; do
        kill "$pid" 2>/dev/null
    done
    return 1
}

for batch in 1 2 3; do
    BATCH_START=$(get_time_ms)
    if ! run_parallel_batch; then
        warn "Parallel batch $batch timed out after ${BATCH_TIMEOUT}s"
        PARALLEL_FAILED=true
        break
    fi
    BATCH_END=$(get_time_ms)
    BATCH_TIME=$((BATCH_END - BATCH_START))
    BATCH_TIMES+=("$BATCH_TIME")
done

if [ "$PARALLEL_FAILED" = true ]; then
    info "Parallel test incomplete - try with fewer concurrent requests:"
    info "  LATENCY_PARALLEL_COUNT=10 ./diagnostics/diagnose.sh"
    info "  Or skip: SKIP_LATENCY_TEST=true ./diagnostics/diagnose.sh"
elif [ ${#BATCH_TIMES[@]} -eq 3 ]; then
    BATCH1=${BATCH_TIMES[0]}
    BATCH2=${BATCH_TIMES[1]}
    BATCH3=${BATCH_TIMES[2]}
    PARALLEL_AVG=$(( (BATCH1 + BATCH2 + BATCH3) / 3 / PARALLEL_COUNT ))

    info "Parallel batches: ${BATCH1}ms, ${BATCH2}ms, ${BATCH3}ms (avg ${PARALLEL_AVG}ms/req)"

    # Check for batch degradation
    if [ "$BATCH3" -gt $((BATCH1 * 2)) ] && [ "$BATCH1" -gt 0 ]; then
        warn "Batch degradation: ${BATCH1}ms -> ${BATCH3}ms (possible throttling)"
    else
        pass "Parallel throughput: ${PARALLEL_AVG}ms/request"
    fi
fi

# HTTP 429 check
if [ "$HTTP_429_COUNT" -gt 0 ]; then
    fail "Rate limiting: $HTTP_429_COUNT HTTP 429 responses"
    info "Contact your artifact repository admin about rate limits"
fi
