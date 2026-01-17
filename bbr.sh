#!/usr/bin/env bash
# =========================================================
# BBR v1/v2 Management Script
# Supported: Debian / Ubuntu / CentOS / Arch / Alpine / OpenWrt
# Features:
#   - Auto-detect BBR v1/v2 availability
#   - Support OpenWrt (kmod-tcp-bbr installation)
#   - Sysctl configuration management
#   - Safe enable/disable/status check
# =========================================================

set -u

# ========= Configuration =========
SYSCTL_CONF="/etc/sysctl.d/99-bbr.conf"
SYSCTL_FALLBACK="/etc/sysctl.conf"
BACKUP_CONF="/etc/sysctl.d/99-cubic.conf"

# ========= Colors =========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ========= Helper Functions =========
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        fail "Please run as root (sudo)."
    fi
}

get_os_type() {
    if [[ -f /etc/openwrt_release ]]; then
        echo "openwrt"
    elif [[ -f /etc/alpine-release ]]; then
        echo "alpine"
    elif [[ -f /etc/arch-release ]]; then
        echo "arch"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian" # Covers Ubuntu/Debian/Kali
    elif [[ -f /etc/redhat-release ]]; then
        echo "rhel" # Covers CentOS/Fedora/Rocky
    else
        echo "unknown"
    fi
}

check_env() {
    # Ensure sysctl is available
    command -v sysctl >/dev/null 2>&1 || fail "sysctl command not found."
    
    # Check if system is a container (OpenVZ/LXC) where sysctl might be read-only
    if [[ -f /proc/user_beancounters ]]; then
        warn "OpenVZ detected. BBR might not work inside the container unless enabled on host."
    fi
}

get_sysctl_path() {
    if [[ -d /etc/sysctl.d ]]; then
        echo "$SYSCTL_CONF"
    else
        echo "$SYSCTL_FALLBACK"
    fi
}

# ========= Core Logic =========

install_bbr_module() {
    local os_type
    os_type=$(get_os_type)

    if [[ "$os_type" == "openwrt" ]]; then
        log "OpenWrt detected. Checking kmod-tcp-bbr..."
        if ! opkg list-installed | grep -q kmod-tcp-bbr; then
            log "Installing kmod-tcp-bbr and kmod-sched-fq..."
            opkg update >/dev/null 2>&1 || warn "opkg update failed, trying install anyway..."
            opkg install kmod-tcp-bbr kmod-sched-fq >/dev/null 2>&1 || fail "Failed to install kernel modules."
        else
            log "kmod-tcp-bbr is already installed."
        fi
        
        # Try to install BBRv2 if available in feeds (rare but possible)
        if opkg list | grep -q kmod-tcp-bbr2; then
            opkg install kmod-tcp-bbr2 >/dev/null 2>&1 || true
        fi
    elif [[ "$os_type" == "alpine" ]]; then
        # Alpine usually has modules, just need to modprobe
        modprobe tcp_bbr >/dev/null 2>&1 || true
    else
        # Standard Linux (Debian/Arch/RHEL)
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi
}

get_available_algo() {
    local avail
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    echo "$avail"
}

enable_bbr() {
    check_root
    check_env
    install_bbr_module

    local avail_algo
    avail_algo=$(get_available_algo)
    local target_algo=""

    # Prioritize BBRv2 if available
    if echo "$avail_algo" | grep -qw "bbr2"; then
        target_algo="bbr2"
    elif echo "$avail_algo" | grep -qw "bbr"; then
        target_algo="bbr"
    else
        fail "Kernel does not support BBR/BBRv2. (Available: ${avail_algo:-none})"
    fi

    log "Selected Algorithm: ${target_algo}"

    local conf_file
    conf_file=$(get_sysctl_path)
    
    log "Writing configuration to $conf_file"
    
    # If using fallback file, ensure we don't duplicate lines endlessly
    if [[ "$conf_file" == "$SYSCTL_FALLBACK" ]]; then
        sed -i '/net.core.default_qdisc/d' "$conf_file"
        sed -i '/net.ipv4.tcp_congestion_control/d' "$conf_file"
        sed -i '/net.ipv4.tcp_ecn/d' "$conf_file"
        sed -i '/net.ipv4.tcp_fastopen/d' "$conf_file"
    fi

    # Create config content
    cat > "$conf_file" <<EOF
# TCP BBR Configuration
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $target_algo
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3
EOF

    # Clean up cubic fallback if exists
    rm -f "$BACKUP_CONF" 2>/dev/null || true

    log "Applying sysctl settings..."
    sysctl -p "$conf_file" >/dev/null 2>&1 || fail "Failed to apply sysctl settings."

    # Verify
    local current_algo
    current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    
    if [[ "$current_algo" == "$target_algo" ]]; then
        ok "BBR ($target_algo) enabled successfully."
    else
        fail "Failed to enable BBR. Current: $current_algo"
    fi
    
    show_status
}

disable_bbr() {
    check_root
    log "Disabling BBR..."

    local conf_file
    conf_file=$(get_sysctl_path)

    if [[ "$conf_file" == "$SYSCTL_FALLBACK" ]]; then
        sed -i '/net.core.default_qdisc/d' "$conf_file"
        sed -i '/net.ipv4.tcp_congestion_control/d' "$conf_file"
        sed -i '/net.ipv4.tcp_ecn/d' "$conf_file"
        sed -i '/net.ipv4.tcp_fastopen/d' "$conf_file"
    else
        rm -f "$conf_file"
    fi

    # Create cubic fallback
    mkdir -p /etc/sysctl.d
    cat > "$BACKUP_CONF" <<EOF
# TCP Cubic Configuration
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = cubic
EOF

    log "Applying cubic settings..."
    sysctl -p "$BACKUP_CONF" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1

    local current_algo
    current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    if [[ "$current_algo" == "cubic" ]]; then
        ok "Restored to cubic."
    else
        warn "Current algo is $current_algo (expected cubic)."
    fi
    
    show_status
}

show_status() {
    echo
    echo "================ System Status ================"
    echo "OS Type       : $(get_os_type)"
    echo "Kernel        : $(uname -r)"
    echo "Arch          : $(uname -m)"
    echo "-----------------------------------------------"
    echo "Congestion CC : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'unknown')"
    echo "Queue Disc    : $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'unknown')"
    echo "Available CC  : $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo 'unknown')"
    echo "TCP ECN       : $(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo '0')"
    echo "==============================================="
    echo
}

# ========= Main =========
case "${1:-}" in
    enable)
        enable_bbr
        ;;
    disable)
        disable_bbr
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {enable|disable|status}"
        echo "  enable  : Auto-detect and enable BBR or BBRv2"
        echo "  disable : Disable BBR and revert to cubic"
        echo "  status  : Show current TCP status"
        exit 1
        ;;
esac
