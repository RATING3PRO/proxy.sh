#!/bin/sh
set -eu

# ========= 可改默认值 =========
DEFAULT_PORT="8443"
DEFAULT_SNI="www.cloudflare.com"
DEFAULT_DEST="www.cloudflare.com:443"
DEFAULT_TAG="vless-reality"
# ============================

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 运行：sudo -i 之后再执行"
    exit 1
  fi
}

say() { printf "%s\n" "$*"; }

read_with_default() {
  _prompt="$1"
  _default="$2"
  printf "%s (默认: %s): " "$_prompt" "$_default"
  read -r _in || true
  if [ -z "${_in:-}" ]; then
    printf "%s" "$_default"
  else
    printf "%s" "$_in"
  fi
}

install_deps() {
  say "[1/6] 安装依赖..."
  apk update >/dev/null
  apk add --no-cache ca-certificates curl wget unzip openssl xxd jq >/dev/null
  update-ca-certificates >/dev/null || true
}

detect_arch() {
  a="$(uname -m)"
  case "$a" in
    x86_64) echo "64" ;;
    aarch64) echo "arm64-v8a" ;;
    armv7l|armv7*) echo "arm32-v7a" ;;
    *) echo "unknown" ;;
  esac
}

install_xray() {
  say "[2/6] 安装 Xray..."
  arch="$(detect_arch)"
  if [ "$arch" = "unknown" ]; then
    say "不支持的架构: $(uname -m)"
    exit 1
  fi

  # 从 GitHub API 获取最新版本与下载链接（脚本运行时在线获取）
  api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  ver="$(curl -fsSL "$api" | jq -r '.tag_name')"
  [ -n "$ver" ] || { say "获取版本失败"; exit 1; }

  # 资产名类似：Xray-linux-64.zip / Xray-linux-arm64-v8a.zip ...
  asset="Xray-linux-${arch}.zip"
  url="$(curl -fsSL "$api" | jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .browser_download_url' | head -n 1)"
  [ -n "$url" ] || { say "获取下载链接失败：$asset"; exit 1; }

  say "  - 最新版本: $ver"
  say "  - 下载: $asset"

  wget -qO "$tmpdir/xray.zip" "$url"
  unzip -qo "$tmpdir/xray.zip" -d "$tmpdir/xray"

  install -m 0755 "$tmpdir/xray/xray" /usr/local/bin/xray

  mkdir -p /etc/xray
  mkdir -p /var/log/xray
  chmod 755 /etc/xray /var/log/xray
}

gen_reality_keys() {
  # 使用 xray 自带 x25519 生成密钥对（输出两行：Private key / Public key）
  out="$(/usr/local/bin/xray x25519)"
  priv="$(printf "%s\n" "$out" | awk -F': ' '/Private key/ {print $2}')"
  pub="$(printf "%s\n" "$out" | awk -F': ' '/Public key/ {print $2}')"
  [ -n "$priv" ] && [ -n "$pub" ] || { say "生成 REALITY 密钥失败"; exit 1; }
  echo "$priv|$pub"
}

write_config() {
  say "[3/6] 写入配置..."
  PORT="$1"
  UUID="$2"
  PRIV="$3"
  SNI="$4"
  DEST="$5"
  SHORTID="$6"

  cat > /etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "tag": "in-vless-reality",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIV}",
          "shortIds": ["${SHORTID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http","tls"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

  chmod 600 /etc/xray/config.json
}

setup_openrc() {
  say "[4/6] 配置 OpenRC 服务..."
  cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

name="xray"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
output_log="/var/log/xray/output.log"
error_log="/var/log/xray/error.log"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath --directory --mode 0755 /var/log/xray
  checkpath --file --mode 0644 /var/log/xray/output.log
}
EOF
  chmod +x /etc/init.d/xray

  rc-update add xray default >/dev/null 2>&1 || true
  rc-service xray restart || rc-service xray start
}

print_link() {
  say "[5/6] 生成 vless:// 链接..."
  HOST="$1"
  PORT="$2"
  UUID="$3"
  SNI="$4"
  PUB="$5"
  SHORTID="$6"
  TAG="$7"

  # 常用客户端参数：fp=chrome、type=tcp、security=reality、sni、pbk、sid、flow
  LINK="vless://${UUID}@${HOST}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SHORTID}&type=tcp&flow=xtls-rprx-vision#${TAG}"
  say ""
  say "==================== 安装完成 ===================="
  say "VLESS-REALITY-链接："
  say "$LINK"
  say "=================================================="
  say ""
  say "配置文件: /etc/xray/config.json"
  say "日志目录: /var/log/xray/"
  say "服务控制: rc-service xray {start|stop|restart|status}"
}

main() {
  need_root
  install_deps
  install_xray

  say "[输入参数]"
  PORT="$(read_with_default "监听端口" "$DEFAULT_PORT")"
  SNI="$(read_with_default "REALITY SNI (伪装域名)" "$DEFAULT_SNI")"
  DEST="$(read_with_default "REALITY dest (通常与SNI一致)" "$DEFAULT_DEST")"
  HOST="$(read_with_default "客户端连接用的域名或服务器IP" "$(wget -qO- https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")")"
  TAG="$(read_with_default "链接备注名称" "$DEFAULT_TAG")"

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORTID="$(xxd -p -l 8 /dev/urandom | tr -d '\n')"  # 8字节 -> 16hex
  kp="$(gen_reality_keys)"
  PRIV="$(printf "%s" "$kp" | cut -d'|' -f1)"
  PUB="$(printf "%s" "$kp" | cut -d'|' -f2)"

  write_config "$PORT" "$UUID" "$PRIV" "$SNI" "$DEST" "$SHORTID"
  setup_openrc

  say "[6/6] 输出信息..."
  print_link "$HOST" "$PORT" "$UUID" "$SNI" "$PUB" "$SHORTID" "$TAG"

  say "小提示：如果你服务器有防火墙/安全组，记得放行端口 ${PORT}/tcp。"
}

main "$@"
