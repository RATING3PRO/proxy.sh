#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Debian / Ubuntu
# VLESS + REALITY + XHTTP
# ==========================================

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
XRAY_CONF="${XRAY_DIR}/config.json"
XRAY_LOG="/var/log/xray"
SERVICE_FILE="/etc/systemd/system/xray.service"

# ==========================================
# 可按需修改
DEFAULT_PORT=8443
DEFAULT_SNI="www.microsoft.com"
DEFAULT_DEST="www.microsoft.com:443"
DEFAULT_TAG="vless-xhttp"
DEFAULT_PATH="/update"
# ==========================================

# ---------- utils ----------
log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

need_root() {
  [[ $EUID -eq 0 ]] || { err "请使用 root 执行"; exit 1; }
}

read_default() {
  read -rp "$1 (默认: $2): " v
  echo "${v:-$2}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "64" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    armv7*) echo "arm32-v7a" ;;
    *) err "不支持的架构"; exit 1 ;;
  esac
}

# ---------- uninstall ----------
uninstall() {
  log "卸载 Xray"

  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true

  rm -f "$SERVICE_FILE"
  rm -f "$XRAY_BIN"
  rm -rf "$XRAY_DIR" "$XRAY_LOG"

  systemctl daemon-reload
  log "卸载完成"
  exit 0
}

# ---------- install ----------
install_deps() {
  log "安装依赖"
  apt update -y >/dev/null
  apt install -y curl wget unzip jq openssl ca-certificates >/dev/null
}

install_xray() {
  log "安装 Xray"
  local arch api ver asset url tmp

  arch="$(detect_arch)"
  api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
  tmp="$(mktemp -d)"

  # 获取最新版本（确保支持 xhttp）
  ver="$(curl -fsSL "$api" | jq -r .tag_name)"
  log "检测到最新版本: $ver"
  
  asset="Xray-linux-${arch}.zip"
  url="$(curl -fsSL "$api" | jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .browser_download_url')"

  if [[ -z "$url" ]]; then
    err "无法获取下载链接"
    exit 1
  fi

  wget -qO "$tmp/xray.zip" "$url"
  unzip -qo "$tmp/xray.zip" -d "$tmp"

  install -m 755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"

  mkdir -p "$XRAY_DIR" "$XRAY_LOG"
}

gen_keys() {
  log "生成 REALITY x25519 密钥"

  local out
  out="$($XRAY_BIN x25519)"

  PRIV="$(echo "$out" | grep '^PrivateKey:' | cut -d':' -f2 | tr -d '[:space:]')"
  PUB="$(echo "$out"  | grep '^Password:'   | cut -d':' -f2 | tr -d '[:space:]')"

  if [[ -z "$PRIV" || -z "$PUB" ]]; then
    err "REALITY 密钥生成失败"
    echo "$out"
    exit 1
  fi

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
        "flow": ""
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": {
        "dest": "$DEST",
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": ["$SHORTID"]
      },
      "xhttpSettings": {
        "path": "$PATH_VAL",
        "host": "$SNI",
        "mode": "packet-up"
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
}

install_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
ExecStart=$XRAY_BIN run -c $XRAY_CONF
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable xray
  systemctl restart xray
}

print_link() {
  echo
  log "VLESS 连接链接："
  # URL encode path
  local enc_path
  enc_path=$(echo -n "$PATH_VAL" | jq -sRr @uri)
  
  echo "vless://${UUID}@${HOST}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SHORTID}&type=xhttp&mode=packet-up&path=${enc_path}#${TAG}"
  echo
}

# ---------- main ----------
main() {
  need_root
  [[ "${1:-}" == "uninstall" ]] && uninstall

  install_deps
  install_xray

  echo
  PORT="$(read_default "监听端口" "$DEFAULT_PORT")"
  SNI="$(read_default "REALITY SNI" "$DEFAULT_SNI")"
  DEST="$(read_default "REALITY dest" "$DEFAULT_DEST")"
  PATH_VAL="$(read_default "XHTTP Path" "$DEFAULT_PATH")"
  HOST="$(read_default "连接域名/IP" "$(curl -fsSL https://api.ipify.org || echo 127.0.0.1)")"
  TAG="$(read_default "链接备注" "$DEFAULT_TAG")"

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORTID="$(openssl rand -hex 8)"

  gen_keys
  write_config
  install_service
  print_link

  systemctl status xray --no-pager || true
}

main "$@"
