#!/usr/bin/env bash
# install-fresh.sh
# Angelo-xui-plugin 一键安装脚本（全新 VPS，从零部署）
# 兼容：Debian/Ubuntu (systemd) · Alpine (OpenRC) · RHEL/Fedora
#
# 用法:
#   curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/install-fresh.sh | sudo bash -s -- --tag dev-latest
set -euo pipefail

REPO="AngeloSakura/Angelo-xui-plugin"
TAG=""
CHANNEL=""
LOG_FILE="/var/log/x-ui-multiplier-install.log"
INSTALL_DIR="/usr/local/x-ui"
DB_PATH="/etc/x-ui/x-ui.db"

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[1;33m'; blue='\033[0;34m'; plain='\033[0m'
log()   { echo -e "${green}[$(date +%H:%M:%S)]${plain} $*"; }
warn()  { echo -e "${yellow}[$(date +%H:%M:%S)] ⚠${plain} $*"; }
err()   { echo -e "${red}[$(date +%H:%M:%S)] ❌${plain} $*"; }

# ---------- 参数解析 ----------
usage() { sed -n '2,8p' "$0"; exit 0; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)     TAG="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) err "未知参数: $1"; exit 1 ;;
  esac
done
[[ -n "$CHANNEL" ]] && TAG="$CHANNEL"
if [[ -z "$TAG" ]]; then
  err "必须指定 --tag (例 v0.2) 或 --channel (例 dev-latest)"
  exit 1
fi

# ---------- 日志 ----------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo -e "${blue}====================================================${plain}"
echo -e "${green} Angelo-xui-plugin 全新安装${plain}"
echo " 时间: $(date '+%F %T')"
echo " 版本: $TAG"
echo " 仓库: $REPO"
echo -e "${blue}====================================================${plain}"

# ---------- 前置 ----------
[[ $EUID -eq 0 ]] || { err "需要 root 权限。请使用 sudo bash install-fresh.sh ..."; exit 1; }

# 包管理器 / 初始化系统检测
PKG_MGR=""; INIT=""
if [[ -f /etc/alpine-release ]]; then
  PKG_MGR="apk"; INIT="openrc"
elif command -v apt-get >/dev/null; then
  PKG_MGR="apt"; INIT="systemd"
elif command -v dnf >/dev/null; then
  PKG_MGR="dnf"; INIT="systemd"
elif command -v yum >/dev/null; then
  PKG_MGR="yum"; INIT="systemd"
fi
if [[ -z "$PKG_MGR" ]]; then err "不支持的发行版（需要 apt/yum/dnf/apk）"; exit 1; fi
log "✅ 包管理器: $PKG_MGR  初始化: $INIT"

# 装基础依赖
log "📦 安装依赖..."
case "$PKG_MGR" in
  apt) DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
       DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar ca-certificates sqlite3 >/dev/null ;;
  yum) yum install -y curl tar ca-certificates sqlite >/dev/null ;;
  dnf) dnf install -y curl tar ca-certificates sqlite >/dev/null ;;
  apk) apk add --no-cache curl tar ca-certificates sqlite3 >/dev/null ;;
esac

# ---------- 架构 ----------
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64|x64|amd64)  ARCH="amd64" ;;
  aarch64|arm64)     ARCH="arm64" ;;
  armv7l)            ARCH="armv7" ;;
  *) err "不支持的架构: $ARCH_RAW"; exit 1 ;;
esac
log "✅ 架构: $ARCH_RAW → $ARCH"

# ---------- 已存在检查 ----------
if [[ -x "$INSTALL_DIR/bin/x-ui" ]] || [[ -x "$INSTALL_DIR/x-ui" ]]; then
  warn "检测到 $INSTALL_DIR 已存在 x-ui 二进制"
  warn "如要升级，请改用 update.sh:"
  warn "  curl -sSL https://raw.githubusercontent.com/${REPO}/main/update.sh | sudo bash -s -- --tag $TAG"
  exit 1
fi

# ---------- 下载 ----------
# 资产 URL 固定: https://github.com/${REPO}/releases/download/<TAG>/x-ui-linux-${ARCH}.tar.gz
ASSET_NAME="x-ui-linux-${ARCH}.tar.gz"
ASSET_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET_NAME}"

log "⬇️  下载: $ASSET_URL"
TMP_DIR=$(mktemp -d); trap 'rm -rf "$TMP_DIR"' EXIT
TMP_FILE="$TMP_DIR/x-ui.tar.gz"
if ! curl -fsSL --max-time 120 --retry 3 -o "$TMP_FILE" "$ASSET_URL"; then
  err "下载失败: $ASSET_URL"
  err "请检查 tag/release 是否存在，或联系作者"
  exit 1
fi
FILE_SIZE=$(stat -c%s "$TMP_FILE" 2>/dev/null || stat -f%z "$TMP_FILE")
log "   下载完成: $FILE_SIZE bytes"
[[ "$FILE_SIZE" -lt 1000000 ]] && { err "产物太小 (<1MB)，下载可能失败"; exit 1; }

# ---------- 解压 ----------
log "📦 解压..."
tar -xzf "$TMP_FILE" -C "$TMP_DIR"
# 自适应目录（可能是 x-ui/ 也可能是直接的）
EXTRACT_ROOT=$(find "$TMP_DIR" -maxdepth 2 -type d \( -name 'x-ui' -o -name "*linux-${ARCH}*" \) | head -1)
[[ -z "$EXTRACT_ROOT" ]] && EXTRACT_ROOT=$(find "$TMP_DIR" -maxdepth 1 -type d ! -path "$TMP_DIR" | head -1)
[[ -z "$EXTRACT_ROOT" ]] && EXTRACT_ROOT="$TMP_DIR"

NEW_BIN=$(find "$EXTRACT_ROOT" -maxdepth 3 -name 'x-ui' -type f | head -1)
[[ -z "$NEW_BIN" ]] && { err "解压后找不到 x-ui 二进制"; ls -la "$EXTRACT_ROOT/"; exit 1; }

# ---------- 准备目录 ----------
log "📁 创建目录..."
mkdir -p "$INSTALL_DIR/bin" "$(dirname "$DB_PATH")" /var/log/x-ui

# 复制
cp -af "$EXTRACT_ROOT"/bin/* "$INSTALL_DIR/bin/" 2>/dev/null || true
cp -af "$NEW_BIN" "$INSTALL_DIR/x-ui"
[[ -f "$EXTRACT_ROOT/x-ui.sh" ]] && cp -af "$EXTRACT_ROOT/x-ui.sh" "$INSTALL_DIR/x-ui.sh"
chmod +x "$INSTALL_DIR/x-ui" "$INSTALL_DIR/x-ui.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/bin/"/* 2>/dev/null || true

# ---------- 注册服务 ----------
install_systemd() {
  cat > /etc/systemd/system/x-ui.service <<EOF
[Unit]
Description=x-ui Service
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/x-ui run
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 /etc/systemd/system/x-ui.service
  systemctl daemon-reload
  systemctl enable x-ui
}
install_openrc() {
  cat > /etc/init.d/x-ui <<EOF
#!/sbin/openrc-run
name="x-ui"
description="x-ui Service"
command="$INSTALL_DIR/x-ui"
command_args="run"
directory="$INSTALL_DIR"
pidfile="/run/\${name}.pid"
output_log="/var/log/x-ui/x-ui.log"
error_log="/var/log/x-ui/x-ui.err"
depend() { need net; after firewall; }
start()  { ebegin "Starting \${name}"; \${command} \${command_args} >\${output_log} 2>\${error_log} & echo \$! > \${pidfile}; eend \$?; }
stop()   { ebegin "Stopping \${name}"; kill -TERM \$(cat \${pidfile}) 2>/dev/null; rm -f \${pidfile}; eend \$?; }
EOF
  chmod +x /etc/init.d/x-ui
  rc-update add x-ui default 2>/dev/null || true
}

case "$INIT" in
  systemd) log "🛠️  注册 systemd 服务..."; install_systemd ;;
  openrc)  log "🛠️  注册 OpenRC 服务..."; install_openrc ;;
esac

# ---------- 启动 ----------
start_svc() {
  case "$INIT" in
    systemd) systemctl start x-ui ;;
    openrc)  rc-service x-ui start 2>/dev/null || /etc/init.d/x-ui start 2>/dev/null || true ;;
  esac
}
svc_active() {
  case "$INIT" in
    systemd) systemctl is-active --quiet x-ui ;;
    openrc)  rc-service x-ui status 2>/dev/null | grep -q started ;;
  esac
}
show_logs() {
  case "$INIT" in
    systemd) journalctl -u x-ui -n 50 --no-pager ;;
    openrc)  cat /var/log/x-ui/x-ui.err 2>/dev/null; cat /var/log/x-ui/x-ui.log 2>/dev/null ;;
  esac
}

log "▶️  启动 x-ui 服务..."
start_svc
log "⏳ 等待服务就绪..."
for i in {1..30}; do svc_active && break; sleep 1; done

if ! svc_active; then
  err "服务未启动！日志："
  echo "----- 日志 -----"; show_logs; echo "---------------"
  exit 1
fi

VER_INSTALLED=$("$INSTALL_DIR/x-ui" version 2>/dev/null | head -1 || echo "unknown")
log "✅ 已安装版本: $VER_INSTALLED"

# ---------- 数据库迁移验证 ----------
log ""
log "🔍 检查数据库迁移..."
sleep 2
if [[ -f "$DB_PATH" ]] && command -v sqlite3 >/dev/null; then
  if sqlite3 "$DB_PATH" "PRAGMA table_info(inbounds);" 2>/dev/null | grep -q "traffic_multiplier"; then
    log "✅ 数据库已就绪 (traffic_multiplier 列存在)"
  else
    warn "数据库列未找到。服务刚启动，再等几秒..."
  fi
else
  warn "跳过数据库检查（数据库尚未生成或 sqlite3 未装）"
fi

echo ""
echo -e "${blue}====================================================${plain}"
echo -e "${green} ✅ 安装完成${plain}"
echo -e "${blue}====================================================${plain}"
echo ""
echo " 安装目录: $INSTALL_DIR"
echo " 数据库:   $DB_PATH"
echo " 日志:     $LOG_FILE"
echo ""
echo " 服务管理:"
case "$INIT" in
  systemd)
    echo "   sudo systemctl status  x-ui"
    echo "   sudo systemctl restart x-ui"
    echo "   sudo journalctl -u x-ui -f" ;;
  openrc)
    echo "   sudo rc-service x-ui status"
    echo "   sudo rc-service x-ui restart"
    echo "   sudo tail -f /var/log/x-ui/x-ui.log" ;;
esac
echo ""
echo " 首次登录凭证:"
echo "   URL:      http://<your-vps-ip>:2053"
echo "   用户名/密码: sudo $INSTALL_DIR/x-ui setting -username -password"
echo ""
echo " 下一步:"
echo "   1. 浏览器访问面板 http://<ip>:2053"
echo "   2. 首次登录后立即改密码（Settings → Profile）"
echo "   3. 进 Inbounds → 编辑入站 → Basic 标签"
echo "   4. 设置 Traffic multiplier (例 5 表示倍率 5x)"