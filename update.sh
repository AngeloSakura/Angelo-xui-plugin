#!/usr/bin/env bash
# update.sh
# Angelo-xui-plugin 一键升级脚本（已装 3x-ui 时使用）
# 双栈兼容：Debian/Ubuntu (glibc + systemd) 和 Alpine (musl + OpenRC)
#
# 用法:
#   curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/update.sh | sudo bash -s -- --tag dev-latest
#
# 安全保证:
#   - 数据库列 traffic_multiplier 由 GORM AutoMigrate 自动加，默认 1.0
#   - 历史流量 (client_traffics.up/down) 保持不变，仅从升级后产生的流量按倍率写入
#   - 备份文件保留在 /var/backups/x-ui-multiplier/，可随时回滚
set -euo pipefail

REPO="AngeloSakura/Angelo-xui-plugin"
TAG=""
ARCH=""

# 颜色
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
plain='\033[0m'

log()   { echo -e "${green}[$(date +%H:%M:%S)]${plain} $*"; }
warn()  { echo -e "${yellow}[$(date +%H:%M:%S)] ⚠ $*${plain}"; }
err()   { echo -e "${red}[$(date +%H:%M:%S)] ❌ $*${plain}"; }

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$TAG" ]]; then
  err "必须指定 --tag <version>"
  exit 1
fi

# ---------- 架构检测 ----------
arch() {
  case "$(uname -m)" in
    x86_64 | x64 | amd64) echo 'amd64' ;;
    aarch64 | arm64)      echo 'arm64' ;;
    *) err "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}
ARCH=$(arch)

# ---------- OS / 初始化系统检测 ----------
detect_init() {
  if [[ -f /etc/alpine-release ]]; then
    echo "openrc"
  elif command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
  else
    echo "unknown"
  fi
}
INIT=$(detect_init)

# Alpine musl 检测
IS_MUSL=0
case "$INIT" in
  openrc)
    # Alpine 上几乎一定是 musl；保险起见 ldd 看 libc.so.6 还是 ld-musl
    if ldd --version 2>&1 | grep -qi musl; then IS_MUSL=1; fi
    if [[ -f /etc/alpine-release ]]; then IS_MUSL=1; fi
    ;;
esac

# ---------- 路径定位 ----------
XUI_BIN=""
for candidate in /usr/local/x-ui/x-ui /usr/local/x-ui/bin/x-ui /usr/bin/x-ui; do
  [[ -x "$candidate" ]] && XUI_BIN="$candidate" && break
done
if [[ -z "$XUI_BIN" ]]; then
  err "未找到 x-ui 二进制，请先安装原版 3x-ui"
  exit 1
fi

XUI_DIR=$(dirname "$(dirname "$XUI_BIN")")
[[ -d "$XUI_DIR/bin" ]] || XUI_DIR=/usr/local/x-ui

DB_PATH="/etc/x-ui/x-ui.db"
[[ -f "$DB_PATH" ]] || DB_PATH="$XUI_DIR/db/x-ui.db"
[[ -f "$DB_PATH" ]] || DB_PATH="$XUI_DIR/x-ui.db"

# 服务控制
stop_svc() {
  case "$INIT" in
    systemd)
      systemctl stop x-ui 2>/dev/null || true
      ;;
    openrc)
      rc-service x-ui stop 2>/dev/null || \
      /etc/init.d/x-ui stop 2>/dev/null || true
      ;;
    *)
      "$XUI_BIN" stop 2>/dev/null || true
      ;;
  esac
}
start_svc() {
  case "$INIT" in
    systemd)
      systemctl start x-ui
      ;;
    openrc)
      rc-service x-ui start 2>/dev/null || \
      /etc/init.d/x-ui start 2>/dev/null || true
      ;;
    *)
      "$XUI_BIN" start 2>/dev/null || true
      ;;
  esac
}
svc_status() {
  case "$INIT" in
    systemd) systemctl is-active x-ui ;;
    openrc)
      if rc-service x-ui status 2>/dev/null | grep -q started; then
        echo "active"
      elif /etc/init.d/x-ui status 2>/dev/null | grep -q started; then
        echo "active"
      else
        echo "inactive"
      fi
      ;;
    *) "$XUI_BIN" status 2>/dev/null | grep -qi running && echo "active" || echo "inactive" ;;
  esac
}
logs_tail() {
  case "$INIT" in
    systemd) journalctl -u x-ui -n 50 --no-pager ;;
    openrc)  cat /var/log/x-ui.log 2>/dev/null || /var/log/messages 2>/dev/null || echo "无日志" ;;
    *)       "$XUI_BIN" log 2>/dev/null | tail -50 || echo "无日志" ;;
  esac
}

echo ""
echo -e "${blue}====================================================${plain}"
echo -e "${green} Angelo-xui-plugin 升级${plain}"
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo " 版本: $TAG"
echo " 仓库: $REPO"
echo -e "===================================================="
echo ""

log "✅ 检测到架构: $(uname -m) → $ARCH"
log "✅ 初始化系统: $INIT (musl=$IS_MUSL)"
log "✅ 找到现有 x-ui: $XUI_BIN"
"$XUI_BIN" version 2>/dev/null || "$XUI_BIN" -version 2>/dev/null || true
log "✅ 数据库: $DB_PATH (不会被修改)"

# ---------- 备份 ----------
BACKUP_DIR="/var/backups/x-ui-multiplier"
mkdir -p "$BACKUP_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/x-ui.bak.$STAMP"
cp -f "$XUI_BIN" "$BACKUP_FILE"
chmod +x "$BACKUP_FILE"
log "✅ 已备份原二进制到: $BACKUP_FILE"

# 备份 bin/ 下资源（xray/dat/mtg），如果存在
BIN_BACKUP_DIR="$BACKUP_DIR/bin.$STAMP"
if [[ -d "$XUI_DIR/bin" ]]; then
  cp -a "$XUI_DIR/bin" "$BIN_BACKUP_DIR"
  log "✅ 已备份 bin/ 到: $BIN_BACKUP_DIR"
fi

# ---------- 选产物 ----------
# 资产 URL 固定: https://github.com/${REPO}/releases/download/<TAG>/x-ui-linux-${ARCH}.tar.gz
TAG_FROM_REPO="${TAG}"
ASSET_NAME="x-ui-linux-${ARCH}.tar.gz"
ASSET_URL="https://github.com/${REPO}/releases/download/${TAG_FROM_REPO}/${ASSET_NAME}"

log "⬇️  下载: $ASSET_URL"
# Portable temp file across GNU coreutils, BSD, and BusyBox (Alpine).
# BusyBox mktemp rejects templates that aren't plain alpha + XXXXXX, so we
# build the .tar.gz suffix manually after creation.
TMP_TGZ=$(mktemp -t x-ui-XXXXXX)
case "$TMP_TGZ" in
  *.tar.gz) ;;
  *) TMP_TGZ="${TMP_TGZ}.tar.gz" ;;
esac
if ! curl -fsSL --max-time 120 --retry 3 -o "$TMP_TGZ" "$ASSET_URL"; then
  err "下载失败: $ASSET_URL"
  err "请检查 tag/release 是否存在，或联系作者"
  rm -f "$TMP_TGZ"
  exit 1
fi
FILE_SIZE=$(stat -c%s "$TMP_TGZ" 2>/dev/null || wc -c <"$TMP_TGZ")
log "   下载完成: $FILE_SIZE bytes"
[[ "$FILE_SIZE" -lt 1000000 ]] && { err "产物太小 (<1MB)，下载可能失败"; exit 1; }

# ---------- 替换 ----------
log "⏸️  停止服务..."
stop_svc
sleep 1

# 解压
TMP_DIR=$(mktemp -d)
tar -xzf "$TMP_TGZ" -C "$TMP_DIR"
EXTRACT_ROOT=$(find "$TMP_DIR" -maxdepth 2 -type d ! -path "$TMP_DIR" | head -1)
[[ -z "$EXTRACT_ROOT" ]] && EXTRACT_ROOT="$TMP_DIR"

# 找新二进制
NEW_BIN=$(find "$EXTRACT_ROOT" -maxdepth 3 -name 'x-ui' -type f -executable | head -1)
[[ -z "$NEW_BIN" ]] && NEW_BIN=$(find "$EXTRACT_ROOT" -maxdepth 3 -name 'x-ui' -type f | head -1)
if [[ -z "$NEW_BIN" ]]; then
  err "产物内未找到 x-ui 二进制"
  rm -rf "$TMP_DIR" "$TMP_TGZ"
  exit 1
fi

log "🔄 替换二进制: $XUI_BIN"
install -m 755 "$NEW_BIN" "$XUI_BIN"

# 替换 bin/ 资源（xray/dat/mtg），如果新 tarball 里也有
if [[ -d "$EXTRACT_ROOT/bin" ]]; then
  log "� 更新 bin/ 下资源..."
  cp -af "$EXTRACT_ROOT"/bin/* "$XUI_DIR/bin/" 2>/dev/null || true
  chmod +x "$XUI_DIR/bin/"/* 2>/dev/null || true
fi

# ---------- 启动 ----------
log "▶️  启动服务..."
start_svc

# ---------- 健康检查 ----------
log "⏳ 等待服务就绪..."
TRIES=30
RUNNING="inactive"
while [[ $TRIES -gt 0 ]]; do
  RUNNING=$(svc_status)
  [[ "$RUNNING" == "active" ]] && break
  sleep 1
  TRIES=$((TRIES - 1))
done

rm -rf "$TMP_DIR" "$TMP_TGZ"

if [[ "$RUNNING" == "active" ]]; then
  echo ""
  log "🎉 升级成功！"
  log "   新版本已运行"
  log "   备份文件: $BACKUP_FILE"
  echo ""
  log "📝 接下来:"
  log "   1. 浏览器硬刷新面板 (Ctrl+Shift+R)"
  log "   2. 进 Inbounds → 编辑入站 → 看到 'Traffic multiplier' 字段"
  log "   3. 不需要改 = 1.0（行为不变）；需要时填倍率"
else
  err "服务未启动！自动回滚..."
  cp -f "$BACKUP_FILE" "$XUI_BIN"
  [[ -d "$BIN_BACKUP_DIR" ]] && cp -af "$BIN_BACKUP_DIR"/* "$XUI_DIR/bin/" 2>/dev/null || true
  start_svc || true
  echo ""
  err "回滚完成。请查日志："
  echo "----- 日志 -----"
  logs_tail
  echo "---------------"
  echo ""
  err "回滚命令（手动）："
  echo "  sudo cp $BACKUP_FILE $XUI_BIN"
  echo "  sudo $0 --tag $TAG  # 或联系作者排查"
  exit 1
fi