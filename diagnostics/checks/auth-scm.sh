#!/bin/bash
# Authentication checks for SCM: test clone with timeout

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../diagnose.sh" --functions-only
fi

section "Authentication - SCM"

# Find repos.csv
CSV_FILE="${REPOS_CSV:-/app/repos.csv}"
if [ ! -f "$CSV_FILE" ]; then
    CSV_FILE="repos.csv"
fi

if [ ! -f "$CSV_FILE" ]; then
    info "Skipped: repos.csv not found"
    return 0 2>/dev/null || exit 0
fi

# Parse header to find column indices
HEADER=$(head -1 "$CSV_FILE")

# Get column index by name (case-insensitive)
get_col_index() {
    echo "$HEADER" | tr ',' '\n' | grep -ni "^$1$" | cut -d: -f1
}

CLONEURL_COL=$(get_col_index "cloneUrl")
BRANCH_COL=$(get_col_index "branch")

if [ -z "$CLONEURL_COL" ]; then
    fail "Clone test: cloneUrl column not found in CSV header"
    return 0 2>/dev/null || exit 0
fi

# Get first repository URL and branch from CSV using dynamic column indices
FIRST_LINE=$(tail -n +2 "$CSV_FILE" | head -1)
FIRST_REPO=$(echo "$FIRST_LINE" | cut -d',' -f"$CLONEURL_COL")
if [ -n "$BRANCH_COL" ]; then
    FIRST_BRANCH=$(echo "$FIRST_LINE" | cut -d',' -f"$BRANCH_COL")
fi

if [ -z "$FIRST_REPO" ]; then
    info "Skipped: no repositories in repos.csv"
    return 0 2>/dev/null || exit 0
fi

# Default branch if not specified
if [ -z "$FIRST_BRANCH" ]; then
    FIRST_BRANCH="main"
fi

# Extract repo name for display
REPO_NAME=$(echo "$FIRST_REPO" | sed 's|.*/||' | sed 's|\.git$||')

# Create temp directory for test clone
TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

# Clone with timeout (1 minute)
START=$(date +%s)

# Use GIT_TERMINAL_PROMPT=0 to fail fast on auth issues instead of hanging
# Handle missing timeout command (macOS)
if check_command timeout; then
    CLONE_OUTPUT=$(GIT_TERMINAL_PROMPT=0 timeout 60 git clone --depth=1 --branch "$FIRST_BRANCH" "$FIRST_REPO" "$TEST_DIR/test-clone" 2>&1)
    CLONE_EXIT=$?
else
    # No timeout available, just run directly
    CLONE_OUTPUT=$(GIT_TERMINAL_PROMPT=0 git clone --depth=1 --branch "$FIRST_BRANCH" "$FIRST_REPO" "$TEST_DIR/test-clone" 2>&1)
    CLONE_EXIT=$?
fi

END=$(date +%s)
DURATION=$((END - START))

if [ $CLONE_EXIT -eq 0 ] && [ -d "$TEST_DIR/test-clone/.git" ]; then
    pass "Clone test: $REPO_NAME (${DURATION}s)"
elif [ $CLONE_EXIT -eq 124 ]; then
    fail "Clone test: timed out after 60s"
else
    # Check if it's an auth failure
    if echo "$CLONE_OUTPUT" | grep -qi "authentication\|credential\|permission\|401\|403"; then
        warn "Clone test: authentication required"
        info "Configure git credentials for: $FIRST_REPO"
    else
        fail "Clone test: failed"
        # Show first meaningful line of error
        echo "$CLONE_OUTPUT" | grep -v "^$" | head -1 | while read -r line; do
            info "$line"
        done
    fi
fi
