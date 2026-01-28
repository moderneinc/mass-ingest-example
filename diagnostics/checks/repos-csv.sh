#!/bin/bash
# repos.csv checks: file exists, parseable, columns, origins, counts

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../diagnose.sh" --functions-only
fi

section "repos.csv"

# Find repos.csv
CSV_FILE="${REPOS_CSV:-/app/repos.csv}"
if [ ! -f "$CSV_FILE" ]; then
    CSV_FILE="repos.csv"
fi

if [ ! -f "$CSV_FILE" ]; then
    warn "repos.csv: not found"
    info "Expected at: /app/repos.csv or current directory"
    info "Will be loaded at runtime from argument or S3/HTTP URL"
    return 0 2>/dev/null || exit 0
fi

# File exists
pass "File: $CSV_FILE (exists)"

# Check if readable and not empty
if [ ! -r "$CSV_FILE" ]; then
    fail "File: not readable"
    return 0 2>/dev/null || exit 0
fi

LINE_COUNT=$(wc -l < "$CSV_FILE" | tr -d ' ')
if [ "$LINE_COUNT" -lt 2 ]; then
    fail "File: empty or only header ($LINE_COUNT lines)"
    return 0 2>/dev/null || exit 0
fi

REPO_COUNT=$((LINE_COUNT - 1))
pass "Repositories: $REPO_COUNT"

# Parse header to find column indices
HEADER=$(head -1 "$CSV_FILE")
REQUIRED_COLS=("cloneUrl" "branch")
OPTIONAL_COLS=("origin" "path")

# Get column index by name (case-insensitive)
get_col_index() {
    echo "$HEADER" | tr ',' '\n' | grep -ni "^$1$" | cut -d: -f1
}

CLONEURL_COL=$(get_col_index "cloneUrl")
BRANCH_COL=$(get_col_index "branch")
ORIGIN_COL=$(get_col_index "origin")
PATH_COL=$(get_col_index "path")

MISSING_REQUIRED=()
for col in "${REQUIRED_COLS[@]}"; do
    if [ -z "$(get_col_index "$col")" ]; then
        MISSING_REQUIRED+=("$col")
    fi
done

if [ ${#MISSING_REQUIRED[@]} -gt 0 ]; then
    fail "Missing required columns: ${MISSING_REQUIRED[*]}"
else
    pass "Required columns: cloneUrl, branch (present)"
fi

# Check additional columns (expected but may work without)
PRESENT_ADDITIONAL=()
MISSING_ADDITIONAL=()
for col in "${OPTIONAL_COLS[@]}"; do
    if [ -n "$(get_col_index "$col")" ]; then
        PRESENT_ADDITIONAL+=("$col")
    else
        MISSING_ADDITIONAL+=("$col")
    fi
done

if [ ${#MISSING_ADDITIONAL[@]} -eq 0 ]; then
    pass "Additional columns: origin, path (present)"
elif [ ${#PRESENT_ADDITIONAL[@]} -gt 0 ]; then
    warn "Additional columns: ${PRESENT_ADDITIONAL[*]} present, ${MISSING_ADDITIONAL[*]} missing"
else
    warn "Additional columns: origin, path (missing)"
fi

# Count by origin (if column exists)
if [ -n "$ORIGIN_COL" ]; then
    info ""
    info "Repositories by origin:"
    tail -n +2 "$CSV_FILE" | cut -d',' -f"$ORIGIN_COL" | sort | uniq -c | sort -rn | head -10 | while read count origin; do
        info "  $origin: $count repos"
    done
fi

# Sample entries (using dynamic column indices)
info ""
info "Sample entries (first 3):"
if [ -n "$CLONEURL_COL" ] && [ -n "$ORIGIN_COL" ] && [ -n "$PATH_COL" ]; then
    tail -n +2 "$CSV_FILE" | head -3 | while IFS=',' read -ra fields; do
        origin="${fields[$((ORIGIN_COL-1))]}"
        path="${fields[$((PATH_COL-1))]}"
        info "  $origin ($path)"
    done
elif [ -n "$CLONEURL_COL" ]; then
    tail -n +2 "$CSV_FILE" | head -3 | cut -d',' -f"$CLONEURL_COL" | while read -r url; do
        info "  $url"
    done
fi

# Check for potential issues (using dynamic cloneUrl column)
if [ -n "$CLONEURL_COL" ]; then
    EMPTY_URLS=$(tail -n +2 "$CSV_FILE" | cut -d',' -f"$CLONEURL_COL" | grep -c '^$' 2>/dev/null || echo "0")
    EMPTY_URLS=$(echo "$EMPTY_URLS" | tr -d '[:space:]')
    if [ -n "$EMPTY_URLS" ] && [ "$EMPTY_URLS" -gt 0 ]; then
        warn "$EMPTY_URLS rows have empty cloneUrl"
    fi

    # Check for duplicate URLs
    UNIQUE_URLS=$(tail -n +2 "$CSV_FILE" | cut -d',' -f"$CLONEURL_COL" | sort -u | wc -l | tr -d ' ')
    TOTAL_URLS=$(tail -n +2 "$CSV_FILE" | cut -d',' -f"$CLONEURL_COL" | wc -l | tr -d ' ')
    if [ "$UNIQUE_URLS" -lt "$TOTAL_URLS" ]; then
        DUPES=$((TOTAL_URLS - UNIQUE_URLS))
        warn "$DUPES duplicate cloneUrl entries"
    fi
fi
