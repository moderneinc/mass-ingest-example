#!/bin/sh
# Core shared functions for diagnostics
#
# Provides fundamental utilities used across all diagnostic scripts:
# - Colors and output formatting (pass/warn/fail/info/section)
# - Command checking
# - Time measurement
# - Byte formatting

# Colors (disabled if not terminal or NO_COLOR set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[38;5;245m'
    NC='\033[0m'
else
    GREEN='' YELLOW='' RED='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

export GREEN YELLOW RED BLUE CYAN BOLD DIM NC

# Counters (initialized if not already set by parent)
: "${PASS_COUNT:=0}"
: "${WARN_COUNT:=0}"
: "${FAIL_COUNT:=0}"

# Result tracking
# Note: %b interprets backslash escapes in color codes
pass() {
    printf "%b[PASS]%b %s\n" "$GREEN" "$NC" "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
    printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
    printf "%b[FAIL]%b %s\n" "$RED" "$NC" "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

info() {
    printf "%b       %s%b\n" "$DIM" "$1" "$NC"
}

section() {
    echo ""
    printf "%b=== %s ===%b\n" "$BOLD" "$1" "$NC"
}

# Check if a command exists
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Get current time in milliseconds (works on GNU and BusyBox date)
# BusyBox/macOS date doesn't support %N, so we fall back to seconds precision
get_time_ms() {
    time_ns=$(date +%s%N 2>/dev/null)
    # Check if we got nanoseconds (length > 10) using expr
    if [ "$(expr "$time_ns" : '.*')" -gt 10 ] 2>/dev/null; then
        # Extract first 13 chars for milliseconds using cut
        echo "$time_ns" | cut -c1-13
    else
        echo "$(($(date +%s) * 1000))"
    fi
}

# Format bytes to human readable (uses awk for portability)
format_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.1fGB\", $bytes / 1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.1fMB\", $bytes / 1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1fKB\", $bytes / 1024}"
    else
        echo "${bytes}B"
    fi
}

# Format number with thousands separator
format_number() {
    local num=$1
    printf "%'d" "$num" 2>/dev/null || echo "$num"
}

# Check if a hostname resolves (DNS check)
# Returns 0 if DNS resolves, 1 if not
check_dns() {
    local host="$1"

    # Try getent (Linux)
    if check_command getent; then
        getent hosts "$host" >/dev/null 2>&1 && return 0
    fi

    # Try dscacheutil (macOS)
    if check_command dscacheutil; then
        dscacheutil -q host -a name "$host" 2>/dev/null | grep -q "ip_address" && return 0
    fi

    # Try host command
    if check_command host; then
        host "$host" >/dev/null 2>&1 && return 0
    fi

    # Fallback: try ping with timeout (just to resolve, not actually ping)
    if check_command ping; then
        ping -c 1 -W 1 "$host" >/dev/null 2>&1 && return 0
    fi

    return 1
}

# Note: Functions are available to scripts that source this file directly.
# No export -f needed (and it's not POSIX compatible anyway).
