#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Alpine Linux
# VLESS + REALITY + XTLS-RPRX-Vision
# Author: RATING3PRO
# ==========================================

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
XRAY_CONF="${XRAY_DIR}/config.json"
XRAY_LOG="/var/log/xray"
SERVICE_FILE="/etc/init.d/xray"
# ==========================================
# 可按需更改这部分
DEFAULT_PORT=8443
DEFAULT_SNI="www.cloudflare.com"
DEFAULT_DEST="www.cloudflare.com:443"
DEFAULT_TAG="vless-reality"
# ==========================================

# ---------- utils ----------
log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请使用 root 执行："
    echo "sudo bash <(curl -fsSL https://raw.githubusercontent.com/RATING3PRO/proxy.sh/main/alpine-vless-reality-xtls-rprx-vision.sh)"
    exit 1
  fi
}

read_default() {
  local prompt="$1" def="$2" input
  read -rp "$prompt (默认: $def): " input
  echo "${input:-$def}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) echo "64" ;;
    aarch64) echo "arm64-v8a" ;;
    armv7*) echo "arm32-v7a" ;;
    *) err "不支持的架构"; exit 1 ;;
  esac
}

# ---------- uninstall ----------
uninstall() {
  log "正在卸载 Xray / VLESS-REALITY"

  rc-service xray stop 2>/dev/null || true
  rc-update del xray default 2>/dev/null || true

  rm -f "$SERVICE_FILE"
  rm -f "$XRAY_BIN"
  rm -rf "$XRAY_DIR"
  rm -rf "$XRAY_LOG"

  log "卸载完成"
  exit 0
}

# ---------- install ----------
install_deps() {
  log "安装依赖"
  apk update >/dev/null
  apk add --no-cache bash curl wget unzip jq openssl ca-certificates xxd >/dev/null
  update-ca-certificates >/dev/null || true
}

install_xray() {
  log "安装 Xray"
  local arch api ver asset url tmp
  arch="$(detect_arch)"
  api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
  tmp="$(mktemp -d)"

  ver="$(curl -fsSL "$api" | jq -r .tag_name)"
  asset="Xray-linux-${arch}.zip"
  url="$(curl -fsSL "$api" | jq -r --arg a "$asset" '.assets[]|select(.name==$a).browser_download_url')"

  wget -qO "$tmp/xray.zip" "$url"
  unzip -qo "$tmp/xray.zip" -d "$tmp"

  install -m 755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"

  mkdir -p "$XRAY_DIR" "$XRAY_LOG"
}

gen_keys() {
  local out
  out="$($XRAY_BIN x25519)"
  PRIV="$(awk -F': ' '/Private key/ {print $2}' <<<"$out")"
  PUB="$(awk -F': ' '/Public key/ {print $2}' <<<"$out")"
}

write_config() {
  cat >"$XRAY_CONF" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$XRAY_LOG/access.log",
    "error": "$XRAY_LOG/error.log"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
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
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF
}

install_service() {
  cat >"$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
pidfile="/run/xray.pid"
command_background="yes"
depend() { need net; }
EOF

  chmod +x "$SERVICE_FILE"
  rc-update add xray default
  rc-service xray restart || rc-service xray start
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

  if [[ "${1:-}" == "uninstall" ]]; then
    uninstall
  fi

  install_deps
  install_xray

  echo
  PORT="$(read_default "监听端口" "$DEFAULT_PORT")"
  SNI="$(read_default "REALITY SNI" "$DEFAULT_SNI")"
  DEST="$(read_default "REALITY dest" "$DEFAULT_DEST")"
  HOST="$(read_default "连接域名/IP" "$(curl -fsSL https://api.ipify.org || echo 127.0.0.1)")"
  TAG="$(read_default "链接备注" "$DEFAULT_TAG")"

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORTID="$(xxd -p -l 8 /dev/urandom)"

  gen_keys
  write_config
  install_service
  print_link

  log "安装完成，服务状态："
  rc-service xray status || true
}

main "$@"
