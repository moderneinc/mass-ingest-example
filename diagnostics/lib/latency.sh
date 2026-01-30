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

# Source shared functions if not already loaded
if ! declare -f get_time_ms >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/../diagnose.sh" --functions-only
fi

# Test artifacts - common POMs that likely exist in any Maven repo
LATENCY_TEST_ARTIFACTS=(
    "org/slf4j/slf4j-api/2.0.9/slf4j-api-2.0.9.pom"
    "com/google/guava/guava/31.1-jre/guava-31.1-jre.pom"
    "junit/junit/4.13.2/junit-4.13.2.pom"
    "org/apache/commons/commons-lang3/3.12.0/commons-lang3-3.12.0.pom"
    "com/fasterxml/jackson/core/jackson-core/2.15.2/jackson-core-2.15.2.pom"
)

# Check for rate limit headers
# Usage: check_rate_limit_headers "url" [curl_args...]
# Output: Sets RATE_LIMIT_HEADERS (empty if none found)
check_rate_limit_headers() {
    local url="$1"
    shift
    local curl_args=("$@")

    RATE_LIMIT_HEADERS=$(curl -s -I --connect-timeout 5 "${curl_args[@]}" "$url" 2>/dev/null | grep -iE "x-ratelimit|retry-after|x-throttle" || true)
}

# Run sequential latency test
# Usage: run_sequential_latency "base_url" [curl_args...]
# Output: Sets LATENCY_MIN, LATENCY_AVG, LATENCY_MAX, LATENCY_RESULT, HTTP_429_COUNT, LATENCIES array
# Also sets THROTTLE_DETECTED if latency increases significantly
run_sequential_latency() {
    local base_url="$1"
    shift
    local curl_args=("$@")

    local artifact_count=${#LATENCY_TEST_ARTIFACTS[@]}
    LATENCIES=()
    HTTP_429_COUNT=0
    THROTTLE_DETECTED=false

    for i in $(seq 1 10); do
        local artifact="${LATENCY_TEST_ARTIFACTS[$((i % artifact_count))]}"
        local test_url="${base_url%/}/$artifact"

        local start end latency http_code
        start=$(get_time_ms)
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "${curl_args[@]}" "$test_url" 2>/dev/null)
        end=$(get_time_ms)
        latency=$((end - start))

        if [ "$http_code" = "429" ]; then
            ((HTTP_429_COUNT++))
        fi

        # Accept any response that indicates the server responded
        if [[ "$http_code" =~ ^[2-5] ]]; then
            LATENCIES+=("$latency")
        fi
    done

    if [ ${#LATENCIES[@]} -eq 0 ]; then
        LATENCY_RESULT="failed"
        return 1
    fi

    # Calculate stats
    local sorted=($(printf '%s\n' "${LATENCIES[@]}" | sort -n))
    local count=${#sorted[@]}
    LATENCY_MIN=${sorted[0]}
    LATENCY_MAX=${sorted[$((count-1))]}
    local sum=0
    for lat in "${LATENCIES[@]}"; do
        sum=$((sum + lat))
    done
    LATENCY_AVG=$((sum / count))

    # Throttling detection: compare first 5 vs last 5
    if [ "$count" -ge 10 ]; then
        local first_5_sum=0 last_5_sum=0
        for i in 0 1 2 3 4; do
            first_5_sum=$((first_5_sum + ${LATENCIES[$i]}))
            last_5_sum=$((last_5_sum + ${LATENCIES[$((count - 5 + i))]}))
        done
        local first_5_avg=$((first_5_sum / 5))
        local last_5_avg=$((last_5_sum / 5))

        if [ "$last_5_avg" -gt $((first_5_avg * 2)) ] && [ "$first_5_avg" -gt 0 ]; then
            THROTTLE_DETECTED=true
            THROTTLE_FROM=$first_5_avg
            THROTTLE_TO=$last_5_avg
        fi
    fi

    # Determine result
    if [ "$LATENCY_AVG" -gt 500 ]; then
        LATENCY_RESULT="high"
        return 1
    elif [ "$LATENCY_AVG" -gt 200 ]; then
        LATENCY_RESULT="elevated"
        return 0
    else
        LATENCY_RESULT="good"
        return 0
    fi
}

# Run parallel throughput test
# Usage: run_parallel_throughput "base_url" [curl_args...]
# Output: Sets THROUGHPUT_AVG_MS, THROUGHPUT_RESULT, BATCH_TIMES array
run_parallel_throughput() {
    local base_url="$1"
    shift
    local curl_args=("$@")

    local parallel_count="${LATENCY_PARALLEL_COUNT:-20}"
    local batch_timeout="${LATENCY_TIMEOUT:-30}"
    local artifact_count=${#LATENCY_TEST_ARTIFACTS[@]}
    BATCH_TIMES=()
    THROUGHPUT_RESULT=""

    # Run parallel batch with timeout
    run_batch() {
        local batch_pids=()
        for i in $(seq 1 $parallel_count); do
            local artifact="${LATENCY_TEST_ARTIFACTS[$((i % artifact_count))]}"
            local url="${base_url%/}/$artifact"
            curl -s -o /dev/null --connect-timeout 10 --max-time 20 "${curl_args[@]}" "$url" &
            batch_pids+=($!)
        done

        local waited=0
        while [ $waited -lt $batch_timeout ]; do
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

        # Timeout - kill remaining
        for pid in "${batch_pids[@]}"; do
            kill "$pid" 2>/dev/null
        done
        return 1
    }

    # Run 3 batches
    for batch in 1 2 3; do
        local batch_start batch_end batch_time
        batch_start=$(get_time_ms)
        if ! run_batch; then
            THROUGHPUT_RESULT="timeout"
            return 1
        fi
        batch_end=$(get_time_ms)
        batch_time=$((batch_end - batch_start))
        BATCH_TIMES+=("$batch_time")
    done

    # Calculate average per request
    local batch1=${BATCH_TIMES[0]}
    local batch2=${BATCH_TIMES[1]}
    local batch3=${BATCH_TIMES[2]}
    THROUGHPUT_AVG_MS=$(( (batch1 + batch2 + batch3) / 3 / parallel_count ))

    # Check for degradation
    if [ "$batch3" -gt $((batch1 * 2)) ] && [ "$batch1" -gt 0 ]; then
        THROUGHPUT_RESULT="degraded"
        return 1
    else
        THROUGHPUT_RESULT="good"
        return 0
    fi
}

# Run comprehensive latency test with all checks
# Usage: run_comprehensive_latency_test "name" "base_url" [curl_args...]
# This runs all tests and outputs results using pass/warn/fail/info
run_comprehensive_latency_test() {
    local name="$1"
    local base_url="$2"
    shift 2
    local curl_args=("$@")

    local parallel_count="${LATENCY_PARALLEL_COUNT:-20}"

    # Check rate limit headers
    local first_artifact="${LATENCY_TEST_ARTIFACTS[0]}"
    check_rate_limit_headers "${base_url%/}/$first_artifact" "${curl_args[@]}"
    if [ -n "$RATE_LIMIT_HEADERS" ]; then
        warn "$name: rate limit headers detected"
        info "$(echo "$RATE_LIMIT_HEADERS" | head -1)"
    fi

    # Sequential latency test
    info "Testing $name (10 sequential requests)..."
    run_sequential_latency "$base_url" "${curl_args[@]}"

    if [ "$LATENCY_RESULT" = "failed" ]; then
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
    if [ "$THROTTLE_DETECTED" = true ]; then
        warn "$name: possible throttling detected (${THROTTLE_FROM}ms -> ${THROTTLE_TO}ms)"
    fi

    # Parallel throughput test
    info "Testing $name (3 × $parallel_count concurrent)..."
    run_parallel_throughput "$base_url" "${curl_args[@]}"

    case "$THROUGHPUT_RESULT" in
        timeout)
            warn "$name: parallel test timed out"
            info "Try: LATENCY_PARALLEL_COUNT=10 or SKIP_LATENCY_TEST=true"
            ;;
        degraded)
            warn "$name: batch degradation ${BATCH_TIMES[0]}ms -> ${BATCH_TIMES[2]}ms (possible throttling)"
            ;;
        good)
            info "Parallel batches: ${BATCH_TIMES[0]}ms, ${BATCH_TIMES[1]}ms, ${BATCH_TIMES[2]}ms"
            pass "$name: parallel throughput ${THROUGHPUT_AVG_MS}ms/request"
            ;;
    esac

    # HTTP 429 check
    if [ "$HTTP_429_COUNT" -gt 0 ]; then
        fail "$name: rate limiting detected ($HTTP_429_COUNT HTTP 429 responses)"
        info "Contact your artifact repository admin about rate limits"
    fi

    return 0
}

# Export functions
export -f check_rate_limit_headers run_sequential_latency run_parallel_throughput run_comprehensive_latency_test
export LATENCY_TEST_ARTIFACTS
