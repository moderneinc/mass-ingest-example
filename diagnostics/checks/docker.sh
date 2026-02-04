#!/bin/bash
# Runtime environment checks: container detection, CPU architecture, emulation

# Source shared functions if run directly
if [[ -z "$SCRIPT_DIR" ]]; then
    source "$(dirname "$0")/../lib/core.sh"
fi

section "Runtime environment"

# Container detection (detect_container from core.sh)
detect_container

if [[ "$IN_CONTAINER" == true ]]; then
    pass "Running inside $CONTAINER_TYPE"
    # Base image detection
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        info "Base image: $PRETTY_NAME"
    fi
else
    info "Running on host (not in container)"
fi

# Architecture
ARCH=$(uname -m)

# Detect emulation (only relevant inside containers)
EMULATED="No"
EMULATION_REASON=""

# Check for QEMU in cpuinfo
if [[ -f /proc/cpuinfo ]]; then
    if grep -qi "QEMU" /proc/cpuinfo 2>/dev/null; then
        EMULATED="Yes"
        EMULATION_REASON="QEMU detected in /proc/cpuinfo"
    fi
fi

# Check for Rosetta (macOS ARM running x86 container)
if [[ "$ARCH" == "x86_64" ]] && [[ -f /proc/cpuinfo ]]; then
    if grep -qi "VirtualApple" /proc/cpuinfo 2>/dev/null; then
        EMULATED="Yes"
        EMULATION_REASON="Rosetta 2 (VirtualApple CPU)"
    fi
    if [[ "$EMULATED" == "No" ]] && command -v sysctl >/dev/null 2>&1; then
        if sysctl -n sysctl.proc_translated 2>/dev/null | grep -q "1"; then
            EMULATED="Yes"
            EMULATION_REASON="Rosetta 2 (sysctl.proc_translated=1)"
        fi
    fi
fi

# Check for binfmt/qemu userspace emulation
if [[ -f /proc/sys/fs/binfmt_misc/status ]]; then
    if ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -qiE "qemu|arm|aarch"; then
        if [[ "$EMULATED" == "No" ]]; then
            EMULATED="Possible"
            EMULATION_REASON="binfmt_misc QEMU handlers registered"
        fi
    fi
fi

# Report architecture results
if [[ "$EMULATED" == "No" ]]; then
    pass "Architecture: $ARCH (no emulation detected)"
elif [[ "$EMULATED" == "Possible" ]] || [[ "$EMULATED" == "Likely" ]]; then
    warn "Architecture: $ARCH - $EMULATION_REASON"
    info "Consider building for linux/arm64 if running on Apple Silicon"
else
    fail "Architecture: $ARCH - $EMULATION_REASON"
    info "Emulation significantly impacts build performance"
    info "Consider building for linux/arm64 if running on Apple Silicon"
fi

# Docker/Podman version (if available)
if check_command docker; then
    DOCKER_VERSION=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$DOCKER_VERSION" ]]; then
        info "Docker CLI: $DOCKER_VERSION"
    fi
elif check_command podman; then
    PODMAN_VERSION=$(podman --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$PODMAN_VERSION" ]]; then
        info "Podman CLI: $PODMAN_VERSION"
    fi
fi
