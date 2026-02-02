#!/bin/sh
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
LATENCY_TEST_ARTIFACT_1="org/slf4j/slf4j-api/2.0.9/slf4j-api-2.0.9.pom"
LATENCY_TEST_ARTIFACT_2="com/google/guava/guava/31.1-jre/guava-31.1-jre.pom"
LATENCY_TEST_ARTIFACT_3="junit/junit/4.13.2/junit-4.13.2.pom"
LATENCY_TEST_ARTIFACT_4="org/apache/commons/commons-lang3/3.12.0/commons-lang3-3.12.0.pom"
LATENCY_TEST_ARTIFACT_5="com/fasterxml/jackson/core/jackson-core/2.15.2/jackson-core-2.15.2.pom"

# Get artifact by index (1-5, wraps around)
get_test_artifact() {
    case $(( ($1 - 1) % 5 + 1 )) in
        1) echo "$LATENCY_TEST_ARTIFACT_1" ;;
        2) echo "$LATENCY_TEST_ARTIFACT_2" ;;
        3) echo "$LATENCY_TEST_ARTIFACT_3" ;;
        4) echo "$LATENCY_TEST_ARTIFACT_4" ;;
        5) echo "$LATENCY_TEST_ARTIFACT_5" ;;
    esac
}

# Check for rate limit headers
# Usage: check_rate_limit_headers "url"
# Output: Sets RATE_LIMIT_HEADERS (empty if none found)
check_rate_limit_headers() {
    url="$1"
    RATE_LIMIT_HEADERS=$(curl -s -I --connect-timeout 5 "$url" 2>/dev/null | grep -iE "x-ratelimit|retry-after|x-throttle" || true)
}

# Run sequential latency test
# Usage: run_sequential_latency "base_url"
# Output: Sets LATENCY_MIN, LATENCY_AVG, LATENCY_MAX, LATENCY_RESULT, HTTP_429_COUNT
# Also sets THROTTLE_DETECTED if latency increases significantly
run_sequential_latency() {
    base_url="$1"

    LATENCIES=""
    HTTP_429_COUNT=0
    THROTTLE_DETECTED=false
    latency_count=0

    i=1
    while [ $i -le 10 ]; do
        artifact=$(get_test_artifact $i)
        test_url="${base_url%/}/$artifact"

        start=$(get_time_ms)
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$test_url" 2>/dev/null)
        end=$(get_time_ms)
        latency=$((end - start))

        if [ "$http_code" = "429" ]; then
            HTTP_429_COUNT=$((HTTP_429_COUNT + 1))
        fi

        # Accept any response that indicates the server responded
        case "$http_code" in
            2*|3*|4*|5*)
                LATENCIES="$LATENCIES $latency"
                latency_count=$((latency_count + 1))
                ;;
        esac

        i=$((i + 1))
    done

    if [ $latency_count -eq 0 ]; then
        LATENCY_RESULT="failed"
        return 1
    fi

    # Calculate stats using awk
    eval $(echo "$LATENCIES" | tr ' ' '\n' | grep -v '^$' | sort -n | awk '
        BEGIN { sum=0; count=0 }
        {
            vals[count++] = $1
            sum += $1
        }
        END {
            if (count > 0) {
                printf "LATENCY_MIN=%d LATENCY_MAX=%d LATENCY_AVG=%d latency_count=%d", vals[0], vals[count-1], sum/count, count
            }
        }
    ')

    # Throttling detection: compare first 5 vs last 5
    if [ "$latency_count" -ge 10 ]; then
        eval $(echo "$LATENCIES" | tr ' ' '\n' | grep -v '^$' | awk '
            { vals[NR] = $1 }
            END {
                first5 = 0; last5 = 0
                for (i=1; i<=5; i++) first5 += vals[i]
                for (i=NR-4; i<=NR; i++) last5 += vals[i]
                first5_avg = first5/5
                last5_avg = last5/5
                if (last5_avg > first5_avg * 2 && first5_avg > 0) {
                    printf "THROTTLE_DETECTED=true THROTTLE_FROM=%d THROTTLE_TO=%d", first5_avg, last5_avg
                }
            }
        ')
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
# Usage: run_parallel_throughput "base_url"
# Output: Sets THROUGHPUT_AVG_MS, THROUGHPUT_RESULT, BATCH_TIME_1, BATCH_TIME_2, BATCH_TIME_3
run_parallel_throughput() {
    base_url="$1"

    parallel_count="${LATENCY_PARALLEL_COUNT:-20}"
    THROUGHPUT_RESULT=""
    BATCH_TIME_1=""
    BATCH_TIME_2=""
    BATCH_TIME_3=""

    # Run 3 batches
    batch=1
    while [ $batch -le 3 ]; do
        batch_start=$(get_time_ms)

        # Launch parallel requests and collect PIDs
        pids=""
        i=1
        while [ $i -le $parallel_count ]; do
            artifact=$(get_test_artifact $i)
            url="${base_url%/}/$artifact"
            curl -s -o /dev/null --connect-timeout 10 --max-time 20 "$url" &
            pids="$pids $!"
            i=$((i + 1))
        done

        # Wait for all background jobs
        for pid in $pids; do
            wait "$pid" 2>/dev/null
        done

        batch_end=$(get_time_ms)
        batch_time=$((batch_end - batch_start))

        case $batch in
            1) BATCH_TIME_1=$batch_time ;;
            2) BATCH_TIME_2=$batch_time ;;
            3) BATCH_TIME_3=$batch_time ;;
        esac

        batch=$((batch + 1))
    done

    # Calculate average per request
    THROUGHPUT_AVG_MS=$(( (BATCH_TIME_1 + BATCH_TIME_2 + BATCH_TIME_3) / 3 / parallel_count ))

    # Check for degradation
    if [ "$BATCH_TIME_3" -gt $((BATCH_TIME_1 * 2)) ] && [ "$BATCH_TIME_1" -gt 0 ]; then
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
    name="$1"
    base_url="$2"

    parallel_count="${LATENCY_PARALLEL_COUNT:-20}"

    # Check rate limit headers
    first_artifact="$LATENCY_TEST_ARTIFACT_1"
    check_rate_limit_headers "${base_url%/}/$first_artifact"
    if [ -n "$RATE_LIMIT_HEADERS" ]; then
        warn "$name: rate limit headers detected"
        info "$(echo "$RATE_LIMIT_HEADERS" | head -1)"
    fi

    # Sequential latency test
    info "Testing $name (10 sequential requests)..."
    run_sequential_latency "$base_url"

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
    if [ "$HTTP_429_COUNT" -gt 0 ]; then
        fail "$name: rate limiting detected ($HTTP_429_COUNT HTTP 429 responses)"
        info "Contact your artifact repository admin about rate limits"
    fi

    return 0
}
