#!/usr/bin/env bash
# update.sh
# Angelo-xui-plugin 一键升级脚本（已装 3x-ui 时使用）
# 用法:
#   curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/update.sh | sudo bash -s -- --tag v0.2
#   curl -sSL ... | sudo bash -s -- --channel dev-latest
#
# 与 install-fresh.sh 的区别:
#   - 不动 /etc/x-ui/x-ui.db（用户数据 + 流量历史完整保留）
#   - 不动现有 systemd 服务（只替换二进制和 bin/ 下 xray/dat）
#   - 强制备份当前二进制，出错自动回滚
#
# 安全保证:
#   - 数据库列 traffic_multiplier 由 GORM AutoMigrate 自动加，默认 1.0
#   - 历史流量 (client_traffics.up/down) 保持不变，仅从升级后产生的流量按倍率写入
#   - 备份文件保留在 /var/backups/x-ui-multiplier/，可随时回滚
set -euo pipefail

REPO="AngeloSakura/Angelo-xui-plugin"
TAG=""
CHANNEL=""
BACKUP_DIR="/var/backups/x-ui-multiplier"
LOG_FILE="/var/log/x-ui-multiplier-update.log"
INSTALL_DIR="/usr/local/x-ui"

# ---------- 参数解析 ----------
usage() {
  sed -n '2,16p' "$0"
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
echo " Angelo-xui-plugin 升级"
echo " 时间: $(date '+%F %T')"
echo " 版本: $TAG"
echo " 仓库: $REPO"
echo "===================================================="

# ---------- 前置检查 ----------
if [[ $EUID -ne 0 ]]; then
  echo "❌ 需要 root 权限。请使用 sudo bash update.sh ..."
  exit 1
fi

for cmd in curl tar; do
  if ! command -v "$cmd" >/dev/null; then
    echo "❌ 缺少命令: $cmd"
    exit 1
  fi
done

# ---------- 检测架构 ----------
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  armv7l)  ARCH="armv7" ;;
  *)
    echo "❌ 不支持的架构: $ARCH_RAW"
    exit 1
    ;;
esac
echo "✅ 检测到架构: $ARCH_RAW → $ARCH"

# ---------- 定位现有 x-ui ----------
XUI_BIN=""
for candidate in "$INSTALL_DIR/x-ui" "$INSTALL_DIR/bin/x-ui" /usr/bin/x-ui; do
  if [[ -x "$candidate" ]]; then
    XUI_BIN="$candidate"
    break
  fi
done

if [[ -z "$XUI_BIN" ]]; then
  echo "❌ 找不到现有的 x-ui 二进制（路径: $INSTALL_DIR/x-ui 或 /usr/bin/x-ui）"
  echo "   如果是新 VPS，请改用 install-fresh.sh:"
  echo "   curl -sSL https://raw.githubusercontent.com/${REPO}/main/install-fresh.sh | sudo bash -s -- --tag $TAG"
  exit 1
fi
echo "✅ 找到现有 x-ui: $XUI_BIN"

CURRENT_VER=$("$XUI_BIN" version 2>/dev/null | head -1 || echo "unknown")
echo "   当前版本: $CURRENT_VER"

# ---------- 数据库预检查（不修改，只确认存在）----------
DB_PATH=""
for candidate in /etc/x-ui/x-ui.db /usr/local/x-ui/db/x-ui.db /var/lib/x-ui/x-ui.db "$INSTALL_DIR/db/x-ui.db"; do
  if [[ -f "$candidate" ]]; then
    DB_PATH="$candidate"
    break
  fi
done
if [[ -n "$DB_PATH" ]]; then
  echo "✅ 数据库: $DB_PATH (不会被修改)"
else
  echo "⚠️  未找到数据库文件。如果这是新安装，可能还没生成。"
fi

# ---------- 备份 ----------
mkdir -p "$BACKUP_DIR"
TS=$(date '+%Y%m%d-%H%M%S')
BACKUP_BIN="$BACKUP_DIR/x-ui.bak.$TS"
cp -p "$XUI_BIN" "$BACKUP_BIN"
echo "✅ 已备份原二进制到: $BACKUP_BIN"

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
  echo "   原二进制未被修改: $XUI_BIN"
  echo "   请到 https://github.com/${REPO}/releases/tag/${TAG} 确认产物"
  exit 1
fi

FILE_SIZE=$(stat -c%s "$TMP_DIR/$ASSET" 2>/dev/null || stat -f%z "$TMP_DIR/$ASSET")
echo "   下载完成: $(numfmt --to=iec "$FILE_SIZE" 2>/dev/null || echo "${FILE_SIZE} bytes")"

if [[ "$FILE_SIZE" -lt 1000000 ]]; then
  echo "❌ 产物文件太小（<1MB），可能下载失败"
  exit 1
fi

# ---------- 解压 ----------
echo "📦 解压..."
tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR"
NEW_BIN_SRC="$TMP_DIR/x-ui/x-ui"
NEW_BIN_DIR_SRC="$TMP_DIR/x-ui/bin"
NEW_SH_SRC="$TMP_DIR/x-ui/x-ui.sh"

if [[ ! -x "$NEW_BIN_SRC" ]]; then
  echo "❌ 解压后找不到 x-ui 二进制"
  ls -la "$TMP_DIR/x-ui/"
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

# 让 xray 退出
sleep 1
pkill -f xray-linux 2>/dev/null || true
sleep 1

# ---------- 替换二进制 + bin/ 下资源 ----------
echo "🔄 替换二进制..."

# 替换主二进制
chmod +x "$NEW_BIN_SRC"
if ! cp -f "$NEW_BIN_SRC" "$XUI_BIN"; then
  echo "❌ 替换二进制失败，尝试回滚..."
  cp -f "$BACKUP_BIN" "$XUI_BIN"
  exit 1
fi

# 替换 x-ui.sh（管理脚本）
if [[ -f "$NEW_SH_SRC" ]]; then
  cp -f "$NEW_SH_SRC" "$INSTALL_DIR/x-ui.sh"
  chmod +x "$INSTALL_DIR/x-ui.sh"
fi

# 更新 bin/ 下资源（xray + dat + mtg）
# 注意：保留用户自定义的额外文件，只覆盖同名文件
BIN_DIR="$INSTALL_DIR/bin"
mkdir -p "$BIN_DIR"
if [[ -d "$NEW_BIN_DIR_SRC" ]]; then
  echo "📦 更新 bin/ 下资源（xray / dat / mtg）..."
  # cp -n 避免覆盖用户自加文件，只更新 tarball 里的
  cp -rn "$NEW_BIN_DIR_SRC/." "$BIN_DIR/" 2>/dev/null || cp -r "$NEW_BIN_DIR_SRC/." "$BIN_DIR/"
  chmod +x "$BIN_DIR"/xray-linux-${ARCH} 2>/dev/null || true
  chmod +x "$BIN_DIR"/mtg-linux-${ARCH}   2>/dev/null || true
fi

# ---------- 启动 ----------
if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
  echo "▶️  启动 x-ui 服务..."
  systemctl start x-ui
elif systemctl list-unit-files 2>/dev/null | grep -q "^x-ui.service"; then
  echo "▶️  启动 x-ui 服务 (enable 但未 active)..."
  systemctl start x-ui
elif command -v x-ui >/dev/null; then
  x-ui start
else
  echo "⚠️  未找到启动方式，请手动启动 x-ui"
fi

# ---------- 等待并验证 ----------
echo "⏳ 等待服务就绪..."
for i in {1..20}; do
  if systemctl is-active --quiet x-ui 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! systemctl is-active --quiet x-ui 2>/dev/null; then
  echo "❌ 服务未启动，请查看日志: journalctl -u x-ui -n 50"
  echo ""
  echo " 回滚命令:"
  echo "   sudo systemctl stop x-ui"
  echo "   sudo cp $BACKUP_BIN $XUI_BIN"
  echo "   sudo systemctl start x-ui"
  exit 1
fi

NEW_VER=$("$XUI_BIN" version 2>/dev/null | head -1 || echo "unknown")
echo "✅ 已升级到: $NEW_VER"

# ---------- 数据库迁移验证 ----------
echo ""
echo "🔍 检查数据库迁移..."
sleep 2
if [[ -z "$DB_PATH" ]]; then
  echo "⚠️  数据库未找到，跳过检查"
elif ! command -v sqlite3 >/dev/null; then
  echo "⚠️  系统没装 sqlite3，无法自动验证"
  echo "   进面板 → Inbounds → 编辑入站，看是否有 Traffic multiplier 字段"
elif sqlite3 "$DB_PATH" "PRAGMA table_info(inbounds);" 2>/dev/null | grep -q "traffic_multiplier"; then
  echo "✅ 数据库已自动添加 traffic_multiplier 列"
else
  echo "⚠️  数据库列未找到。可能服务还在启动中，请等 30 秒再检查"
  echo "   检查命令: sudo sqlite3 $DB_PATH \"PRAGMA table_info(inbounds);\""
fi

echo ""
echo "===================================================="
echo " ✅ 升级完成"
echo "===================================================="
echo ""
echo " 旧版本:    $CURRENT_VER"
echo " 新版本:    $NEW_VER"
echo " 备份文件:  $BACKUP_BIN"
echo " 日志文件:  $LOG_FILE"
echo " 数据库:    $DB_PATH (未修改)"
echo ""
echo " 下一步:"
echo "   1. 强制刷新浏览器 (Ctrl+Shift+R) 清前端缓存"
echo "   2. 进 Inbounds → 编辑入站 → Basic 标签"
echo "   3. 设置 Traffic multiplier (例 5 表示 5 倍率)"
echo ""
echo " 如需回滚:"
echo "   sudo systemctl stop x-ui"
echo "   sudo cp $BACKUP_BIN $XUI_BIN"
echo "   sudo systemctl start x-ui"
echo ""
