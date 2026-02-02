#!/bin/bash
# Authentication checks for SCM: test clone with timeout

# Source shared functions if run directly
if [[ -z "$SCRIPT_DIR" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/core.sh"
fi

section "Authentication - SCM"

# Check .git-credentials file if it exists
# Check multiple locations (home dir, current dir, /root for Docker)
GIT_CREDS_FILE=""
for path in "$HOME/.git-credentials" "./.git-credentials" "/root/.git-credentials"; do
    if [[ -f "$path" ]]; then
        GIT_CREDS_FILE="$path"
        break
    fi
done

if [[ -n "$GIT_CREDS_FILE" ]]; then
    # Check 1: Is file non-empty (excluding comments and blank lines)?
    CRED_LINES=$(grep -v '^\s*#' "$GIT_CREDS_FILE" | grep -v '^\s*$' | wc -l | tr -d ' ')
    if (( CRED_LINES == 0 )); then
        fail ".git-credentials: file exists but contains no credentials"
        info "Add credentials in format: https://user:token@hostname"
    else
        pass ".git-credentials: found $CRED_LINES credential(s)"
    fi

    # Check 2: Is file read-only? Git can wipe it on auth failure
    # Note: -w always returns true for root, so check actual permissions
    FILE_PERMS=$(stat -c '%a' "$GIT_CREDS_FILE" 2>/dev/null || stat -f '%Lp' "$GIT_CREDS_FILE" 2>/dev/null)
    if [[ "$FILE_PERMS" =~ ^(400|440|444|000)$ ]]; then
        pass ".git-credentials: file is read-only (mode $FILE_PERMS)"
    else
        warn ".git-credentials: file is writable (mode $FILE_PERMS)"
        info "Git may clear credentials on authentication failure"
        # Detect Docker and suggest appropriate fix
        if [[ -f "/.dockerenv" ]] || grep -q 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
            info "In Docker, mount the file as read-only:"
            info "  -v /path/.git-credentials:/root/.git-credentials:ro"
        else
            info "Consider: chmod 400 ~/.git-credentials"
        fi
    fi

    # Check 3: Do credentials contain characters that need URL escaping?
    # Common issue: Bitbucket PATs contain '/' which must be encoded as %2F
    NEEDS_ESCAPE=false
    while IFS= read -r line; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
            continue
        fi

        # Extract password: format is https://user:password@host
        if [[ "$line" =~ ://[^:]+:([^@]+)@ ]]; then
            password="${BASH_REMATCH[1]}"
            # Check for chars that need escaping: / @ : and space
            if [[ "$password" =~ [/:@\ ] ]]; then
                NEEDS_ESCAPE=true
            fi
        fi
    done < "$GIT_CREDS_FILE"

    if [[ "$NEEDS_ESCAPE" == true ]]; then
        fail ".git-credentials: credentials contain characters that require URL escaping"
        info "Special characters (/ : @ space) in passwords must be URL-encoded"
        info "Common: '/' in Bitbucket PATs must be encoded as '%2F'"
        info ""
        info "To URL-encode a password, run:"
        info "  python3 -c \"import urllib.parse; print(urllib.parse.quote('YOUR_PASSWORD', safe=''))\""
        info ""
        info "Or use this awk command:"
        info "  echo 'YOUR_PASSWORD' | awk '{gsub(/\\//, \"%2F\"); gsub(/:/, \"%3A\"); gsub(/@/, \"%40\"); print}'"
    fi
else
    info ".git-credentials: file not found (may use other auth method)"
fi

info ""

# Find repos.csv
CSV_FILE="${REPOS_CSV:-/app/repos.csv}"
if [[ ! -f "$CSV_FILE" ]]; then
    CSV_FILE="repos.csv"
fi

if [[ ! -f "$CSV_FILE" ]]; then
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

if [[ -z "$CLONEURL_COL" ]]; then
    fail "Clone test: cloneUrl column not found in CSV header"
    return 0 2>/dev/null || exit 0
fi

# Get first repository URL and branch from CSV using dynamic column indices
FIRST_LINE=$(tail -n +2 "$CSV_FILE" | head -1)
FIRST_REPO=$(echo "$FIRST_LINE" | cut -d',' -f"$CLONEURL_COL")
if [[ -n "$BRANCH_COL" ]]; then
    FIRST_BRANCH=$(echo "$FIRST_LINE" | cut -d',' -f"$BRANCH_COL")
fi

if [[ -z "$FIRST_REPO" ]]; then
    info "Skipped: no repositories in repos.csv"
    return 0 2>/dev/null || exit 0
fi

# Default branch if not specified
if [[ -z "$FIRST_BRANCH" ]]; then
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
if check_command timeout; then
    CLONE_OUTPUT=$(GIT_TERMINAL_PROMPT=0 timeout 60 git clone --depth=1 --branch "$FIRST_BRANCH" "$FIRST_REPO" "$TEST_DIR/test-clone" 2>&1)
    CLONE_EXIT=$?
else
    # No timeout available (macOS), just run directly
    CLONE_OUTPUT=$(GIT_TERMINAL_PROMPT=0 git clone --depth=1 --branch "$FIRST_BRANCH" "$FIRST_REPO" "$TEST_DIR/test-clone" 2>&1)
    CLONE_EXIT=$?
fi

END=$(date +%s)
DURATION=$((END - START))

if (( CLONE_EXIT == 0 )) && [[ -d "$TEST_DIR/test-clone/.git" ]]; then
    pass "Clone test: $REPO_NAME (${DURATION}s)"
elif (( CLONE_EXIT == 124 )); then
    fail "Clone test: timed out after 60s"
else
    # Check if it's an auth failure
    if [[ "$CLONE_OUTPUT" =~ authentication|credential|permission|401|403 ]]; then
        warn "Clone test: authentication required"
        info "Configure git credentials for: $FIRST_REPO"
    else
        fail "Clone test: failed"
        # Show first meaningful line of error
        info "$(echo "$CLONE_OUTPUT" | grep -v "^$" | head -1)"
    fi
fi
