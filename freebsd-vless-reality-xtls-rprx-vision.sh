#!/usr/bin/env sh
set -eu

# ==========================================
# FreeBSD
# VLESS + REALITY + XTLS-RPRX-Vision
# ==========================================

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONF="${XRAY_DIR}/config.json"
XRAY_LOG="/var/log/xray"
RC_SCRIPT="/usr/local/etc/rc.d/xray"

DEFAULT_PORT=8443
DEFAULT_SNI="www.cloudflare.com"
DEFAULT_DEST="www.cloudflare.com:443"
DEFAULT_TAG="vless-reality"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }

need_root() {
  [ "$(id -u)" -eq 0 ] || { err "请使用 root 执行"; exit 1; }
}

read_default() {
  printf "%s (默认: %s): " "$1" "$2"
  read v
  echo "${v:-$2}"
}

detect_arch() {
  case "$(uname -m)" in
    amd64) echo "64" ;;
    aarch64) echo "arm64-v8a" ;;
    *) err "不支持的架构"; exit 1 ;;
  esac
}

# ---------- uninstall ----------
uninstall() {
  log "卸载 Xray"

  service xray stop 2>/dev/null || true
  rm -f "$RC_SCRIPT"
  rm -f "$XRAY_BIN"
  rm -rf "$XRAY_DIR" "$XRAY_LOG"

  log "卸载完成"
  exit 0
}

# ---------- install ----------
install_deps() {
  log "安装依赖"
  pkg install -y curl wget unzip jq ca_root_nss
}

install_xray() {
  log "安装 Xray"

  arch="$(detect_arch)"
  api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
  tmp="$(mktemp -d)"

  asset="Xray-freebsd-${arch}.zip"
  url="$(curl -fsSL "$api" | jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .browser_download_url')"

  fetch -o "$tmp/xray.zip" "$url"
  unzip -qo "$tmp/xray.zip" -d "$tmp"

  install -m 755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"

  mkdir -p "$XRAY_DIR" "$XRAY_LOG"
}

gen_keys() {
  log "生成 REALITY x25519 密钥"

  out="$($XRAY_BIN x25519)"

  PRIV="$(echo "$out" | grep '^PrivateKey:' | cut -d':' -f2 | tr -d '[:space:]')"
  PUB="$(echo "$out"  | grep '^Password:'   | cut -d':' -f2 | tr -d '[:space:]')"

  [ -n "$PRIV" ] && [ -n "$PUB" ] || {
    err "REALITY 密钥生成失败"
    echo "$out"
    exit 1
  }

  log "REALITY 密钥生成成功"
}

write_config() {
  cat >"$XRAY_CONF" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$XRAY_LOG/access.log",
    "error": "$XRAY_LOG/error.log"
  },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "$UUID",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$DEST",
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": ["$SHORTID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
}

install_service() {
  cat >"$RC_SCRIPT" <<'EOF'
#!/bin/sh
#
# PROVIDE: xray
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="xray"
rcvar="xray_enable"

command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"

load_rc_config $name
: ${xray_enable:=YES}

run_rc_command "$1"
EOF

  chmod +x "$RC_SCRIPT"
  sysrc xray_enable=YES >/dev/null
  service xray restart
}

print_link() {
  echo
  log "VLESS 连接链接："
  echo "vless://${UUID}@${HOST}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SHORTID}&type=tcp&flow=xtls-rprx-vision#${TAG}"
  echo
}

# ---------- main ----------
main() {
  need_root
  [ "${1:-}" = "uninstall" ] && uninstall

  install_deps
  install_xray

  echo
  PORT="$(read_default "监听端口" "$DEFAULT_PORT")"
  SNI="$(read_default "REALITY SNI" "$DEFAULT_SNI")"
  DEST="$(read_default "REALITY dest" "$DEFAULT_DEST")"
  HOST="$(read_default "连接域名/IP" "$(curl -fsSL https://api.ipify.org || echo 127.0.0.1)")"
  TAG="$(read_default "链接备注" "$DEFAULT_TAG")"

  UUID="$(uuidgen)"
  SHORTID="$(openssl rand -hex 8)"

  gen_keys
  write_config
  install_service
  print_link

  service xray status || true
}

main "$@"
