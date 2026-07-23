#!/bin/bash
# SCM credential file checks: .git-credentials validation
#
# Validates the .git-credentials file for common issues:
# - File exists and contains credentials
# - Credential helper cannot erase the file on auth failure
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

    # Check 2: Do credentials contain characters that need URL escaping?
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

# Credential helper check: can git erase the credentials on auth failure?
# When a server rejects a credential (HTTP 401), git asks every configured helper to
# erase it; a store helper then wipes the file's entry for that whole host, failing
# every remaining repository on that host. A get-only helper ignores erase requests.
# File permissions do not protect against this: store replaces the file via rename,
# so only directory writability matters. This check runs even when the credentials
# file does not exist yet (publish.sh writes it from GIT_CREDENTIALS after startup
# diagnostics have already run).
CRED_PATH="${GIT_CREDS_FILE:-$HOME/.git-credentials}"
case "$CRED_PATH" in
    /*) ;;
    *) CRED_PATH="$(cd "$(dirname "$CRED_PATH")" && pwd)/$(basename "$CRED_PATH")" ;;
esac
# An empty helper entry resets the list accumulated so far, so only entries after the
# last empty one are active.
GIT_HELPERS=$(git config --get-all credential.helper 2>/dev/null | awk '{ if ($0 == "") out = ""; else out = out $0 "\n" } END { printf "%s", out }')
HELPER_SAFE=false
HELPER_UNSAFE=false
while IFS= read -r helper; do
    [[ -z "$helper" ]] && continue
    if [[ "$helper" == *'if [ "$1" = "get" ]'* ]]; then
        HELPER_SAFE=true
    elif [[ "$helper" == store* || "$helper" == *credential-store* ]]; then
        HELPER_UNSAFE=true
    fi
done <<< "$GIT_HELPERS"
detect_container
if [[ "$HELPER_UNSAFE" == true ]]; then
    if [[ "$IN_CONTAINER" == true ]]; then
        warn "credential.helper: a store helper is active, git erases credentials on auth failure"
        info "One rejected clone (HTTP 401) wipes the host's entry from $CRED_PATH,"
        info "failing every remaining repository on that host. Configure a get-only helper instead:"
        info "  git config --global --replace-all credential.helper '!f() { if [ \"\$1\" = \"get\" ]; then git credential-store --file=$CRED_PATH get; fi; }; f'"
    else
        info "credential.helper: a store helper is active; a rejected clone (HTTP 401) erases that host's entry from $CRED_PATH"
        info "This is normal on a workstation; the mass-ingest container image configures a get-only helper instead"
    fi
elif [[ "$HELPER_SAFE" == true ]]; then
    pass "credential.helper: get-only wrapper (erase requests ignored)"
elif [[ -z "$GIT_HELPERS" ]]; then
    if [[ "$IN_CONTAINER" == true ]]; then
        warn "credential.helper: not configured, git will not read $CRED_PATH"
    else
        info "credential.helper: not configured"
    fi
else
    info "credential.helper: custom helper configured (not validated)"
fi
