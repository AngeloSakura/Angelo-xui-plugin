#!/usr/bin/env bash
# install-multiplier.sh
# Angelo-xui-plugin 一键安装脚本
# 用法:
#   curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/install-multiplier.sh | sudo bash -s -- --tag v0.1
#   curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/install-multiplier.sh | sudo bash -s -- --tag v0.1 --repo AngeloSakura/Angelo-xui-plugin
#
# 功能:
#   1. 自动检测架构 (amd64 / arm64 / armv7)
#   2. 自动检测操作系统 (debian / alpine / rhel / ...) + 包管理器
#   3. 自动检测 init 系统 (systemd / OpenRC / runit / sysvinit)
#   4. 按 init 系统探测 x-ui 真实路径（不靠 which）
#   5. 从 GitHub Release 下载对应 tarball
#   6. 备份并替换二进制；镜像到所有候选位置
#   7. 用对应 init 命令启停（systemctl / rc-service / sv / service）
#   8. 验证数据库 traffic_multiplier 列已自动添加
#   9. 出错自动回滚
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

# ---------- 操作系统 + 包管理器 + init 系统 探测 ----------
OS_ID="unknown"
PKG_MGR="unknown"
for f in /etc/os-release /etc/lsb-release /etc/alpine-release /etc/redhat-release /etc/debian_version; do
  if [[ -f "$f" ]]; then
    case "$f" in
      /etc/os-release)   OS_ID=$(. "$f" 2>/dev/null && echo "${ID:-unknown}") ;;
      /etc/alpine-release) OS_ID="alpine" ;;
      /etc/redhat-release) OS_ID="rhel" ;;
      /etc/debian_version)  OS_ID="debian" ;;
    esac
    break
  fi
done
command -v apk    >/dev/null && PKG_MGR="apk"
command -v apt-get >/dev/null && PKG_MGR="apt"
command -v dnf    >/dev/null && PKG_MGR="dnf"
command -v yum    >/dev/null && PKG_MGR="yum"
command -v pacman >/dev/null && PKG_MGR="pacman"
echo "✅ 操作系统: $OS_ID  包管理器: $PKG_MGR"

INIT_SYS="none"
if     command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then INIT_SYS="systemd"
elif   [[ -f /sbin/openrc-run ]] || command -v openrc-run >/dev/null 2>&1;       then INIT_SYS="openrc"
elif   [[ -d /etc/sv ]] && command -v sv >/dev/null 2>&1;                         then INIT_SYS="runit"
elif   command -v service >/dev/null 2>&1 && [[ -f /etc/init.d/x-ui ]];          then INIT_SYS="sysvinit"
fi
echo "✅ Init 系统: $INIT_SYS"

service_start() {
  case "$INIT_SYS" in
    systemd)   systemctl start x-ui ;;
    openrc)    rc-service x-ui start ;;
    runit)     sv start x-ui 2>/dev/null || sv up x-ui ;;
    sysvinit)  service x-ui start ;;
    none)      return 1 ;;
  esac
}
service_stop() {
  case "$INIT_SYS" in
    systemd)   systemctl stop x-ui ;;
    openrc)    rc-service x-ui stop ;;
    runit)     sv stop x-ui 2>/dev/null || sv down x-ui ;;
    sysvinit)  service x-ui stop ;;
    none)      return 1 ;;
  esac
}
service_status() {
  case "$INIT_SYS" in
    systemd)   systemctl is-active x-ui 2>/dev/null ;;
    openrc)    rc-service x-ui status 2>&1 | grep -q started && echo active || echo inactive ;;
    runit)     sv status x-ui 2>/dev/null | head -1 ;;
    sysvinit)  service x-ui status 2>&1 | head -1 ;;
    none)      return 1 ;;
  esac
}
unit_binary() {
  # Read the binary the running service actually execs.
  case "$INIT_SYS" in
    systemd)
      systemctl cat x-ui 2>/dev/null \
        | grep -m1 -oP 'ExecStart=\K\S+' \
        | sed -E 's/[[:space:]]+run.*//; s/[[:space:]]+x-ui.*//'
      ;;
    openrc)
      [[ -f /etc/init.d/x-ui ]] && grep -m1 -E '^command=' /etc/init.d/x-ui | sed -E 's/^command="?([^"[:space:]]+).*/\1/'
      ;;
    runit)
      [[ -f /etc/sv/x-ui/run ]] && grep -m1 -oE '/[^ ]*x-ui' /etc/sv/x-ui/run
      ;;
    sysvinit)
      [[ -f /etc/init.d/x-ui ]] && grep -m1 -E '^(DAEMON|BINARY|PROGRAM)=' /etc/init.d/x-ui \
        | sed -E 's/.*="?([^"[:space:]]+x-ui[^"[:space:]]*).*/\1/' | head -1
      ;;
  esac
}

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
# Init system first → it tells us where the live binary really lives.
# /usr/bin/x-ui on Debian/Ubuntu is sometimes a wrapper, sometimes the real
# thing — never trust which(1) when a unit / OpenRC script disagrees.
XUI_BIN=""
if svc_bin=$(unit_binary) && [[ -n "$svc_bin" && -x "$svc_bin" ]]; then
  XUI_BIN="$svc_bin"
fi
if [[ -z "$XUI_BIN" ]] && command -v x-ui >/dev/null; then
  cand=$(command -v x-ui)
  if [[ -L "$cand" ]]; then
    target=$(readlink -f "$cand" 2>/dev/null || true)
    [[ -n "$target" && -x "$target" ]] && cand="$target"
  fi
  XUI_BIN="$cand"
fi
if [[ -z "$XUI_BIN" ]]; then
  for candidate in /usr/local/x-ui/x-ui /usr/local/x-ui/bin/x-ui /usr/bin/x-ui /opt/x-ui/bin/x-ui; do
    if [[ -x "$candidate" ]]; then
      XUI_BIN="$candidate"
      break
    fi
  done
fi

if [[ -z "$XUI_BIN" ]]; then
  echo "❌ 找不到 x-ui 二进制。常见路径:"
  echo "   /usr/local/x-ui/x-ui"
  echo "   /usr/local/x-ui/bin/x-ui"
  echo "   /usr/bin/x-ui"
  echo "   请先安装原版 3x-ui 后再运行此脚本"
  exit 1
fi
echo "✅ 找到 x-ui: $XUI_BIN"

XUI_DIR=$(dirname "$XUI_BIN")
echo "   安装目录: $XUI_DIR"

# Mirror targets: every place a binary called "x-ui" might answer `x-ui`,
# `which`, the unit, or the OpenRC script. Replacing only XUI_BIN left
# hybrid installs (wrapper + real) half-upgraded — patch all of them.
MIRROR_TARGETS=("$XUI_BIN")
for cand in /usr/local/x-ui/x-ui /usr/local/x-ui/bin/x-ui /usr/bin/x-ui /opt/x-ui/bin/x-ui; do
  [[ -e "$cand" || -L "$cand" ]] && MIRROR_TARGETS+=("$cand")
done
# Dedup while preserving order.
declare -A _seen=()
MIRROR_DEDUP=()
for t in "${MIRROR_TARGETS[@]}"; do
  [[ -z "${_seen[$t]:-}" ]] && { MIRROR_DEDUP+=("$t"); _seen["$t"]=1; }
done
MIRROR_TARGETS=("${MIRROR_DEDUP[@]}")

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
# tarball 解压出的是 x-ui/ 目录；真正的二进制在 x-ui/x-ui
NEW_BIN="$TMP_DIR/x-ui/x-ui"

if [[ ! -x "$NEW_BIN" ]]; then
  echo "❌ 解压后找不到 x-ui 二进制"
  ls -la "$TMP_DIR"
  ls -la "$TMP_DIR/x-ui" 2>/dev/null
  exit 1
fi

# ---------- 停止服务 ----------
SERVICE_WAS_ACTIVE=false
if [[ "$INIT_SYS" != "none" ]] && service_status 2>/dev/null | grep -qiE 'active|run|up|started'; then
  SERVICE_WAS_ACTIVE=true
fi

if [[ "$INIT_SYS" != "none" ]]; then
  echo "⏸️  通过 $INIT_SYS 停止 x-ui..."
  service_stop || true
else
  echo "⚠️  未检测到 init 系统，尝试直接 kill 旧进程..."
  pkill -f "$(basename "$XUI_BIN")" 2>/dev/null || true
  sleep 1
fi

# ---------- 替换（镜像到所有候选位置） ----------
echo "🔄 替换二进制到: ${MIRROR_TARGETS[*]}"
chmod +x "$NEW_BIN"
REPLACE_OK=true
for target in "${MIRROR_TARGETS[@]}"; do
  # Skip non-regular files (e.g. broken symlinks to absent paths).
  if [[ -e "$target" || -L "$target" ]]; then
    if ! cp -f "$NEW_BIN" "$target"; then
      echo "❌ 替换 $target 失败，尝试回滚..."
      cp -f "$BACKUP_PATH" "$XUI_BIN"
      REPLACE_OK=false
      break
    fi
  else
    # Brand-new install: place it where the unit will look for it.
    mkdir -p "$(dirname "$target")"
    cp -f "$NEW_BIN" "$target"
  fi
done
[[ "$REPLACE_OK" == false ]] && exit 1

# ---------- 启动 ----------
if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
  echo "▶️  通过 $INIT_SYS 启动 x-ui..."
  service_start || echo "⚠️  启动失败，请用 '$INIT_SYS' 的命令手动启动"
elif [[ "$INIT_SYS" != "none" ]]; then
  echo "▶️  通过 $INIT_SYS 启动 x-ui（之前未在跑）..."
  service_start || echo "⚠️  启动失败，请手动启动"
else
  echo "⚠️  未找到 init 系统，请手动启动 x-ui"
fi

# ---------- 等待并验证 ----------
echo "⏳ 等待服务就绪..."
sleep 5

VER_INSTALLED=$("$XUI_BIN" version 2>/dev/null | head -1 || echo "unknown")
echo "✅ 已安装版本: $VER_INSTALLED"

# ---------- 数据库迁移：检测 sqlite3，装；不行则走 x-ui migrate-db 兜底 ----------
echo ""
echo "🔍 检查/准备数据库迁移工具..."

ensure_sqlite3() {
  if command -v sqlite3 >/dev/null 2>&1; then
    echo "✅ sqlite3 已安装: $(sqlite3 -version | head -1)"
    return 0
  fi
  echo "ℹ️  未检测到 sqlite3，尝试自动安装..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 && return 0
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sqlite && return 0
  elif command -v yum >/dev/null 2>&1; then
    yum install -y sqlite && return 0
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache sqlite && return 0
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm sqlite && return 0
  fi
  echo "⚠️  未能自动安装 sqlite3（包管理器未识别）"
  return 1
}

ensure_sqlite3 || echo "   → 后续将跳过 sqlite3 验证，改用 x-ui migrate-db 兜底"

DB_PATH=""
for candidate in /etc/x-ui/x-ui.db /usr/local/x-ui/db/x-ui.db /var/lib/x-ui/x-ui.db; do
  if [[ -f "$candidate" ]]; then
    DB_PATH="$candidate"
    break
  fi
done

if [[ -z "$DB_PATH" ]]; then
  echo "⚠️  找不到数据库文件，跳过迁移验证（面板正常访问 = 启动成功）"
else
  HAS_COL=false
  if command -v sqlite3 >/dev/null 2>&1; then
    if sqlite3 "$DB_PATH" "PRAGMA table_info(inbounds);" 2>/dev/null | grep -q "traffic_multiplier"; then
      HAS_COL=true
    fi
  fi

  if [[ "$HAS_COL" == true ]]; then
    echo "✅ 数据库已包含 traffic_multiplier 列"
  else
    echo "ℹ️  数据库缺 traffic_multiplier 列，调用 x-ui migrate-db 补齐..."
    if command -v x-ui >/dev/null 2>&1; then
      if x-ui migrate-db 2>&1 | tee -a "$LOG_FILE"; then
        echo "✅ migrate-db 完成"
      else
        echo "⚠️  x-ui migrate-db 返回非零，继续启动（启动时 GORM AutoMigrate 会兜底）"
      fi
    else
      echo "⚠️  没 x-ui 命令且没 sqlite3，跳过显式迁移。Go 进程首次启动会跑 GORM AutoMigrate 兜底"
    fi
    sleep 2
    if command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB_PATH" "PRAGMA table_info(inbounds);" 2>/dev/null | grep -q "traffic_multiplier"; then
        echo "✅ 迁移后数据库已包含 traffic_multiplier 列"
      else
        echo "⚠️  仍检测不到该列 — 进面板 Inbounds 编辑入站确认是否出现 'Traffic multiplier' 字段"
      fi
    fi
  fi
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
echo " 如已存在旧数据入站: 把倍率从默认 1 改成你想要的倍率即可，无需重启"
echo ""
echo " 如需回滚:"
echo "   sudo cp $BACKUP_PATH $XUI_BIN"
case "$INIT_SYS" in
  systemd)  echo "   sudo systemctl restart x-ui" ;;
  openrc)   echo "   sudo rc-service x-ui restart" ;;
  runit)    echo "   sudo sv restart x-ui" ;;
  sysvinit) echo "   sudo service x-ui restart" ;;
  none)     echo "   （未检测到 init 系统，请手动重启 x-ui）" ;;
esac
echo ""