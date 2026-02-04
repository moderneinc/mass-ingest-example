#!/bin/bash
# Core shared functions for diagnostics
#
# Provides fundamental utilities used across all diagnostic scripts:
# - Colors and output formatting (pass/warn/fail/info/section)
# - Command checking
# - Time measurement
# - Byte formatting
# - CSV column parsing

# Colors (disabled if not terminal or NO_COLOR set)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
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

# Get current time in milliseconds
# GNU date supports %N for nanoseconds, macOS doesn't (falls back to seconds)
get_time_ms() {
    local time_ns
    time_ns=$(date +%s%N 2>/dev/null)
    if [[ ${#time_ns} -gt 10 ]]; then
        echo "${time_ns:0:13}"
    else
        echo "$(($(date +%s) * 1000))"
    fi
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        awk "BEGIN {printf \"%.1fGB\", $bytes / 1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN {printf \"%.1fMB\", $bytes / 1048576}"
    elif (( bytes >= 1024 )); then
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

# Get CSV column index by name (case-insensitive, fixed string match)
# Requires $HEADER to be set to the CSV header line
get_col_index() {
    local target="$1"
    local target_lower=$(echo "$target" | tr '[:upper:]' '[:lower:]')
    local idx=0
    # Use comma as delimiter and iterate to find exact match
    while IFS= read -r col; do
        idx=$((idx + 1))
        # Case-insensitive exact match (portable - works with Bash 3.x)
        local col_lower=$(echo "$col" | tr '[:upper:]' '[:lower:]')
        if [[ "$col_lower" == "$target_lower" ]]; then
            echo "$idx"
            return 0
        fi
    done < <(echo "$HEADER" | tr ',' '\n')
}

# Find repos.csv file (checks REPOS_CSV env, /app/repos.csv, ./repos.csv)
# Sets CSV_FILE variable and returns 0 if found, 1 if not
find_repos_csv() {
    CSV_FILE="${REPOS_CSV:-/app/repos.csv}"
    if [[ ! -f "$CSV_FILE" ]]; then
        CSV_FILE="repos.csv"
    fi
    [[ -f "$CSV_FILE" ]]
}

# Strip ANSI escape codes from input
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# Detect if running inside a container
# Sets: IN_CONTAINER (true/false), CONTAINER_TYPE (Docker/Podman/container/empty)
detect_container() {
    IN_CONTAINER=false
    CONTAINER_TYPE=""

    # Check for Docker (most common)
    if [[ -f /.dockerenv ]]; then
        IN_CONTAINER=true
        CONTAINER_TYPE="Docker"
        return 0
    fi

    # Check for Podman
    if [[ -f /run/.containerenv ]]; then
        IN_CONTAINER=true
        CONTAINER_TYPE="Podman"
        return 0
    fi

    # Check cgroups v1 (older systems)
    if grep -qE 'docker|containerd|lxc' /proc/1/cgroup 2>/dev/null; then
        IN_CONTAINER=true
        CONTAINER_TYPE="container"
        return 0
    fi

    # Check cgroups v2 (modern systems) - look for container indicators in mountinfo
    if [[ -f /proc/1/mountinfo ]]; then
        if grep -qE 'workdir=.*(docker|containers|buildkit)' /proc/1/mountinfo 2>/dev/null; then
            IN_CONTAINER=true
            CONTAINER_TYPE="container"
            return 0
        fi
        # Also check for overlay filesystem with typical container paths
        if grep -qE '^[0-9]+ [0-9]+ [0-9]+:[0-9]+ / / .*overlay' /proc/1/mountinfo 2>/dev/null; then
            IN_CONTAINER=true
            CONTAINER_TYPE="container"
            return 0
        fi
    fi

    return 1
}

# Note: Functions are available to scripts that source this file directly.
# No export -f needed (and it's not POSIX compatible anyway).
