#!/bin/bash
# Thread and process limit checks: cgroup PID limits, ulimit, kernel threads-max
# Helps diagnose pthread_create EAGAIN errors caused by hitting thread/PID limits

# Source shared functions if run directly
if [[ -z "$SCRIPT_DIR" ]]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

section "Thread and process limits"
info "Java builds use many threads. Low PID/thread limits cause 'pthread_create' errors."
info "Expect: unlimited or 8192+ for cgroup PID limit and ulimit."

# Detect container environment if not already done
if [[ -z "${IN_CONTAINER:-}" ]]; then
    detect_container
fi

# Cgroup PID limit
PID_MAX=""
if [[ -f /sys/fs/cgroup/pids.max ]]; then
    PID_MAX=$(cat /sys/fs/cgroup/pids.max 2>/dev/null)
elif [[ -f /sys/fs/cgroup/pids/pids.max ]]; then
    PID_MAX=$(cat /sys/fs/cgroup/pids/pids.max 2>/dev/null)
fi

# Current PID count from cgroup
PID_CURRENT=""
if [[ -f /sys/fs/cgroup/pids.current ]]; then
    PID_CURRENT=$(cat /sys/fs/cgroup/pids.current 2>/dev/null)
elif [[ -f /sys/fs/cgroup/pids/pids.current ]]; then
    PID_CURRENT=$(cat /sys/fs/cgroup/pids/pids.current 2>/dev/null)
fi

PID_LIMIT_MIN=8192

if [[ -n "$PID_MAX" ]] && [[ -n "$PID_CURRENT" ]]; then
    if [[ "$PID_MAX" == "max" ]]; then
        pass "Cgroup PID limit: unlimited ($PID_CURRENT currently used)"
    else
        USAGE_PCT=$((PID_CURRENT * 100 / PID_MAX))
        if [[ "$USAGE_PCT" -ge 90 ]]; then
            fail "Cgroup PID usage: $PID_CURRENT / $PID_MAX (${USAGE_PCT}%)"
            info "Near the PID limit — likely cause of pthread_create EAGAIN errors"
            info "Increase with: docker run --pids-limit=$PID_LIMIT_MIN or --pids-limit=-1 for unlimited"
        elif [[ "$USAGE_PCT" -ge 70 ]]; then
            warn "Cgroup PID usage: $PID_CURRENT / $PID_MAX (${USAGE_PCT}%)"
            info "PID usage is elevated, may become a problem under load"
        elif [[ "$PID_MAX" -lt "$PID_LIMIT_MIN" ]]; then
            warn "Cgroup PID limit: $PID_MAX ($PID_CURRENT currently used)"
            info "Recommend at least $PID_LIMIT_MIN for mass-ingest workloads"
            info "Increase with: docker run --pids-limit=$PID_LIMIT_MIN or --pids-limit=-1 for unlimited"
        else
            pass "Cgroup PID limit: $PID_MAX ($PID_CURRENT currently used)"
        fi
    fi
elif [[ -n "$PID_MAX" ]]; then
    if [[ "$PID_MAX" == "max" ]]; then
        pass "Cgroup PID limit: unlimited"
    elif [[ "$PID_MAX" -lt "$PID_LIMIT_MIN" ]]; then
        warn "Cgroup PID limit: $PID_MAX"
        info "Recommend at least $PID_LIMIT_MIN for mass-ingest workloads"
        info "Increase with: docker run --pids-limit=$PID_LIMIT_MIN or --pids-limit=-1 for unlimited"
    else
        pass "Cgroup PID limit: $PID_MAX"
    fi
fi

# ulimit -u (max user processes, includes threads on Linux)
ULIMIT_U=$(ulimit -u 2>/dev/null)
if [[ -n "$ULIMIT_U" ]]; then
    if [[ "$ULIMIT_U" == "unlimited" ]]; then
        pass "Max user processes (ulimit -u): unlimited"
    elif [[ "$ULIMIT_U" -lt "$PID_LIMIT_MIN" ]] 2>/dev/null; then
        warn "Max user processes (ulimit -u): $ULIMIT_U (recommend ${PID_LIMIT_MIN}+)"
        info "On Linux, threads count against this limit and can cause pthread_create EAGAIN"
    else
        pass "Max user processes (ulimit -u): $ULIMIT_U"
    fi
fi

# System-wide thread limit (info only — almost never the bottleneck, defaults to 100k+)
if [[ -f /proc/sys/kernel/threads-max ]]; then
    THREADS_MAX=$(cat /proc/sys/kernel/threads-max 2>/dev/null)
    if [[ -n "$THREADS_MAX" ]]; then
        if [[ "$THREADS_MAX" -lt 8192 ]] 2>/dev/null; then
            warn "Kernel threads-max: $THREADS_MAX (unusually low)"
        else
            info "Kernel threads-max: $THREADS_MAX"
        fi
    fi
fi