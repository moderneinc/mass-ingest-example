#!/bin/bash
# Configuration checks: environment variables, credentials

# Source shared functions if run directly
if [[ -z "$SCRIPT_DIR" ]]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

section "Configuration"

# Data directory
DATA_DIR="${DATA_DIR:-/var/moderne}"
if [[ -d "$DATA_DIR" ]]; then
    if [[ -w "$DATA_DIR" ]]; then
        pass "DATA_DIR: $DATA_DIR (writable)"
    else
        fail "DATA_DIR: $DATA_DIR (not writable)"
    fi
else
    info "DATA_DIR: $DATA_DIR (will be created)"
fi

# Required for artifact publishing
if [[ -n "${PUBLISH_URL:-}" ]]; then
    MASKED_URL=$(echo "$PUBLISH_URL" | sed 's|://[^:]*:[^@]*@|://***:***@|')
    pass "PUBLISH_URL: $MASKED_URL"
else
    fail "PUBLISH_URL: not set"
fi

# Authentication (required if PUBLISH_URL is HTTP/HTTPS)
if [[ -n "${PUBLISH_URL:-}" ]]; then
    case "${PUBLISH_URL:-}" in
        s3://*) ;; # Skip S3 URLs
        *)
            # Check HTTP/HTTPS credentials
            if [[ -n "${PUBLISH_USER:-}" ]] && [[ -n "${PUBLISH_PASSWORD:-}" ]]; then
                pass "Publish credentials: PUBLISH_USER/PASSWORD set"
            elif [[ -n "${PUBLISH_TOKEN:-}" ]]; then
                pass "Publish credentials: PUBLISH_TOKEN set"
            else
                warn "Publish credentials: not set (may be needed)"
            fi
            ;;
    esac
fi

# Git credentials
info ""
info "Git credentials:"

GIT_CREDS_FILE="${HOME:-/root}/.git-credentials"
SSH_DIR="${HOME:-/root}/.ssh"
HAS_GIT_CREDS=false

if [[ -f "$GIT_CREDS_FILE" ]]; then
    CRED_COUNT=$(wc -l < "$GIT_CREDS_FILE" | tr -d ' ')
    pass "HTTPS credentials: $GIT_CREDS_FILE ($CRED_COUNT entries)"
    HAS_GIT_CREDS=true
elif [[ -n "${GIT_CREDENTIALS:-}" ]]; then
    pass "HTTPS credentials: GIT_CREDENTIALS env var set"
    HAS_GIT_CREDS=true
fi

if [[ -d "$SSH_DIR" ]] && { [[ -f "$SSH_DIR/id_rsa" ]] || [[ -f "$SSH_DIR/id_ed25519" ]] || [[ -f "$SSH_DIR/private-key" ]]; }; then
    pass "SSH keys: available in $SSH_DIR"
    HAS_GIT_CREDS=true
elif [[ -n "${GIT_SSH_CREDENTIALS:-}" ]]; then
    pass "SSH keys: GIT_SSH_CREDENTIALS env var set"
    HAS_GIT_CREDS=true
fi

if [[ "$HAS_GIT_CREDS" == false ]]; then
    info "No git credentials configured (may be needed for private repos)"
fi

# Git config summary (safe values only, no credentials)
if check_command git; then
    info ""
    info "Git config:"

    GIT_USER=$(git config --global user.name 2>/dev/null || echo "")
    GIT_EMAIL=$(git config --global user.email 2>/dev/null || echo "")
    GIT_CRED_HELPER=$(git config --global credential.helper 2>/dev/null || echo "")

    if [[ -n "$GIT_USER" ]]; then
        info "  user.name: $GIT_USER"
    fi
    if [[ -n "$GIT_EMAIL" ]]; then
        info "  user.email: $GIT_EMAIL"
    fi
    if [[ -n "$GIT_CRED_HELPER" ]]; then
        # Mask any paths that might contain usernames
        MASKED_HELPER=$(echo "$GIT_CRED_HELPER" | sed 's|/Users/[^/]*/|/Users/***/|g' | sed 's|/home/[^/]*/|/home/***/|g')
        info "  credential.helper: $MASKED_HELPER"
    else
        info "  credential.helper: (not configured)"
    fi
fi
