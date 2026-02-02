#!/bin/bash
# Required tools checks: git, curl, jq, unzip, tar

# Source shared functions if run directly
if [[ -z "$SCRIPT_DIR" ]]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

section "Required tools"

# Check each required tool (space-separated for POSIX compatibility)
REQUIRED_TOOLS="git curl jq unzip tar"
MISSING_TOOLS=""

for tool in $REQUIRED_TOOLS; do
    if check_command "$tool"; then
        VERSION=$($tool --version 2>/dev/null | head -1 || echo "installed")
        # Clean up version string
        case "$tool" in
            git)
                VERSION=$(echo "$VERSION" | sed 's/git version //')
                ;;
            curl)
                VERSION=$(echo "$VERSION" | sed 's/curl //' | cut -d' ' -f1)
                ;;
            jq)
                VERSION=$(echo "$VERSION" | sed 's/jq-//')
                ;;
            unzip)
                VERSION=$($tool -v 2>/dev/null | head -1 | awk '{print $2}' || echo "installed")
                ;;
            tar)
                VERSION=$(echo "$VERSION" | sed 's/(GNU tar) //' | cut -d' ' -f1)
                ;;
        esac
        pass "$tool: $VERSION"
    else
        MISSING_TOOLS="$MISSING_TOOLS $tool"
        fail "$tool: not found"
    fi
done

# Summary for missing tools
if [[ -n "$MISSING_TOOLS" ]]; then
    info ""
    info "Missing tools can be installed with:"
    # Detect package manager
    if check_command apt-get; then
        info "  apt-get install$MISSING_TOOLS"
    elif check_command dnf; then
        info "  dnf install$MISSING_TOOLS"
    elif check_command yum; then
        info "  yum install$MISSING_TOOLS"
    elif check_command apk; then
        info "  apk add$MISSING_TOOLS"
    elif check_command pacman; then
        info "  pacman -S$MISSING_TOOLS"
    elif check_command brew; then
        info "  brew install$MISSING_TOOLS"
    else
        info "  <package-manager> install$MISSING_TOOLS"
    fi
fi
