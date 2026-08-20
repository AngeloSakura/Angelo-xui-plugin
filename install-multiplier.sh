#!/usr/bin/env bash
# install-multiplier.sh
# Angelo-xui-plugin 一键安装脚本
# 用法:
#   curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/install-multiplier.sh | sudo bash -s -- --tag v0.1
#   curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/install-multiplier.sh | sudo bash -s -- --tag v0.1 --repo AngeloSakura/Angelo-xui-plugin
#
# 功能:
#   1. 自动检测架构 (amd64 / arm64)
#   2. 从 GitHub Release 下载对应 tarball
#   3. 备份现有 /usr/local/x-ui/bin/x-ui
#   4. 停止 x-ui 服务
#   5. 替换二进制
#   6. 启动 x-ui 服务
#   7. 验证数据库 traffic_multiplier 列已自动添加
#   8. 出错自动回滚
set -euo pipefail

REPO="AngeloSakura/Angelo-xui-plugin"
TAG=""
BACKUP_DIR="/var/backups/x-ui-multiplier"
LOG_FILE="/var/log/x-ui-multiplier-install.log"

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)  TAG="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "❌ 必须指定 --tag，例如 --tag v0.1"
  exit 1
fi

# ---------- 日志函数 ----------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "===================================================="
echo " Angelo-xui-plugin 安装开始"
echo " 时间: $(date '+%F %T')"
echo " 版本: $TAG"
echo " 仓库: $REPO"
echo "===================================================="

# ---------- 前置检查 ----------
if [[ $EUID -ne 0 ]]; then
  echo "❌ 需要 root 权限。请使用 sudo bash install-multiplier.sh ..."
  exit 1
fi

if ! command -v curl >/dev/null; then
  echo "❌ 缺少 curl。请先 apt install curl / yum install curl"
  exit 1
fi

if ! command -v tar >/dev/null; then
  echo "❌ 缺少 tar"
  exit 1
fi

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

# ---------- 检测 x-ui 安装路径 ----------
XUI_BIN=""
for candidate in /usr/local/x-ui/bin/x-ui /usr/bin/x-ui /opt/x-ui/bin/x-ui; do
  if [[ -x "$candidate" ]]; then
    XUI_BIN="$candidate"
    break
  fi
done

if [[ -z "$XUI_BIN" ]]; then
  echo "❌ 找不到 x-ui 二进制。常见路径:"
  echo "   /usr/local/x-ui/bin/x-ui"
  echo "   /usr/bin/x-ui"
  echo "   请先安装原版 3x-ui 后再运行此脚本"
  exit 1
fi
echo "✅ 找到 x-ui: $XUI_BIN"

XUI_DIR=$(dirname "$(dirname "$XUI_BIN")")
echo "   安装目录: $XUI_DIR"

# ---------- 备份 ----------
mkdir -p "$BACKUP_DIR"
TS_BACKUP=$(date '+%Y%m%d-%H%M%S')
BACKUP_PATH="$BACKUP_DIR/x-ui.bak.$TS_BACKUP"
cp -p "$XUI_BIN" "$BACKUP_PATH"
echo "✅ 已备份原二进制到: $BACKUP_PATH"

# ---------- 下载 ----------
ASSET="x-ui-linux-${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
echo "⬇️  下载: $DOWNLOAD_URL"

if ! curl -fsSL --retry 3 --retry-delay 5 -o "$TMP_DIR/$ASSET" "$DOWNLOAD_URL"; then
  echo "❌ 下载失败。可能原因:"
  echo "   1. tag $TAG 不存在"
  echo "   2. 该架构 $ARCH 没有产物"
  echo "   3. 网络问题"
  echo ""
  echo "   请到 https://github.com/${REPO}/releases/tag/${TAG} 确认产物"
  exit 1
fi

# ---------- 校验 ----------
FILE_SIZE=$(stat -c%s "$TMP_DIR/$ASSET" 2>/dev/null || stat -f%z "$TMP_DIR/$ASSET")
echo "   下载完成: $(numfmt --to=iec "$FILE_SIZE" 2>/dev/null || echo "${FILE_SIZE} bytes")"

if [[ "$FILE_SIZE" -lt 1000000 ]]; then
  echo "❌ 产物文件太小（<1MB），可能下载失败"
  exit 1
fi

# ---------- 解压 ----------
echo "📦 解压..."
tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR"
NEW_BIN="$TMP_DIR/x-ui"

if [[ ! -x "$NEW_BIN" ]]; then
  echo "❌ 解压后找不到 x-ui 二进制"
  ls -la "$TMP_DIR"
  exit 1
fi

# ---------- 停止服务 ----------
SERVICE_WAS_ACTIVE=false
if systemctl is-active --quiet x-ui 2>/dev/null; then
  SERVICE_WAS_ACTIVE=true
  echo "⏸️  停止 x-ui 服务..."
  systemctl stop x-ui || true
elif command -v x-ui >/dev/null; then
  echo "⏸️  通过 x-ui stop 停止..."
  x-ui stop 2>/dev/null || true
else
  echo "⚠️  未检测到 systemd x-ui，尝试直接 kill 旧进程..."
  pkill -f "$(basename "$XUI_BIN")" 2>/dev/null || true
  sleep 1
fi

# ---------- 替换 ----------
echo "🔄 替换二进制..."
chmod +x "$NEW_BIN"
if ! cp -f "$NEW_BIN" "$XUI_BIN"; then
  echo "❌ 替换失败，尝试回滚..."
  cp -f "$BACKUP_PATH" "$XUI_BIN"
  exit 1
fi

# ---------- 启动 ----------
if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
  echo "▶️  启动 x-ui 服务..."
  systemctl start x-ui
elif systemctl list-unit-files | grep -q "^x-ui.service"; then
  echo "▶️  启动 x-ui 服务 (enable 但未 active)..."
  systemctl start x-ui
elif command -v x-ui >/dev/null; then
  x-ui start
else
  echo "⚠️  未找到启动方式，请手动启动 x-ui"
fi

# ---------- 等待并验证 ----------
echo "⏳ 等待服务就绪..."
sleep 5

VER_INSTALLED=$("$XUI_BIN" version 2>/dev/null | head -1 || echo "unknown")
echo "✅ 已安装版本: $VER_INSTALLED"

# ---------- 数据库迁移验证 ----------
echo ""
echo "🔍 检查数据库迁移..."
DB_PATH=""
for candidate in /etc/x-ui/x-ui.db /usr/local/x-ui/db/x-ui.db /var/lib/x-ui/x-ui.db; do
  if [[ -f "$candidate" ]]; then
    DB_PATH="$candidate"
    break
  fi
done

if [[ -z "$DB_PATH" ]]; then
  echo "⚠️  找不到数据库文件，请手动检查"
elif command -v sqlite3 >/dev/null; then
  if sqlite3 "$DB_PATH" "PRAGMA table_info(inbounds);" 2>/dev/null | grep -q "traffic_multiplier"; then
    echo "✅ 数据库已自动添加 traffic_multiplier 列"
  else
    echo "⚠️  数据库列未找到。可能是:"
    echo "   - 服务还没启动 (等 30 秒再查)"
    echo "   - 数据库路径不同 (在主节点上 db 可能在 /etc/x-ui/)"
    echo "   - 进面板 → Inbounds → 编辑入站，如果看到 Traffic multiplier 字段就说明成功了"
  fi
else
  echo "⚠️  系统没装 sqlite3，无法自动验证。请手动检查面板"
fi

echo ""
echo "===================================================="
echo " ✅ 安装完成"
echo "===================================================="
echo ""
echo " 备份文件:   $BACKUP_PATH"
echo " 安装日志:   $LOG_FILE"
echo ""
echo " 下一步:"
echo "   1. 登录面板 → Inbounds → 编辑入站 → Basic 标签"
echo "   2. 找到 'Traffic multiplier' 字段，输入倍率 (例如 5)"
echo "   3. 保存即可生效"
echo ""
echo " 如需回滚:"
echo "   sudo cp $BACKUP_PATH $XUI_BIN"
echo "   sudo systemctl restart x-ui"
echo ""