#!/bin/bash
# repos.csv checks: file exists, parseable, columns, origins, counts
#
# Provides a structured summary of the repos.csv file for diagnostics.
# This helps understand the scale and scope of the ingestion workload.

# Source shared functions if run directly
if [[ -z "$SCRIPT_DIR" ]]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

section "repos.csv"

# Find repos.csv (find_repos_csv from core.sh)
if ! find_repos_csv; then
    warn "repos.csv: not found"
    info "Expected at: /app/repos.csv or current directory"
    info "Will be loaded at runtime from argument or S3/HTTP URL"
    return 0 2>/dev/null || exit 0
fi

# File exists
pass "File: $CSV_FILE"

# Check if readable and not empty
if [[ ! -r "$CSV_FILE" ]]; then
    fail "File: not readable"
    return 0 2>/dev/null || exit 0
fi

LINE_COUNT=$(wc -l < "$CSV_FILE" | tr -d ' ')
if [[ "$LINE_COUNT" -lt 2 ]]; then
    fail "File: empty or only header ($LINE_COUNT lines)"
    return 0 2>/dev/null || exit 0
fi

REPO_COUNT=$((LINE_COUNT - 1))

# Parse header to find column indices (get_col_index from core.sh)
HEADER=$(head -1 "$CSV_FILE")

CLONEURL_COL=$(get_col_index "cloneUrl")
BRANCH_COL=$(get_col_index "branch")
ORIGIN_COL=$(get_col_index "origin")
PATH_COL=$(get_col_index "path")

# Check required columns
MISSING_REQUIRED=""
for col in cloneUrl branch; do
    if [[ -z "$(get_col_index "$col")" ]]; then
        MISSING_REQUIRED="$MISSING_REQUIRED $col"
    fi
done

if [[ -n "$MISSING_REQUIRED" ]]; then
    fail "Missing required columns:$MISSING_REQUIRED"
else
    pass "Required columns: cloneUrl, branch"
fi

# Check optional columns
PRESENT_OPTIONAL=""
MISSING_OPTIONAL=""
for col in origin path; do
    if [[ -n "$(get_col_index "$col")" ]]; then
        PRESENT_OPTIONAL="$PRESENT_OPTIONAL $col"
    else
        MISSING_OPTIONAL="$MISSING_OPTIONAL $col"
    fi
done

if [[ -z "$MISSING_OPTIONAL" ]]; then
    pass "Optional columns: origin, path"
elif [[ -n "$PRESENT_OPTIONAL" ]]; then
    warn "Optional columns:$PRESENT_OPTIONAL present,$MISSING_OPTIONAL missing"
else
    warn "Optional columns: origin, path (missing)"
fi

# Check for potential issues
ISSUES_FOUND=false
if [[ -n "$CLONEURL_COL" ]]; then
    EMPTY_URLS=$(tail -n +2 "$CSV_FILE" | cut -d',' -f"$CLONEURL_COL" | grep -c '^$' 2>/dev/null || echo "0")
    EMPTY_URLS=$(echo "$EMPTY_URLS" | tr -d '[:space:]')
    if [[ -n "$EMPTY_URLS" ]] && [[ "$EMPTY_URLS" -gt 0 ]]; then
        warn "$EMPTY_URLS rows have empty cloneUrl"
        ISSUES_FOUND=true
    fi

    UNIQUE_URLS=$(tail -n +2 "$CSV_FILE" | cut -d',' -f"$CLONEURL_COL" | sort -u | wc -l | tr -d ' ')
    TOTAL_URLS=$(tail -n +2 "$CSV_FILE" | cut -d',' -f"$CLONEURL_COL" | wc -l | tr -d ' ')
    if [[ "$UNIQUE_URLS" -lt "$TOTAL_URLS" ]]; then
        DUPES=$((TOTAL_URLS - UNIQUE_URLS))
        warn "$DUPES duplicate cloneUrl entries"
        ISSUES_FOUND=true
    fi
fi

# Print structured summary
info ""
info "Summary"
info "-----------------------------------------------"
info "  Total repositories:    $(format_number $REPO_COUNT)"

# Count unique origins
if [[ -n "$ORIGIN_COL" ]]; then
    UNIQUE_ORIGINS=$(tail -n +2 "$CSV_FILE" | cut -d',' -f"$ORIGIN_COL" | sort -u | grep -v '^$' | wc -l | tr -d ' ')
    info "  Unique origins:        $UNIQUE_ORIGINS"
    info ""
    info "  Origin breakdown:"

    # Get origin counts, sorted by count descending
    # Format: right-aligned count, then origin name
    tail -n +2 "$CSV_FILE" | cut -d',' -f"$ORIGIN_COL" | sort | uniq -c | sort -rn | while read count origin; do
        if [[ -n "$origin" ]]; then
            printf "       %6d  %s\n" "$count" "$origin"
        else
            printf "       %6d  %s\n" "$count" "(no origin)"
        fi
    done
    info "-----------------------------------------------"
else
    # No origin column - extract hosts from cloneUrl
    if [[ -n "$CLONEURL_COL" ]]; then
        info ""
        info "  SCM hosts (from cloneUrl):"
        tail -n +2 "$CSV_FILE" | cut -d',' -f"$CLONEURL_COL" | sed 's|.*://||' | cut -d/ -f1 | cut -d@ -f2 | sort | uniq -c | sort -rn | head -10 | while read count host; do
            if [[ -n "$host" ]]; then
                printf "       %6d  %s\n" "$count" "$host"
            fi
        done
        info "-----------------------------------------------"
    fi
fi

# Sample entries
info ""
info "Sample entries (first 3):"
if [[ -n "$CLONEURL_COL" ]] && [[ -n "$ORIGIN_COL" ]] && [[ -n "$PATH_COL" ]]; then
    tail -n +2 "$CSV_FILE" | head -3 | while IFS= read -r line; do
        origin=$(echo "$line" | cut -d',' -f"$ORIGIN_COL")
        path=$(echo "$line" | cut -d',' -f"$PATH_COL")
        info "  $origin / $path"
    done
elif [[ -n "$CLONEURL_COL" ]]; then
    tail -n +2 "$CSV_FILE" | head -3 | cut -d',' -f"$CLONEURL_COL" | while read -r url; do
        info "  $url"
    done
fi
