#!/bin/bash
# Java/JDK checks

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

section "Java/JDKs"

if ! check_command mod; then
    fail "mod CLI not available"
    return 0 2>/dev/null || exit 0
fi

# Get JDK list from CLI, filtering out the logo/formatting
# Lines with JDKs start with whitespace followed by a version number
JDK_LIST=$(mod config java jdk list 2>&1 | grep -E "^\s+[0-9]" | sed 's/\x1b\[[0-9;]*m//g')

if [ -n "$JDK_LIST" ]; then
    JDK_COUNT=$(echo "$JDK_LIST" | wc -l | tr -d ' ')
    pass "$JDK_COUNT JDK(s) detected:"
    # Show each JDK - columns are: version, source, path (separated by multiple spaces)
    echo "$JDK_LIST" | head -10 | while IFS= read -r line; do
        # Collapse multiple spaces to single, then parse
        CLEANED=$(echo "$line" | sed 's/  */ /g' | sed 's/^ //')
        VERSION=$(echo "$CLEANED" | cut -d' ' -f1)
        # Source is field 2, possibly with field 3 if it's "OS directory" or "User provided"
        SOURCE=$(echo "$CLEANED" | cut -d' ' -f2-3 | sed 's/ *\/.*//')
        info "  $VERSION ($SOURCE)"
    done
    if [ "$JDK_COUNT" -gt 10 ]; then
        info "  ... and $((JDK_COUNT - 10)) more"
    fi
else
    warn "No JDKs detected"
fi
