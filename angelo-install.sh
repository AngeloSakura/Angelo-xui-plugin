#!/usr/bin/env bash
# angelo-install.sh
# Angelo-xui-plugin 统一入口（自动检测 fresh / update）
# 兼容 Alpine / Debian / RHEL
#
# 用法:
#   bash <(curl -Ls .../angelo-install.sh) <version>            # 自动检测
#   bash <(curl -Ls .../angelo-install.sh) <version> --fresh    # 强制全新安装
#   bash <(curl -Ls .../angelo-install.sh) <version> --update   # 强制升级
#   bash <(curl -Ls .../angelo-install.sh) dev-latest           # dev channel
set -euo pipefail

REPO="AngeloSakura/Angelo-xui-plugin"
VERSION="${1:-}"
MODE=""   # fresh | update | auto

# 颜色
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[1;33m'; blue='\033[0;34m'; plain='\033[0m'

# ---------- 参数解析 ----------
# 第一个位置参数是版本（可省，省时下面退出）
# 其余是开关
VERSION="${1:-}"
if [[ -n "$VERSION" ]]; then shift; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh)  MODE="fresh"; shift ;;
    --update) MODE="update"; shift ;;
    --repo)   REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo -e "${red}❌ 必须指定版本: bash <(curl -Ls ...) v0.2 或 dev-latest${plain}"
  exit 1
fi

# ---------- 检测 ----------
if [[ -x /usr/local/x-ui/x-ui ]] || [[ -x /usr/local/x-ui/bin/x-ui ]] || [[ -x /usr/bin/x-ui ]]; then
  HAS_XUI=1
else
  HAS_XUI=0
fi

if [[ -z "$MODE" ]]; then
  if [[ "$HAS_XUI" -eq 1 ]]; then MODE="update"; else MODE="fresh"; fi
fi

echo -e "${blue}====================================================${plain}"
echo -e "${green} Angelo-xui-plugin 部署${plain}"
echo " 版本:   $VERSION"
echo " 仓库:   $REPO"
echo " 模式:   $MODE"
echo " x-ui 已安装: $([[ "$HAS_XUI" -eq 1 ]] && echo "yes" || echo "no")"
echo -e "${blue}====================================================${plain}"

SCRIPT_BASE="https://cdn.jsdelivr.net/gh/${REPO}@main"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
fetch_and_exec() {
  local sub="$1"
  local out="/tmp/angelo-${sub}"
  # 1) jsDelivr 优先（CDN 国内快，但偶发 500）
  if curl -fsSL --max-time 20 --retry 2 "$SCRIPT_BASE/${sub}" -o "$out"; then
    echo "✅ 通过 jsDelivr 拉取 ${sub}"
  elif curl -fsSL --max-time 20 --retry 2 "$RAW_BASE/${sub}" -o "$out"; then
    echo "✅ jsDelivr 失败，回退到 raw 拉取 ${sub}"
  else
    echo "❌ jsDelivr 和 raw 都不通"
    exit 1
  fi
  chmod +x "$out"
  bash "$out" --tag "${VERSION}"
}
case "$MODE" in
  fresh)  fetch_and_exec install-fresh.sh ;;
  update) fetch_and_exec update.sh ;;
esac