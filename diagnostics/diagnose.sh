#!/bin/bash
#
# Mass-ingest comprehensive diagnostics
#
# Usage:
#   DIAGNOSE=true docker compose up     # Full diagnostics, no ingestion
#   DIAGNOSE_ON_START=true ...          # Run diagnostics before ingestion
#   ./diagnostics/diagnose.sh           # Run directly
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
#
# Individual checks can be run directly:
#   ./diagnostics/checks/docker.sh
#   ./diagnostics/checks/cli.sh
#   etc.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS_DIR="$SCRIPT_DIR/checks"

# Mode flags
FUNCTIONS_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --functions-only)
            FUNCTIONS_ONLY=true
            shift
            ;;
        -h|--help)
            head -16 "$0" | tail -14
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Export for child scripts
export SCRIPT_DIR
export CHECKS_DIR

################################################################################
# Shared functions
################################################################################

# Colors (disabled if not terminal or NO_COLOR set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[38;5;245m'  # Medium gray (256 color)
    NC='\033[0m'
else
    GREEN='' YELLOW='' RED='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

export GREEN YELLOW RED BLUE CYAN BOLD DIM NC

# Counters
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# Result tracking
pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASS_COUNT++))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARN_COUNT++))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAIL_COUNT++))
}

info() {
    echo -e "${DIM}       $1${NC}"
}

section() {
    echo ""
    echo -e "${BOLD}=== $1 ===${NC}"
}

# Check if a command exists
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Get current time in milliseconds (works on GNU and BusyBox date)
# BusyBox date doesn't support %N, so we fall back to seconds precision
get_time_ms() {
    local time_ns
    time_ns=$(date +%s%N 2>/dev/null)
    if [ ${#time_ns} -gt 10 ]; then
        # GNU date with nanoseconds
        echo "${time_ns:0:13}"
    else
        # BusyBox date - seconds only, multiply by 1000
        echo "$(($(date +%s) * 1000))"
    fi
}

# Check if a URL is reachable (returns HTTP 2xx/3xx)
check_reachable() {
    local url="$1"
    local timeout="${2:-5}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout" "$url" 2>/dev/null)
    [[ "$code" =~ ^[23] ]]
}

# Measure latency to a URL in milliseconds
measure_latency() {
    local url="$1"
    local start end
    start=$(get_time_ms)
    curl -s -o /dev/null --connect-timeout 5 "$url" 2>/dev/null
    end=$(get_time_ms)
    echo $((end - start))
}

# Get unique origins from repos.csv
get_origins() {
    local csv="${1:-/app/repos.csv}"
    if [ -f "$csv" ]; then
        # Dynamically find origin column index
        local header origin_col
        header=$(head -1 "$csv")
        origin_col=$(echo "$header" | tr ',' '\n' | grep -ni "^origin$" | cut -d: -f1)
        if [ -n "$origin_col" ]; then
            tail -n +2 "$csv" | cut -d',' -f"$origin_col" | sort -u | grep -v '^$'
        fi
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

# Export functions for child scripts
export -f pass warn fail info section check_command get_time_ms check_reachable measure_latency get_origins format_bytes

################################################################################
# Main execution (skip if --functions-only)
################################################################################

if [ "$FUNCTIONS_ONLY" = true ]; then
    return 0 2>/dev/null || exit 0
fi

# Set up logging to file and stdout
LOG_DIR="./.moderne"
LOG_FILE="$LOG_DIR/diagnostics.log"
mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_FILE") 2>&1

# Track start time
DIAG_START=$(date +%s)

# Print header
echo ""
echo -e "${BOLD}Mass-ingest Diagnostics${NC}"
echo "Generated: $(date '+%Y-%m-%d %H:%M %Z')"

# Run checks
run_check() {
    local check="$1"
    local script="$CHECKS_DIR/$check.sh"
    if [ -f "$script" ]; then
        source "$script"
    else
        echo -e "${YELLOW}[SKIP]${NC} Check not found: $check"
    fi
}

# Run all checks in logical order:
# 1. System resources (CPU, memory, disk)
# 2. Required tools (git, curl, etc.)
# 3. Docker/runtime environment
# 4. Java/JDKs
# 5. Moderne CLI
# 6. Configuration (env vars, credentials)
# 7. Input data (repos.csv)
# 8. Network connectivity
# 9. SSL certificates
# 10. Authentication tests

run_check "system"
run_check "tools"
run_check "docker"
run_check "java"
run_check "cli"
run_check "config"
run_check "repos-csv"
run_check "network"
run_check "ssl"
run_check "auth-publish"
run_check "auth-scm"
run_check "publish-latency"

# Calculate duration
DIAG_END=$(date +%s)
DIAG_DURATION=$((DIAG_END - DIAG_START))

# Print summary
echo ""
echo "========================================"
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${BOLD}RESULT:${NC} ${RED}$FAIL_COUNT failure(s)${NC}, ${YELLOW}$WARN_COUNT warning(s)${NC}, ${GREEN}$PASS_COUNT passed${NC}"
elif [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "${BOLD}RESULT:${NC} ${YELLOW}$WARN_COUNT warning(s)${NC}, ${GREEN}$PASS_COUNT passed${NC}"
else
    echo -e "${BOLD}RESULT:${NC} ${GREEN}All $PASS_COUNT checks passed${NC}"
fi
echo -e "${DIM}Completed in ${DIAG_DURATION}s${NC}"
echo "========================================"
echo ""

# Exit with appropriate code
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
