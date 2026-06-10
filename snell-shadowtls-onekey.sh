#!/usr/bin/env sh
set -eu

# ============================================================
# Snell + ShadowTLS V3 一键安装脚本
# 支持：Debian / Ubuntu / Alpine
# 架构：amd64 / x86_64, arm64 / aarch64, armv7l
#
# 用法：
#   sh snell-shadowtls-onekey.sh install
#   PUBLIC_PORT=8443 TLS_DOMAIN=www.microsoft.com sh snell-shadowtls-onekey.sh install
#   sh snell-shadowtls-onekey.sh qr
#   sh snell-shadowtls-onekey.sh status
#   sh snell-shadowtls-onekey.sh logs
#   sh snell-shadowtls-onekey.sh uninstall
# ============================================================

SCRIPT_NAME="snell-shadowtls-onekey"

# 记录用户本次通过环境变量传入的参数。
# 这样重复安装时可以读取旧配置，同时允许 PUBLIC_PORT=8443 这类新参数覆盖旧配置。
USER_SNELL_VERSION="${SNELL_VERSION:-}"
USER_SHADOWTLS_VERSION="${SHADOWTLS_VERSION:-}"
USER_PUBLIC_PORT="${PUBLIC_PORT:-}"
USER_BACKEND_PORT="${BACKEND_PORT:-}"
USER_TLS_DOMAIN="${TLS_DOMAIN:-}"
USER_LISTEN_ADDR="${LISTEN_ADDR:-}"
USER_IPV6_OUT="${IPV6_OUT:-}"
USER_SNELL_PSK="${SNELL_PSK:-}"
USER_STLS_PASSWORD="${STLS_PASSWORD:-}"

SNELL_VERSION="${SNELL_VERSION:-5.0.1}"
SHADOWTLS_VERSION="${SHADOWTLS_VERSION:-latest}"

PUBLIC_PORT="${PUBLIC_PORT:-443}"
BACKEND_PORT="${BACKEND_PORT:-28111}"
TLS_DOMAIN="${TLS_DOMAIN:-www.microsoft.com}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
IPV6_OUT="${IPV6_OUT:-false}"

INSTALL_DIR="/usr/local/bin"
BASE_DIR="/etc/snell-shadowtls"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
ENV_FILE="${BASE_DIR}/env"
INFO_FILE="${BASE_DIR}/info.txt"
LINK_FILE="${BASE_DIR}/node-line.txt"
CLIENT_CONF_FILE="${BASE_DIR}/shadowrocket-surge.conf"
QRCODE_TXT="${BASE_DIR}/qrcode.txt"
QRCODE_PNG="${BASE_DIR}/qrcode.png"

SNELL_BIN="${INSTALL_DIR}/snell-server"
SHADOWTLS_BIN="${INSTALL_DIR}/shadow-tls"

OS_FAMILY=""
INIT_SYSTEM=""
SNELL_ARCH=""
SHADOWTLS_ASSET=""
SHADOWTLS_TAG=""
SNELL_PSK="${SNELL_PSK:-}"
STLS_PASSWORD="${STLS_PASSWORD:-}"

log() { printf '\033[32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$1"; }
err() { printf '\033[31m[ERROR]\033[0m %s\n' "$1"; }

need_root() {
  if [ "$(id -u)" != "0" ]; then
    err "请用 root 权限运行，例如：sudo sh ${SCRIPT_NAME}.sh install"
    exit 1
  fi
}

load_env_if_exists() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  fi

  # 用户本次显式传入的环境变量优先级最高。
  [ -n "$USER_SNELL_VERSION" ] && SNELL_VERSION="$USER_SNELL_VERSION"
  [ -n "$USER_SHADOWTLS_VERSION" ] && SHADOWTLS_VERSION="$USER_SHADOWTLS_VERSION"
  [ -n "$USER_PUBLIC_PORT" ] && PUBLIC_PORT="$USER_PUBLIC_PORT"
  [ -n "$USER_BACKEND_PORT" ] && BACKEND_PORT="$USER_BACKEND_PORT"
  [ -n "$USER_TLS_DOMAIN" ] && TLS_DOMAIN="$USER_TLS_DOMAIN"
  [ -n "$USER_LISTEN_ADDR" ] && LISTEN_ADDR="$USER_LISTEN_ADDR"
  [ -n "$USER_IPV6_OUT" ] && IPV6_OUT="$USER_IPV6_OUT"
  [ -n "$USER_SNELL_PSK" ] && SNELL_PSK="$USER_SNELL_PSK"
  [ -n "$USER_STLS_PASSWORD" ] && STLS_PASSWORD="$USER_STLS_PASSWORD"
}

detect_os() {
  if [ ! -f /etc/os-release ]; then
    err "无法识别系统：缺少 /etc/os-release"
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"

  case "$OS_ID $OS_LIKE" in
    *debian*|*ubuntu*) OS_FAMILY="debian" ;;
    *alpine*) OS_FAMILY="alpine" ;;
    *)
      err "暂不支持当前系统：${PRETTY_NAME:-unknown}"
      err "当前脚本支持 Debian / Ubuntu / Alpine"
      exit 1
      ;;
  esac
}

detect_init() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    INIT_SYSTEM="systemd"
  elif command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ]; then
    INIT_SYSTEM="openrc"
  else
    err "未检测到 systemd 或 OpenRC，无法创建自启动服务"
    exit 1
  fi
}

install_deps() {
  log "安装依赖包..."

  if [ "$OS_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl wget unzip openssl ca-certificates procps iproute2 qrencode
  elif [ "$OS_FAMILY" = "alpine" ]; then
    apk update
    apk add --no-cache curl wget unzip openssl ca-certificates openrc iproute2 procps qrencode
  fi

  update-ca-certificates >/dev/null 2>&1 || true
}

detect_arch() {
  ARCH_RAW="$(uname -m)"

  case "$ARCH_RAW" in
    x86_64|amd64)
      SNELL_ARCH="amd64"
      SHADOWTLS_ASSET="shadow-tls-x86_64-unknown-linux-musl"
      ;;
    aarch64|arm64)
      SNELL_ARCH="aarch64"
      SHADOWTLS_ASSET="shadow-tls-aarch64-unknown-linux-musl"
      ;;
    armv7l|armv7*)
      SNELL_ARCH="armv7l"
      SHADOWTLS_ASSET="shadow-tls-armv7-unknown-linux-musleabihf"
      ;;
    i386|i686)
      err "不建议使用 32 位 x86：Snell 有 i386 包，但 ShadowTLS 常用 release 不提供 i386 Linux 二进制。"
      exit 1
      ;;
    *)
      err "不支持的架构：${ARCH_RAW}。建议使用 amd64 或 arm64 VPS。"
      exit 1
      ;;
  esac
}

random_hex() {
  openssl rand -hex "$1"
}

download_file() {
  URL="$1"
  OUT="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 --max-time 180 -o "$OUT" "$URL"
  else
    wget -O "$OUT" "$URL"
  fi
}

stop_existing_services() {
  detect_init

  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl stop shadowtls >/dev/null 2>&1 || true
    systemctl stop snell >/dev/null 2>&1 || true
  else
    rc-service shadowtls stop >/dev/null 2>&1 || true
    rc-service snell stop >/dev/null 2>&1 || true
  fi
}

port_in_use() {
  PORT="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\\])${PORT}$"
  else
    return 1
  fi
}

check_ports() {
  if port_in_use "$PUBLIC_PORT"; then
    err "公网端口 ${PUBLIC_PORT}/tcp 已被占用。"
    err "请换端口，例如：PUBLIC_PORT=8443 sh ${SCRIPT_NAME}.sh install"
    exit 1
  fi

  if port_in_use "$BACKEND_PORT"; then
    err "本机后端端口 ${BACKEND_PORT}/tcp 已被占用。"
    err "请换端口，例如：BACKEND_PORT=28112 sh ${SCRIPT_NAME}.sh install"
    exit 1
  fi
}

install_snell() {
  log "下载并安装 Snell Server v${SNELL_VERSION}..."

  TMP_DIR="$(mktemp -d)"
  SNELL_URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${SNELL_ARCH}.zip"

  download_file "$SNELL_URL" "${TMP_DIR}/snell.zip"
  unzip -o "${TMP_DIR}/snell.zip" -d "$TMP_DIR" >/dev/null

  if [ ! -f "${TMP_DIR}/snell-server" ]; then
    err "Snell 解压后未找到 snell-server"
    rm -rf "$TMP_DIR"
    exit 1
  fi

  install -m 755 "${TMP_DIR}/snell-server" "$SNELL_BIN"
  rm -rf "$TMP_DIR"

  log "Snell Server 安装完成：${SNELL_BIN}"
}

get_shadowtls_latest_tag() {
  TAG=""

  if command -v curl >/dev/null 2>&1; then
    TAG="$(curl -fsSL --connect-timeout 20 --max-time 60 https://api.github.com/repos/ihciah/shadow-tls/releases/latest 2>/dev/null \
      | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1 || true)"
  fi

  if [ -z "$TAG" ]; then
    warn "无法从 GitHub API 获取 ShadowTLS 最新版本，回退到 v0.2.25"
    TAG="v0.2.25"
  fi

  printf "%s" "$TAG"
}

install_shadowtls() {
  if [ "$SHADOWTLS_VERSION" = "latest" ]; then
    SHADOWTLS_TAG="$(get_shadowtls_latest_tag)"
  else
    SHADOWTLS_TAG="$SHADOWTLS_VERSION"
  fi

  log "下载并安装 ShadowTLS ${SHADOWTLS_TAG}..."

  TMP_DIR="$(mktemp -d)"
  SHADOWTLS_URL="https://github.com/ihciah/shadow-tls/releases/download/${SHADOWTLS_TAG}/${SHADOWTLS_ASSET}"

  download_file "$SHADOWTLS_URL" "${TMP_DIR}/shadow-tls"
  install -m 755 "${TMP_DIR}/shadow-tls" "$SHADOWTLS_BIN"
  rm -rf "$TMP_DIR"

  log "ShadowTLS 安装完成：${SHADOWTLS_BIN}"
}

write_snell_config() {
  mkdir -p "$SNELL_CONF_DIR" "$BASE_DIR"

  if [ -z "${SNELL_PSK:-}" ]; then
    SNELL_PSK="$(random_hex 24)"
  fi

  cat > "$SNELL_CONF_FILE" <<EOF2
[snell-server]
listen = 127.0.0.1:${BACKEND_PORT}
psk = ${SNELL_PSK}
ipv6 = ${IPV6_OUT}
EOF2

  chmod 600 "$SNELL_CONF_FILE"
  log "Snell 配置已写入：${SNELL_CONF_FILE}"
}

write_env_file() {
  mkdir -p "$BASE_DIR"

  if [ -z "${STLS_PASSWORD:-}" ]; then
    STLS_PASSWORD="$(random_hex 24)"
  fi

  cat > "$ENV_FILE" <<EOF2
SNELL_VERSION='${SNELL_VERSION}'
SHADOWTLS_TAG='${SHADOWTLS_TAG}'
PUBLIC_PORT='${PUBLIC_PORT}'
BACKEND_PORT='${BACKEND_PORT}'
TLS_DOMAIN='${TLS_DOMAIN}'
LISTEN_ADDR='${LISTEN_ADDR}'
IPV6_OUT='${IPV6_OUT}'
SNELL_PSK='${SNELL_PSK}'
STLS_PASSWORD='${STLS_PASSWORD}'
EOF2

  chmod 600 "$ENV_FILE"
}

format_listen_addr() {
  ADDR="$1"
  PORT="$2"

  case "$ADDR" in
    *:*) printf "[%s]:%s" "$ADDR" "$PORT" ;;
    *) printf "%s:%s" "$ADDR" "$PORT" ;;
  esac
}

write_systemd_services() {
  LISTEN_SOCKET="$(format_listen_addr "$LISTEN_ADDR" "$PUBLIC_PORT")"

  cat > /etc/systemd/system/snell.service <<EOF2
[Unit]
Description=Snell Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SNELL_BIN} -c ${SNELL_CONF_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2

  cat > /etc/systemd/system/shadowtls.service <<EOF2
[Unit]
Description=ShadowTLS V3 for Snell
After=network-online.target snell.service
Wants=network-online.target
Requires=snell.service

[Service]
Type=simple
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStart=${SHADOWTLS_BIN} --v3 server --listen ${LISTEN_SOCKET} --server 127.0.0.1:${BACKEND_PORT} --tls ${TLS_DOMAIN} --password ${STLS_PASSWORD}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable snell shadowtls >/dev/null
  systemctl restart snell
  systemctl restart shadowtls

  log "systemd 服务已创建并启动"
}

write_openrc_services() {
  LISTEN_SOCKET="$(format_listen_addr "$LISTEN_ADDR" "$PUBLIC_PORT")"

  cat > /etc/init.d/snell <<EOF2
#!/sbin/openrc-run

name="Snell Server"
description="Snell Server"
command="${SNELL_BIN}"
command_args="-c ${SNELL_CONF_FILE}"
command_background=true
pidfile="/run/snell.pid"

start_pre() {
  checkpath --directory --mode 0755 /run
}

depend() {
  need net
}
EOF2

  cat > /etc/init.d/shadowtls <<EOF2
#!/sbin/openrc-run

name="ShadowTLS V3 for Snell"
description="ShadowTLS V3 for Snell"
command="${SHADOWTLS_BIN}"
command_args="--v3 server --listen ${LISTEN_SOCKET} --server 127.0.0.1:${BACKEND_PORT} --tls ${TLS_DOMAIN} --password ${STLS_PASSWORD}"
command_background=true
pidfile="/run/shadowtls.pid"

export MONOIO_FORCE_LEGACY_DRIVER=1

start_pre() {
  checkpath --directory --mode 0755 /run
}

depend() {
  need net
  after snell
}
EOF2

  chmod +x /etc/init.d/snell /etc/init.d/shadowtls

  rc-update add snell default >/dev/null 2>&1 || true
  rc-update add shadowtls default >/dev/null 2>&1 || true

  rc-service snell restart
  rc-service shadowtls restart

  log "OpenRC 服务已创建并启动"
}

open_firewall_hint() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      ufw allow "${PUBLIC_PORT}/tcp" >/dev/null 2>&1 || true
      log "已尝试放行 UFW：${PUBLIC_PORT}/tcp"
    fi
  fi

  warn "如果 VPS 面板或云厂商有安全组，请手动放行 TCP ${PUBLIC_PORT}"
}

get_server_ip() {
  IP=""

  if command -v curl >/dev/null 2>&1; then
    IP="$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi

  if [ -z "$IP" ] && command -v curl >/dev/null 2>&1; then
    IP="$(curl -fsS6 --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
  fi

  if [ -z "$IP" ]; then
    IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  if [ -z "$IP" ]; then
    IP="你的服务器IP"
  fi

  printf "%s" "$IP"
}

format_client_host() {
  HOST="$1"
  case "$HOST" in
    *:*) printf "[%s]" "$HOST" ;;
    *) printf "%s" "$HOST" ;;
  esac
}

generate_client_files() {
  SERVER_IP="$1"
  CLIENT_HOST="$(format_client_host "$SERVER_IP")"

  PROXY_LINE="STLS-SNELL = snell, ${CLIENT_HOST}, ${PUBLIC_PORT}, psk=${SNELL_PSK}, version=4, reuse=true, shadow-tls-password=${STLS_PASSWORD}, shadow-tls-sni=${TLS_DOMAIN}, shadow-tls-version=3"

  cat > "$LINK_FILE" <<EOF2
${PROXY_LINE}
EOF2

  cat > "$CLIENT_CONF_FILE" <<EOF2
[General]
loglevel = notify

[Proxy]
${PROXY_LINE}

[Proxy Group]
Proxy = select, STLS-SNELL, DIRECT

[Rule]
FINAL,Proxy
EOF2

  chmod 600 "$LINK_FILE" "$CLIENT_CONF_FILE"

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o "$QRCODE_PNG" -s 8 -m 2 "$PROXY_LINE"
    qrencode -t ANSIUTF8 "$PROXY_LINE" > "$QRCODE_TXT"
    chmod 600 "$QRCODE_PNG" "$QRCODE_TXT"
  else
    warn "未检测到 qrencode，跳过二维码生成"
  fi
}

save_and_show_info() {
  SERVER_IP="$(get_server_ip)"
  generate_client_files "$SERVER_IP"

  cat > "$INFO_FILE" <<EOF2
===== Snell + ShadowTLS V3 配置信息 =====

服务器地址：${SERVER_IP}
公网监听：${LISTEN_ADDR}:${PUBLIC_PORT}
ShadowTLS 版本：3
ShadowTLS 密码：${STLS_PASSWORD}
ShadowTLS SNI：${TLS_DOMAIN}

Snell 后端地址：127.0.0.1
Snell 后端端口：${BACKEND_PORT}
Snell PSK：${SNELL_PSK}
建议客户端 Snell 版本：4
Snell 服务端版本：${SNELL_VERSION}
ShadowTLS 服务端版本：${SHADOWTLS_TAG}

===== Shadowrocket / Surge 配置行 =====

$(cat "$LINK_FILE")

===== 文件位置 =====

节点配置行：
  ${LINK_FILE}

Shadowrocket / Surge 配置片段：
  ${CLIENT_CONF_FILE}

终端二维码：
  ${QRCODE_TXT}

二维码图片：
  ${QRCODE_PNG}

信息文件：
  ${INFO_FILE}

===== 常用命令 =====

查看二维码：
  sh ${SCRIPT_NAME}.sh qr

查看状态：
  sh ${SCRIPT_NAME}.sh status

查看日志：
  sh ${SCRIPT_NAME}.sh logs

卸载：
  sh ${SCRIPT_NAME}.sh uninstall

===== 客户端手动填写参考 =====

类型：Snell
地址：${SERVER_IP}
端口：${PUBLIC_PORT}
PSK：${SNELL_PSK}
Snell 版本：4
ShadowTLS：开启
ShadowTLS 版本：3
ShadowTLS 密码：${STLS_PASSWORD}
SNI / Host：${TLS_DOMAIN}
EOF2

  chmod 600 "$INFO_FILE"

  printf "\n"
  cat "$INFO_FILE"
  printf "\n"

  if [ -f "$QRCODE_TXT" ]; then
    printf "\n===== 扫描下面二维码添加节点 =====\n\n"
    cat "$QRCODE_TXT"
    printf "\n"
  fi
}

install_all() {
  need_root
  detect_os
  detect_arch
  detect_init
  load_env_if_exists
  install_deps
  stop_existing_services
  check_ports
  install_snell
  install_shadowtls
  write_snell_config
  write_env_file

  if [ "$INIT_SYSTEM" = "systemd" ]; then
    write_systemd_services
  else
    write_openrc_services
  fi

  open_firewall_hint
  save_and_show_info
}

status_all() {
  need_root
  detect_os
  detect_init
  load_env_if_exists

  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl status snell --no-pager || true
    systemctl status shadowtls --no-pager || true
  else
    rc-service snell status || true
    rc-service shadowtls status || true
  fi

  if [ -f "$INFO_FILE" ]; then
    printf "\n"
    cat "$INFO_FILE"
  else
    warn "未找到信息文件：${INFO_FILE}"
  fi
}

show_logs() {
  need_root
  detect_os
  detect_init

  if [ "$INIT_SYSTEM" = "systemd" ]; then
    journalctl -u snell -u shadowtls -n 100 --no-pager || true
    printf "\n实时日志命令：journalctl -u snell -u shadowtls -f\n"
  else
    warn "OpenRC 下日志位置取决于系统 syslog 配置。先显示服务状态："
    rc-service snell status || true
    rc-service shadowtls status || true
  fi
}

restart_all() {
  need_root
  detect_os
  detect_init

  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl restart snell shadowtls
  else
    rc-service snell restart
    rc-service shadowtls restart
  fi

  log "服务已重启"
}

show_qr() {
  need_root
  load_env_if_exists

  if [ -f "$QRCODE_TXT" ]; then
    cat "$QRCODE_TXT"
  else
    warn "二维码文件不存在，尝试重新生成..."
    if [ -z "${SNELL_PSK:-}" ] || [ -z "${STLS_PASSWORD:-}" ]; then
      err "缺少配置参数，请先执行 install"
      exit 1
    fi
    mkdir -p "$BASE_DIR"
    SERVER_IP="$(get_server_ip)"
    generate_client_files "$SERVER_IP"
    cat "$QRCODE_TXT"
  fi

  if [ -f "$LINK_FILE" ]; then
    printf "\n===== 节点配置行 =====\n"
    cat "$LINK_FILE"
    printf "\n"
  fi

  if [ -f "$QRCODE_PNG" ]; then
    printf "\n二维码图片：%s\n" "$QRCODE_PNG"
  fi
}

show_info() {
  need_root
  if [ -f "$INFO_FILE" ]; then
    cat "$INFO_FILE"
  else
    err "信息文件不存在，请先执行 install"
    exit 1
  fi
}

uninstall_all() {
  need_root
  detect_os
  detect_init

  warn "开始卸载 Snell + ShadowTLS..."

  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl stop shadowtls snell >/dev/null 2>&1 || true
    systemctl disable shadowtls snell >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/shadowtls.service
    rm -f /etc/systemd/system/snell.service
    systemctl daemon-reload || true
  else
    rc-service shadowtls stop >/dev/null 2>&1 || true
    rc-service snell stop >/dev/null 2>&1 || true
    rc-update del shadowtls default >/dev/null 2>&1 || true
    rc-update del snell default >/dev/null 2>&1 || true
    rm -f /etc/init.d/shadowtls
    rm -f /etc/init.d/snell
  fi

  rm -f "$SHADOWTLS_BIN"
  rm -f "$SNELL_BIN"
  rm -rf "$SNELL_CONF_DIR"
  rm -rf "$BASE_DIR"

  log "卸载完成"
}

usage() {
  cat <<EOF2
用法：
  sh ${SCRIPT_NAME}.sh install      安装 / 重装
  sh ${SCRIPT_NAME}.sh qr           显示二维码和节点配置行
  sh ${SCRIPT_NAME}.sh info         显示节点信息
  sh ${SCRIPT_NAME}.sh status       查看服务状态
  sh ${SCRIPT_NAME}.sh logs         查看日志
  sh ${SCRIPT_NAME}.sh restart      重启服务
  sh ${SCRIPT_NAME}.sh uninstall    卸载

可选环境变量：
  PUBLIC_PORT=443                   ShadowTLS 对外端口
  BACKEND_PORT=28111                Snell 本机后端端口
  TLS_DOMAIN=www.microsoft.com      ShadowTLS 伪装 SNI，建议选支持 TLS1.3 的大站
  LISTEN_ADDR=0.0.0.0               监听地址；IPv6 可尝试 LISTEN_ADDR=::
  IPV6_OUT=false                    Snell 出站是否启用 IPv6：true / false
  SNELL_VERSION=5.0.1               Snell 服务端版本
  SHADOWTLS_VERSION=latest          ShadowTLS 版本，例如 v0.2.25
  SNELL_PSK=xxxx                    自定义 Snell PSK
  STLS_PASSWORD=yyyy                自定义 ShadowTLS 密码

示例：
  PUBLIC_PORT=8443 TLS_DOMAIN=www.microsoft.com sh ${SCRIPT_NAME}.sh install
EOF2
}

case "${1:-install}" in
  install) install_all ;;
  qr) show_qr ;;
  info) show_info ;;
  status) status_all ;;
  logs|log) show_logs ;;
  restart) restart_all ;;
  uninstall|remove) uninstall_all ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
