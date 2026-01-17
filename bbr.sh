#!/usr/bin/env bash
set -e

CONF_FILE="/etc/sysctl.d/99-bbr.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

msg() {
  echo -e "${GREEN}[BBR]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

err() {
  echo -e "${RED}[ERR]${NC} $1"
  exit 1
}

require_root() {
  [[ $EUID -ne 0 ]] && err "请使用 root 运行"
}

kernel_version_ok() {
  local major minor
  major=$(uname -r | cut -d. -f1)
  minor=$(uname -r | cut -d. -f2)
  [[ $major -gt 4 || ( $major -eq 4 && $minor -ge 9 ) ]]
}

enable_bbr() {
  require_root

  kernel_version_ok || err "内核版本 < 4.9，不支持 BBR"

  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    err "当前内核不支持 BBR（tcp_available_congestion_control 中未发现 bbr）"
  fi

  msg "写入 BBR 配置 -> $CONF_FILE"

  cat > "$CONF_FILE" <<EOF
# TCP BBR (v1 / v2)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  sysctl --system >/dev/null

  msg "BBR 已启用"
  status
}

disable_bbr() {
  require_root

  msg "卸载 BBR，回退到 cubic"

  rm -f "$CONF_FILE"

  cat > /etc/sysctl.d/99-cubic.conf <<EOF
# TCP Cubic fallback
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = cubic
EOF

  sysctl --system >/dev/null

  msg "BBR 已卸载（当前使用 cubic）"
  status
}

status() {
  echo
  echo "========== TCP 拥塞控制状态 =========="
  uname -r
  sysctl net.ipv4.tcp_congestion_control
  sysctl net.core.default_qdisc
  echo -n "BBR 模块: "
  lsmod | grep -q tcp_bbr && echo "loaded" || echo "builtin / not loaded"
  echo "====================================="
}

case "$1" in
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
