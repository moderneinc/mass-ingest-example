#!/bin/bash
# Shared latency testing library for repository diagnostics
#
# Provides comprehensive latency and throughput testing:
# - Sequential latency with min/avg/max stats
# - Throttling detection (first 5 vs last 5 comparison)
# - Rate limit header detection (X-RateLimit, Retry-After)
# - Parallel throughput with degradation detection
# - HTTP 429 counting
#
# Environment variables:
#   LATENCY_PARALLEL_COUNT    Number of concurrent requests (default: 20)
#   LATENCY_TIMEOUT           Timeout per batch in seconds (default: 30)

# Note: Core library (core.sh) must be sourced before this file.
# This is typically done by the calling script (e.g., publish-latency.sh).

# Test artifacts - common POMs that likely exist in any Maven repo
LATENCY_TEST_ARTIFACTS=(
    "org/slf4j/slf4j-api/2.0.9/slf4j-api-2.0.9.pom"
    "com/google/guava/guava/31.1-jre/guava-31.1-jre.pom"
    "junit/junit/4.13.2/junit-4.13.2.pom"
    "org/apache/commons/commons-lang3/3.12.0/commons-lang3-3.12.0.pom"
    "com/fasterxml/jackson/core/jackson-core/2.15.2/jackson-core-2.15.2.pom"
)

# Get artifact by index (wraps around)
get_test_artifact() {
    local idx=$(( ($1 - 1) % ${#LATENCY_TEST_ARTIFACTS[@]} ))
    echo "${LATENCY_TEST_ARTIFACTS[$idx]}"
}

# Check for rate limit headers
# Usage: check_rate_limit_headers "url"
# Output: Sets RATE_LIMIT_HEADERS (empty if none found)
check_rate_limit_headers() {
    local url="$1"
    RATE_LIMIT_HEADERS=$(curl -s -I --connect-timeout 5 "$url" 2>/dev/null | grep -iE "x-ratelimit|retry-after|x-throttle" || true)
}

# Run sequential latency test
# Usage: run_sequential_latency "base_url"
# Output: Sets LATENCY_MIN, LATENCY_AVG, LATENCY_MAX, LATENCY_RESULT, HTTP_429_COUNT
# Also sets THROTTLE_DETECTED if latency increases significantly
run_sequential_latency() {
    local base_url="$1"
    local -a latencies=()
    HTTP_429_COUNT=0
    THROTTLE_DETECTED=false

    for i in {1..10}; do
        local artifact=$(get_test_artifact $i)
        local test_url="${base_url%/}/$artifact"

        local start=$(get_time_ms)
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$test_url" 2>/dev/null)
        local end=$(get_time_ms)
        local latency=$((end - start))

        if [[ "$http_code" == "429" ]]; then
            ((HTTP_429_COUNT++))
        fi

        # Accept any response that indicates the server responded
        if [[ "$http_code" =~ ^[2-5] ]]; then
            latencies+=($latency)
        fi
    done

    if [[ ${#latencies[@]} -eq 0 ]]; then
        LATENCY_RESULT="failed"
        return 1
    fi

    # Calculate stats
    local sorted=($(printf '%s\n' "${latencies[@]}" | sort -n))
    local sum=0
    for l in "${latencies[@]}"; do
        ((sum += l))
    done

    LATENCY_MIN=${sorted[0]}
    LATENCY_MAX=${sorted[-1]}
    LATENCY_AVG=$((sum / ${#latencies[@]}))

    # Throttling detection: compare first 5 vs last 5
    if [[ ${#latencies[@]} -ge 10 ]]; then
        local first5_sum=0 last5_sum=0
        for i in {0..4}; do
            ((first5_sum += latencies[i]))
            ((last5_sum += latencies[9-4+i]))
        done
        local first5_avg=$((first5_sum / 5))
        local last5_avg=$((last5_sum / 5))

        if (( last5_avg > first5_avg * 2 && first5_avg > 0 )); then
            THROTTLE_DETECTED=true
            THROTTLE_FROM=$first5_avg
            THROTTLE_TO=$last5_avg
        fi
    fi

    # Determine result
    if (( LATENCY_AVG > 500 )); then
        LATENCY_RESULT="high"
        return 1
    elif (( LATENCY_AVG > 200 )); then
        LATENCY_RESULT="elevated"
        return 0
    else
        LATENCY_RESULT="good"
        return 0
    fi
}

# Run parallel throughput test
# Usage: run_parallel_throughput "base_url"
# Output: Sets THROUGHPUT_AVG_MS, THROUGHPUT_RESULT, BATCH_TIME_1, BATCH_TIME_2, BATCH_TIME_3
run_parallel_throughput() {
    local base_url="$1"
    local parallel_count="${LATENCY_PARALLEL_COUNT:-20}"
    local -a batch_times=()

    # Run 3 batches
    for batch in {1..3}; do
        local batch_start=$(get_time_ms)
        local -a pids=()

        # Launch parallel requests
        for ((i=1; i<=parallel_count; i++)); do
            local artifact=$(get_test_artifact $i)
            local url="${base_url%/}/$artifact"
            curl -s -o /dev/null --connect-timeout 10 --max-time 20 "$url" &
            pids+=($!)
        done

        # Wait for all
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null
        done

        local batch_end=$(get_time_ms)
        batch_times+=($((batch_end - batch_start)))
    done

    BATCH_TIME_1=${batch_times[0]}
    BATCH_TIME_2=${batch_times[1]}
    BATCH_TIME_3=${batch_times[2]}

    # Calculate average per request
    THROUGHPUT_AVG_MS=$(( (BATCH_TIME_1 + BATCH_TIME_2 + BATCH_TIME_3) / 3 / parallel_count ))

    # Check for degradation
    if (( BATCH_TIME_3 > BATCH_TIME_1 * 2 && BATCH_TIME_1 > 0 )); then
        THROUGHPUT_RESULT="degraded"
        return 1
    else
        THROUGHPUT_RESULT="good"
        return 0
    fi
}

# Run comprehensive latency test with all checks
# Usage: run_comprehensive_latency_test "name" "base_url"
# This runs all tests and outputs results using pass/warn/fail/info
run_comprehensive_latency_test() {
    local name="$1"
    local base_url="$2"
    local parallel_count="${LATENCY_PARALLEL_COUNT:-20}"

    # Check rate limit headers
    local first_artifact="${LATENCY_TEST_ARTIFACTS[0]}"
    check_rate_limit_headers "${base_url%/}/$first_artifact"
    if [[ -n "$RATE_LIMIT_HEADERS" ]]; then
        warn "$name: rate limit headers detected"
        info "$(echo "$RATE_LIMIT_HEADERS" | head -1)"
    fi

    # Sequential latency test
    info "Testing $name (10 sequential requests)..."
    run_sequential_latency "$base_url"

    if [[ "$LATENCY_RESULT" == "failed" ]]; then
        fail "$name: latency test failed"
        return 1
    fi

    info "Sequential: min=${LATENCY_MIN}ms avg=${LATENCY_AVG}ms max=${LATENCY_MAX}ms"

    # Report latency result
    case "$LATENCY_RESULT" in
        high)
            warn "$name: HIGH average latency ${LATENCY_AVG}ms"
            ;;
        elevated)
            pass "$name: average latency ${LATENCY_AVG}ms (elevated but acceptable)"
            ;;
        *)
            pass "$name: average latency ${LATENCY_AVG}ms"
            ;;
    esac

    # Report throttling
    if [[ "$THROTTLE_DETECTED" == true ]]; then
        warn "$name: possible throttling detected (${THROTTLE_FROM}ms -> ${THROTTLE_TO}ms)"
    fi

    # Parallel throughput test
    info "Testing $name (3 × $parallel_count concurrent)..."
    run_parallel_throughput "$base_url"

    case "$THROUGHPUT_RESULT" in
        timeout)
            warn "$name: parallel test timed out"
            info "Try: LATENCY_PARALLEL_COUNT=10 or SKIP_LATENCY_TEST=true"
            ;;
        degraded)
            warn "$name: batch degradation ${BATCH_TIME_1}ms -> ${BATCH_TIME_3}ms (possible throttling)"
            ;;
        good)
            info "Parallel batches: ${BATCH_TIME_1}ms, ${BATCH_TIME_2}ms, ${BATCH_TIME_3}ms"
            pass "$name: parallel throughput ${THROUGHPUT_AVG_MS}ms/request"
            ;;
    esac

    # HTTP 429 check
    if (( HTTP_429_COUNT > 0 )); then
        fail "$name: rate limiting detected ($HTTP_429_COUNT HTTP 429 responses)"
        info "Contact your artifact repository admin about rate limits"
    fi

    return 0
}
