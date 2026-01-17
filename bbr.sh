#!/usr/bin/env bash
set -euo pipefail

# ========= 基本配置 =========
BBR_CONF="/etc/sysctl.d/99-bbr.conf"
CUBIC_CONF="/etc/sysctl.d/99-cubic.conf"

# ========= 颜色 =========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ========= 输出函数 =========
log() {
  echo -e "${BLUE}[BBR]${NC} $1"
}

ok() {
  echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

fail() {
  echo -e "${RED}[FAIL]${NC} $1"
  exit 1
}

# ========= 基础检查 =========
require_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "请使用 root 运行脚本"
  fi
}

kernel_supports_bbr() {
  local major minor
  major=$(uname -r | cut -d. -f1)
  minor=$(uname -r | cut -d. -f2)

  if [[ $major -gt 4 || ( $major -eq 4 && $minor -ge 9 ) ]]; then
    return 0
  fi
  return 1
}

# ========= 核心逻辑 =========
enable_bbr() {
  require_root
  log "开始启用 TCP BBR"

  kernel_supports_bbr || fail "内核版本 < 4.9，不支持 BBR"

  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    fail "当前内核未启用 BBR（tcp_available_congestion_control 中不存在 bbr）"
  fi

  log "写入 sysctl 配置 $BBR_CONF"
  cat > "$BBR_CONF" <<EOF
# TCP BBR (v1 / v2)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  rm -f "$CUBIC_CONF" || true

  log "应用 sysctl 配置"
  sysctl --system >/dev/null || fail "sysctl 应用失败"

  if sysctl net.ipv4.tcp_congestion_control | grep -qw bbr; then
    ok "TCP BBR 已成功启用"
  else
    fail "BBR 未生效，可能存在 sysctl 冲突"
  fi

  status
}

disable_bbr() {
  require_root
  log "开始卸载 BBR，回退到 cubic"

  rm -f "$BBR_CONF" || true

  cat > "$CUBIC_CONF" <<EOF
# TCP Cubic fallback
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = cubic
EOF

  log "应用 sysctl 配置"
  sysctl --system >/dev/null || fail "sysctl 应用失败"

  if sysctl net.ipv4.tcp_congestion_control | grep -qw cubic; then
    ok "已成功回退到 TCP cubic"
  else
    fail "回退 cubic 失败，请检查系统配置"
  fi

  status
}

status() {
  echo
  echo "================ TCP 拥塞控制状态 ================"
  echo "Kernel        : $(uname -r)"
  echo "Congestion CC : $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo "Default qdisc : $(sysctl -n net.core.default_qdisc)"
  echo -n "BBR module    : "
  if lsmod | grep -q tcp_bbr; then
    echo "loaded"
  else
    echo "builtin / not loaded"
  fi

  if kernel_supports_bbr; then
    echo "BBR version   : $( [[ $(uname -r | cut -d. -f1) -ge 5 ]] && echo 'v2 (kernel-based)' || echo 'v1' )"
  else
    echo "BBR version   : unsupported"
  fi
  echo "=================================================="
  echo
}

# ========= 参数入口 =========
case "${1:-}" in
  enable)
    enable_bbr
    ;;
  disable)
    disable_bbr
    ;;
  status)
    status
    ;;
  *)
    echo "用法: $0 {enable|disable|status}"
    exit 1
    ;;
esac
