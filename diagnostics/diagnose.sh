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

# Check for bash (required for these scripts)
if [[ -z "$BASH_VERSION" ]]; then
    echo "Error: bash is required. Install with: apk add bash (Alpine) or apt install bash (Debian)"
    exit 1
fi

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
# Shared functions (from lib/core.sh)
################################################################################

# Initialize counters before sourcing core.sh
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# Source the core library
source "$SCRIPT_DIR/lib/core.sh"

################################################################################
# Main execution (skip if --functions-only)
################################################################################

if [[ "$FUNCTIONS_ONLY" == true ]]; then
    return 0 2>/dev/null || exit 0
fi

# Set up logging directory (output will be captured by caller if needed)
LOG_DIR="./.moderne"
LOG_FILE="$LOG_DIR/diagnostics.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Track start time
DIAG_START=$(date +%s)

# Print header
echo ""
printf "%bMass-ingest Diagnostics%b\n" "$BOLD" "$NC"
echo "Generated: $(date '+%Y-%m-%d %H:%M %Z')"

# Check for millisecond timing support (GNU date with %N)
_test_time=$(date +%s%N 2>/dev/null)
if [[ ${#_test_time} -le 10 ]]; then
    warn "Millisecond timing unavailable (install coreutils for accurate latency measurements)"
fi
unset _test_time

# Run checks
run_check() {
    local check="$1"
    local script="$CHECKS_DIR/$check.sh"
    if [[ -f "$script" ]]; then
        source "$script"
    else
        printf "%b[SKIP]%b Check not found: %s\n" "$YELLOW" "$NC" "$check"
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
# 11. Latency tests (publish, maven, dependencies, scm)

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
run_check "maven-repos"
run_check "dependency-repos"
run_check "scm-repos"

# Calculate duration
DIAG_END=$(date +%s)
DIAG_DURATION=$((DIAG_END - DIAG_START))

# Print summary
echo ""
echo "========================================"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf "%bRESULT:%b %b%d failure(s)%b, %b%d warning(s)%b, %b%d passed%b\n" "$BOLD" "$NC" "$RED" "$FAIL_COUNT" "$NC" "$YELLOW" "$WARN_COUNT" "$NC" "$GREEN" "$PASS_COUNT" "$NC"
elif [[ "$WARN_COUNT" -gt 0 ]]; then
    printf "%bRESULT:%b %b%d warning(s)%b, %b%d passed%b\n" "$BOLD" "$NC" "$YELLOW" "$WARN_COUNT" "$NC" "$GREEN" "$PASS_COUNT" "$NC"
else
    printf "%bRESULT:%b %bAll %d checks passed%b\n" "$BOLD" "$NC" "$GREEN" "$PASS_COUNT" "$NC"
fi
printf "%bCompleted in %ss%b\n" "$DIM" "$DIAG_DURATION" "$NC"
echo "========================================"
echo ""

# Exit with appropriate code
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
