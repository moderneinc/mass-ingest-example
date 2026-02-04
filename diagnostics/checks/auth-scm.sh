#!/bin/bash
# SCM credential file checks: .git-credentials validation
#
# Validates the .git-credentials file for common issues:
# - File exists and contains credentials
# - File permissions (read-only recommended)
# - URL encoding issues in passwords
#
# Note: Actual SCM connectivity is tested by scm-repos.sh

# Source shared functions if run directly
if [[ -z "$SCRIPT_DIR" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/core.sh"
fi

section "SCM credentials"

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
        # Detect container and suggest appropriate fix (detect_container from core.sh)
        detect_container
        if [[ "$IN_CONTAINER" == true ]]; then
            info "In container, mount the file as read-only:"
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

        # Extract password using step-by-step parsing (handles @ in passwords, port numbers)
        # Format: https://user:password@host[:port][/path]
        # 1. Strip protocol prefix (https://, http://)
        without_proto="${line#*://}"
        # 2. Get the userinfo part (everything before the last @)
        #    Using parameter expansion: remove shortest match from end
        if [[ "$without_proto" == *@* ]]; then
            userinfo="${without_proto%@*}"
            # 3. Extract password (everything after first :)
            if [[ "$userinfo" == *:* ]]; then
                password="${userinfo#*:}"
                # Check for chars that need escaping: / @ : space % # ? +
                if [[ "$password" =~ [/:@\ %#?+] ]]; then
                    NEEDS_ESCAPE=true
                fi
            fi
        fi
    done < "$GIT_CREDS_FILE"

    if [[ "$NEEDS_ESCAPE" == true ]]; then
        fail ".git-credentials: credentials contain characters that require URL escaping"
        info "Special characters (/ : @ space % # ? +) in passwords must be URL-encoded"
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
