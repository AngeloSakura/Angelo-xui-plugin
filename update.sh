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
    openrc)
      # 优先级: x-ui.log → /usr/local/x-ui/x-ui.log → /var/log/messages
      for f in /var/log/x-ui.log /usr/local/x-ui/x-ui.log /var/log/messages /var/log/syslog; do
        if [[ -r "$f" ]]; then
          echo "--- $f ---"
          tail -n 30 "$f"
          break
        fi
      done
      ;;
    *)       "$XUI_BIN" log 2>/dev/null | tail -50 || echo "无日志" ;;
  esac
}

# ---------- 日志双写 ----------
# /tmp 在小磁盘或配额 VPS 上可能写不进去（出现 tee: I/O error）。
# 把所有输出同时写到 /var/log/x-ui-update.log 作为兜底，
# 用户事后总能 cat 到这次升级的完整输出。
LOG_FILE="${LOG_FILE:-/var/log/x-ui-update.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="$XUI_DIR/x-ui-update.log"
if [[ -w "$LOG_FILE" ]] || (touch "$LOG_FILE" 2>/dev/null); then
  exec > >(while IFS= read -r line; do printf '%s\n' "$line"; printf '%s\n' "$line" >>"$LOG_FILE"; done) 2>&1
fi

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
mkdir -p "$BACKUP_DIR" 2>/dev/null || BACKUP_DIR="$XUI_DIR/.bak"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/x-ui.bak.$STAMP"
if cp -f "$XUI_BIN" "$BACKUP_FILE" 2>/dev/null && chmod +x "$BACKUP_FILE"; then
  log "✅ 已备份原二进制到: $BACKUP_FILE"
else
  warn "⚠️  备份失败($BACKUP_FILE) — 继续升级（旧二进制未保留）"
  BACKUP_FILE=""
fi

# 备份 bin/ 下资源（xray/dat/mtg），如果存在
BIN_BACKUP_DIR="$BACKUP_DIR/bin.$STAMP"
if [[ -d "$XUI_DIR/bin" ]]; then
  if cp -a "$XUI_DIR/bin" "$BIN_BACKUP_DIR" 2>/dev/null; then
    log "✅ 已备份 bin/ 到: $BIN_BACKUP_DIR"
  else
    warn "⚠️  bin/ 备份失败 — 继续升级"
  fi
fi

# 自动修剪旧备份：x-ui.bak.* 保留最近 3 份；bin.* 保留最近 2 份
if [[ -d "$BACKUP_DIR" ]]; then
  ls -t "$BACKUP_DIR"/x-ui.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f
  ls -dt "$BACKUP_DIR"/bin.* 2>/dev/null | tail -n +3 | xargs -r rm -rf
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

# ---------- 修补 openrc init 脚本（Angelo fork 需要 `run` 子命令）----------
if [[ "$INIT" == "openrc" && -f /etc/init.d/x-ui ]]; then
  if ! grep -q '^command_args="run"' /etc/init.d/x-ui; then
    warn "⚠️  /etc/init.d/x-ui 缺少 command_args=\"run\" — Angelo fork 需要它"
    if cp -a /etc/init.d/x-ui "/etc/init.d/x-ui.bak.$(date +%s)" 2>/dev/null \
       && sed -i 's|^command="\(.*x-ui\)"$|command="\1"\ncommand_args="run"\ndirectory="/usr/local/x-ui"|' /etc/init.d/x-ui \
       && rc-service x-ui restart 2>/dev/null; then
      sleep 2
      if svc_status | grep -q active; then
        log "✅ init 脚本修补完成，服务已重启"
      else
        warn "⚠️  init 修补后服务仍异常，请查 rc-service x-ui status"
      fi
    else
      warn "⚠️  init 修补失败 — 请手工编辑 /etc/init.d/x-ui 加 command_args=\"run\""
    fi
  fi
fi

rm -rf "$TMP_DIR" "$TMP_TGZ"

if [[ "$RUNNING" == "active" ]]; then
  # ---------- 等待 x-ui 写 "Web server running HTTP on" 到日志 ----------
  # x-ui 启动到监听实际端口需要 1-3s（DB 加载 + TLS 初始化）；
  # openrc 的 status: started 只代表 start-stop-daemon 跑了 fork 出来，
  # 不代表面板真的在 listen。所以不靠 curl，靠 x-ui 自己写的日志行。
  LISTEN=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    case "$INIT" in
      systemd)
        LISTEN=$(journalctl -u x-ui --no-pager -n 50 2>/dev/null | grep -E 'Web server running HTTP on' | tail -1) ;;
      openrc)
        for f in /var/log/messages /var/log/syslog /usr/local/x-ui/x-ui.log /var/log/x-ui.log; do
          [ -r "$f" ] || continue
          LISTEN=$(tail -n 50 "$f" 2>/dev/null | grep -E 'Web server running HTTP on' | tail -1)
          [ -n "$LISTEN" ] && break
        done ;;
      *)
        LISTEN=$("$XUI_BIN" log 2>/dev/null | grep -E 'Web server running HTTP on' | tail -1) ;;
    esac
    [[ -n "$LISTEN" ]] && break
  done

  if [[ -n "$LISTEN" ]]; then
    log "✅ $LISTEN"
  else
    warn "⚠️  15 秒内未在日志中看到 Web server running — 进程启动但面板未就绪"
  fi

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