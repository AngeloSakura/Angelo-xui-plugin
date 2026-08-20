#!/usr/bin/env bash
# install-fresh.sh
# Angelo-xui-plugin 一键安装脚本（全新 VPS，从零部署）
# 用法:
#   curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/install-fresh.sh | sudo bash -s -- --tag v0.2
#   curl -sSL ... | sudo bash -s -- --tag dev-latest --channel dev
#
# 功能:
#   1. 自动检测架构 (amd64 / arm64 / armv7)
#   2. 安装运行时依赖 (curl, tar, sqlite3, ca-certificates)
#   3. 从 GitHub Release 下载 Angelo-xui-plugin tarball
#   4. 创建 /usr/local/x-ui/ 目录结构 + systemd 服务
#   5. 启动 x-ui 服务（首次会自动生成随机用户名/密码并打印）
#   6. 验证数据库 traffic_multiplier 列已就绪
set -euo pipefail

REPO="AngeloSakura/Angelo-xui-plugin"
TAG=""
CHANNEL=""
LOG_FILE="/var/log/x-ui-multiplier-install.log"
INSTALL_DIR="/usr/local/x-ui"
DB_PATH="/etc/x-ui/x-ui.db"

# ---------- 参数解析 ----------
usage() {
  sed -n '2,14p' "$0"
  exit 0
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)     TAG="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

if [[ -n "$CHANNEL" ]]; then
  TAG="$CHANNEL"
fi
if [[ -z "$TAG" ]]; then
  echo "❌ 必须指定 --tag (例 v0.2) 或 --channel (例 dev-latest)"
  exit 1
fi

# ---------- 日志 ----------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "===================================================="
echo " Angelo-xui-plugin 全新安装"
echo " 时间: $(date '+%F %T')"
echo " 版本: $TAG"
echo " 仓库: $REPO"
echo "===================================================="

# ---------- 前置检查 ----------
if [[ $EUID -ne 0 ]]; then
  echo "❌ 需要 root 权限。请使用 sudo bash install-fresh.sh ..."
  exit 1
fi

# 检测包管理器
PKG_MGR=""
if   command -v apt-get >/dev/null; then PKG_MGR="apt"
elif command -v yum     >/dev/null; then PKG_MGR="yum"
elif command -v dnf     >/dev/null; then PKG_MGR="dnf"
elif command -v apk     >/dev/null; then PKG_MGR="apk"
fi
if [[ -z "$PKG_MGR" ]]; then
  echo "❌ 不支持的发行版（需要 apt/yum/dnf/apk 之一）"
  exit 1
fi
echo "✅ 包管理器: $PKG_MGR"

# 装基础依赖
echo "📦 安装依赖..."
case "$PKG_MGR" in
  apt) DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
       DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar ca-certificates sqlite3 >/dev/null ;;
  yum) yum install -y curl tar ca-certificates sqlite >/dev/null ;;
  dnf) dnf install -y curl tar ca-certificates sqlite >/dev/null ;;
  apk) apk add --no-cache curl tar ca-certificates sqlite >/dev/null ;;
esac

# ---------- 检测架构 ----------
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  armv7l)  ARCH="armv7" ;;
  *)
    echo "❌ 不支持的架构: $ARCH_RAW（仅支持 amd64 / arm64 / armv7）"
    exit 1
    ;;
esac
echo "✅ 检测到架构: $ARCH_RAW → $ARCH"

# ---------- 检测是否已安装 ----------
if [[ -x "$INSTALL_DIR/bin/x-ui" ]] || [[ -x "$INSTALL_DIR/x-ui" ]]; then
  echo "⚠️  检测到 $INSTALL_DIR 已存在 x-ui 二进制"
  echo "   如果想升级现有 3x-ui，请改用 update.sh："
  echo "   curl -sSL https://raw.githubusercontent.com/${REPO}/main/update.sh | sudo bash -s -- --tag $TAG"
  exit 1
fi

# ---------- 下载 ----------
ASSET="x-ui-linux-${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
echo "⬇️  下载: $DOWNLOAD_URL"

if ! curl -fsSL --retry 3 --retry-delay 5 -o "$TMP_DIR/$ASSET" "$DOWNLOAD_URL"; then
  echo "❌ 下载失败。可能原因:"
  echo "   1. tag $TAG 不存在"
  echo "   2. 该架构 $ARCH 没有产物（目前只构建 amd64）"
  echo "   3. 网络问题"
  echo ""
  echo "   请到 https://github.com/${REPO}/releases/tag/${TAG} 确认产物"
  exit 1
fi

FILE_SIZE=$(stat -c%s "$TMP_DIR/$ASSET" 2>/dev/null || stat -f%z "$TMP_DIR/$ASSET")
echo "   下载完成: $(numfmt --to=iec "$FILE_SIZE" 2>/dev/null || echo "${FILE_SIZE} bytes")"

if [[ "$FILE_SIZE" -lt 1000000 ]]; then
  echo "❌ 产物文件太小（<1MB），可能下载失败"
  exit 1
fi

# ---------- 解压到临时目录 ----------
echo "📦 解压..."
tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR"
if [[ ! -x "$TMP_DIR/x-ui/x-ui" ]]; then
  echo "❌ 解压后找不到 x-ui 二进制"
  ls -la "$TMP_DIR/x-ui/"
  exit 1
fi

# ---------- 准备目录结构 ----------
echo "📁 创建目录..."
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$(dirname "$DB_PATH")"
mkdir -p /var/log/x-ui

# 复制文件
cp -rT "$TMP_DIR/x-ui/bin" "$INSTALL_DIR/bin"
cp "$TMP_DIR/x-ui/x-ui"     "$INSTALL_DIR/x-ui"
cp "$TMP_DIR/x-ui/x-ui.sh"  "$INSTALL_DIR/x-ui.sh"
chmod +x "$INSTALL_DIR/x-ui"
chmod +x "$INSTALL_DIR/x-ui.sh"
chmod +x "$INSTALL_DIR/bin/xray-linux-${ARCH}" 2>/dev/null || true
chmod +x "$INSTALL_DIR/bin/mtg-linux-${ARCH}"  2>/dev/null || true

# ---------- systemd 服务 ----------
echo "🛠️  注册 systemd 服务..."
SERVICE_FILE="/etc/systemd/system/x-ui.service"
cat > "$SERVICE_FILE" <<EOF
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
chmod 644 "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable x-ui

# ---------- 启动 ----------
echo "▶️  启动 x-ui 服务..."
systemctl start x-ui

echo "⏳ 等待服务就绪..."
for i in {1..15}; do
  if systemctl is-active --quiet x-ui; then
    break
  fi
  sleep 1
done

if ! systemctl is-active --quiet x-ui; then
  echo "❌ 服务未启动，请查看日志: journalctl -u x-ui -n 50"
  exit 1
fi

VER_INSTALLED=$("$INSTALL_DIR/x-ui" version 2>/dev/null | head -1 || echo "unknown")
echo "✅ 已安装版本: $VER_INSTALLED"

# ---------- 数据库迁移验证 ----------
echo ""
echo "🔍 检查数据库迁移..."
sleep 2
if [[ -f "$DB_PATH" ]] && command -v sqlite3 >/dev/null; then
  if sqlite3 "$DB_PATH" "PRAGMA table_info(inbounds);" 2>/dev/null | grep -q "traffic_multiplier"; then
    echo "✅ 数据库已就绪 (traffic_multiplier 列存在)"
  else
    echo "⚠️  数据库列未找到。服务刚启动，再等几秒..."
  fi
else
  echo "⚠️  跳过数据库检查（数据库尚未生成或 sqlite3 未装）"
fi

echo ""
echo "===================================================="
echo " ✅ 安装完成"
echo "===================================================="
echo ""
echo " 安装目录: $INSTALL_DIR"
echo " 数据库:   $DB_PATH"
echo " 日志:     $LOG_FILE"
echo ""
echo " 服务管理:"
echo "   sudo systemctl status  x-ui"
echo "   sudo systemctl restart x-ui"
echo "   sudo journalctl -u x-ui -f"
echo ""
echo " 首次登录凭证:"
echo "   URL:      http://<your-vps-ip>:2053"
echo "   用户名:   (自动生成，查看上面服务日志或: sudo x-ui setting -username)"
echo "   密码:     (自动生成，查看上面服务日志或: sudo x-ui setting -password)"
echo ""
echo " 下一步:"
echo "   1. 浏览器访问面板 http://<ip>:2053"
echo "   2. 首次登录后立即改密码（Settings → Profile）"
echo "   3. 进 Inbounds → 编辑入站 → Basic 标签"
echo "   4. 设置 Traffic multiplier (例 5 表示倍率 5x)"
echo ""
