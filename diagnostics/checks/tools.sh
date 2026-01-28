#!/bin/bash
# Required tools checks: git, curl, jq, unzip, tar

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../diagnose.sh" --functions-only
fi

section "Required tools"

# Check each required tool
REQUIRED_TOOLS=("git" "curl" "jq" "unzip" "tar")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
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
        MISSING_TOOLS+=("$tool")
        fail "$tool: not found"
    fi
done

# Summary for missing tools
if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    info ""
    info "Missing tools can be installed with:"
    info "  apt-get install ${MISSING_TOOLS[*]}"
fi
