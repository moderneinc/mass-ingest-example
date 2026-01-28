#!/bin/bash
# System checks: CPU, memory, disk space

# Source shared functions if run directly
if [ -z "$SCRIPT_DIR" ]; then
    source "$(dirname "$0")/../diagnose.sh" --functions-only
fi

section "System"

# CPU count
if [ -f /proc/cpuinfo ]; then
    CPU_COUNT=$(grep -c ^processor /proc/cpuinfo)
elif check_command nproc; then
    CPU_COUNT=$(nproc)
elif check_command sysctl; then
    CPU_COUNT=$(sysctl -n hw.ncpu 2>/dev/null || echo "0")
else
    CPU_COUNT="0"
fi

if [ "$CPU_COUNT" -gt 0 ] 2>/dev/null; then
    if [ "$CPU_COUNT" -lt 2 ]; then
        fail "CPUs: $CPU_COUNT (minimum 2 required)"
    else
        pass "CPUs: $CPU_COUNT"
    fi
fi

# Memory: total and available
if [ -f /proc/meminfo ]; then
    MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    if [ -n "$MEM_TOTAL_KB" ] && [ -n "$MEM_AVAIL_KB" ]; then
        MEM_TOTAL=$((MEM_TOTAL_KB * 1024))
        MEM_AVAIL=$((MEM_AVAIL_KB * 1024))
        MEM_TOTAL_HR=$(format_bytes "$MEM_TOTAL")
        MEM_AVAIL_HR=$(format_bytes "$MEM_AVAIL")

        if [ "$MEM_TOTAL" -lt 17179869184 ]; then  # 16GB
            warn "Memory: $MEM_AVAIL_HR / $MEM_TOTAL_HR available (recommend 16GB+)"
        elif [ "$MEM_AVAIL" -lt 8589934592 ]; then  # 8GB available
            warn "Memory: $MEM_AVAIL_HR / $MEM_TOTAL_HR available (low)"
        else
            pass "Memory: $MEM_AVAIL_HR / $MEM_TOTAL_HR available"
        fi
    fi
elif check_command sysctl; then
    # macOS - get memory info via sysctl and vm_stat
    MEM_TOTAL=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
    if [ "$MEM_TOTAL" -gt 0 ] 2>/dev/null; then
        MEM_TOTAL_HR=$(format_bytes "$MEM_TOTAL")

        # Try to get available memory from vm_stat
        MEM_AVAIL=""
        if check_command vm_stat; then
            # vm_stat outputs pages, page size is typically 4096 or 16384
            PAGE_SIZE=$(vm_stat 2>/dev/null | grep "page size" | grep -oE '[0-9]+' || echo "4096")
            FREE_PAGES=$(vm_stat 2>/dev/null | grep "Pages free" | grep -oE '[0-9]+' || echo "0")
            INACTIVE_PAGES=$(vm_stat 2>/dev/null | grep "Pages inactive" | grep -oE '[0-9]+' || echo "0")
            PURGEABLE_PAGES=$(vm_stat 2>/dev/null | grep "Pages purgeable" | grep -oE '[0-9]+' || echo "0")
            # Available = free + inactive + purgeable (approximation)
            AVAIL_PAGES=$((FREE_PAGES + INACTIVE_PAGES + PURGEABLE_PAGES))
            MEM_AVAIL=$((AVAIL_PAGES * PAGE_SIZE))
        fi

        if [ -n "$MEM_AVAIL" ] && [ "$MEM_AVAIL" -gt 0 ] 2>/dev/null; then
            MEM_AVAIL_HR=$(format_bytes "$MEM_AVAIL")
            if [ "$MEM_TOTAL" -lt 17179869184 ]; then  # 16GB total
                warn "Memory: $MEM_AVAIL_HR / $MEM_TOTAL_HR available (recommend 16GB+)"
            elif [ "$MEM_AVAIL" -lt 8589934592 ]; then  # 8GB available
                warn "Memory: $MEM_AVAIL_HR / $MEM_TOTAL_HR available (low)"
            else
                pass "Memory: $MEM_AVAIL_HR / $MEM_TOTAL_HR available"
            fi
        else
            # Fallback if vm_stat unavailable
            if [ "$MEM_TOTAL" -lt 17179869184 ]; then  # 16GB
                warn "Memory: $MEM_TOTAL_HR (recommend 16GB+)"
            else
                pass "Memory: $MEM_TOTAL_HR"
            fi
        fi
    fi
fi

# Helper function to show disk space for a directory
show_disk_space() {
    local dir="$1"
    local label="$2"

    if [ ! -d "$dir" ]; then
        return 1
    fi

    if check_command df; then
        local df_output DISK_TOTAL DISK_USED DISK_FREE
        if df -B1 "$dir" >/dev/null 2>&1; then
            # Linux with -B1 support
            df_output=$(df -B1 "$dir" 2>/dev/null | tail -1)
            DISK_TOTAL=$(echo "$df_output" | awk '{print $2}')
            DISK_USED=$(echo "$df_output" | awk '{print $3}')
            DISK_FREE=$(echo "$df_output" | awk '{print $4}')
        else
            # macOS - df outputs 512-byte blocks by default
            df_output=$(df "$dir" 2>/dev/null | tail -1)
            DISK_TOTAL=$(($(echo "$df_output" | awk '{print $2}') * 512))
            DISK_USED=$(($(echo "$df_output" | awk '{print $3}') * 512))
            DISK_FREE=$(($(echo "$df_output" | awk '{print $4}') * 512))
        fi

        if [ -n "$DISK_FREE" ] && [ "$DISK_FREE" -gt 0 ]; then
            DISK_TOTAL_HR=$(format_bytes "$DISK_TOTAL")
            DISK_FREE_HR=$(format_bytes "$DISK_FREE")

            if [ "$DISK_FREE" -lt 10737418240 ]; then  # 10GB
                warn "$label: $DISK_FREE_HR / $DISK_TOTAL_HR available (low)"
            else
                pass "$label: $DISK_FREE_HR / $DISK_TOTAL_HR available"
            fi
            return 0
        fi
    fi
    return 1
}

# Data directory disk space
DATA_DIR="${DATA_DIR:-/var/moderne}"
if [ -d "$DATA_DIR" ]; then
    show_disk_space "$DATA_DIR" "Disk (data)"
else
    # Show disk space for parent directory that exists
    PARENT_DIR=$(dirname "$DATA_DIR")
    while [ ! -d "$PARENT_DIR" ] && [ "$PARENT_DIR" != "/" ]; do
        PARENT_DIR=$(dirname "$PARENT_DIR")
    done
    if [ -d "$PARENT_DIR" ]; then
        show_disk_space "$PARENT_DIR" "Disk ($PARENT_DIR)"
    fi
fi

# Working directory disk space (if on different filesystem)
WORK_DIR=$(pwd)
if [ "$WORK_DIR" != "$DATA_DIR" ]; then
    DATA_FS=$(df "$DATA_DIR" 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
    WORK_FS=$(df "$WORK_DIR" 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
    if [ "$DATA_FS" != "$WORK_FS" ] || [ -z "$DATA_FS" ]; then
        show_disk_space "$WORK_DIR" "Disk (workdir)"
    fi
fi
