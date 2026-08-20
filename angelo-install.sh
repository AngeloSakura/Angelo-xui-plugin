#!/usr/bin/env bash
# angelo-install.sh
# Angelo-xui-plugin 一键部署统一入口
# 用法（与原版 3x-ui install.sh 风格一致）:
#   bash <(curl -Ls https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/angelo-install.sh) v0.2
#
#   # 升级已有 3x-ui:
#   bash <(curl -Ls ...angelo-install.sh) v0.2 --update
#
#   # 全新安装（默认，检测到已有 x-ui 会自动切换为 --update 并提示）:
#   bash <(curl -Ls ...angelo-install.sh) v0.2
#
# 可选参数:
#   --repo <owner/repo>      GitHub 仓库 (默认 AngeloSakura/Angelo-xui-plugin)
#   --update / --upgrade     强制走升级模式
#   --fresh / --install      强制走全新安装模式
#   -h / --help              帮助
#
# 自动检测:
#   - 如果 /usr/local/x-ui/x-ui 已存在 → 默认升级模式
#   - 否则 → 全新安装模式
set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
plain='\033[0m'

REPO="AngeloSakura/Angelo-xui-plugin"
TAG=""
MODE="auto"   # auto | fresh | update

usage() {
  cat <<EOF
${green}Angelo-xui-plugin 一键部署${plain}

用法:
  bash <(curl -Ls https://raw.githubusercontent.com/${REPO}/main/angelo-install.sh) <version> [options]

参数:
  <version>                 版本标签 (例 v0.2, v0.3-rc1, dev-latest)

选项:
  --update / --upgrade      强制升级模式（替换现有 x-ui 二进制）
  --fresh / --install       强制全新安装模式（从零部署）
  --repo <owner/repo>       GitHub 仓库 (默认 ${REPO})
  -h / --help               显示此帮助

默认行为:
  检测到现有 x-ui → 自动升级
  未检测到 x-ui   → 自动全新安装
EOF
  exit 0
}

# ---------- 参数解析 ----------
# 第一个非 flag 参数当作 TAG
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update|--upgrade) MODE="update"; shift ;;
    --fresh|--install) MODE="fresh"; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo -e "${red}未知参数: $1${plain}"; usage ;;
    *)  ARGS+=("$1"); shift ;;
  esac
done

if [[ ${#ARGS[@]} -gt 0 ]]; then
  TAG="${ARGS[0]}"
fi

if [[ -z "$TAG" ]]; then
  echo -e "${red}❌ 必须指定版本标签${plain}"
  echo "   例: bash <(curl -Ls .../angelo-install.sh) v0.2"
  exit 1
fi

# ---------- 自动模式判断 ----------
if [[ "$MODE" == "auto" ]]; then
  if [[ -x /usr/local/x-ui/x-ui ]] || [[ -x /usr/local/x-ui/bin/x-ui ]] || [[ -x /usr/bin/x-ui ]]; then
    MODE="update"
  else
    MODE="fresh"
  fi
fi

echo ""
echo -e "${blue}====================================================${plain}"
echo -e "${green} Angelo-xui-plugin 部署${plain}"
echo -e " 版本:   ${TAG}"
echo -e " 仓库:   ${REPO}"
echo -e " 模式:   ${MODE}"
echo -e "===================================================="
echo ""

# ---------- 拉取并调用子脚本 ----------
# 子脚本通过 GIST 风格的下载链接拉取（不走 GitHub raw，避免缓存）
BASE_URL="https://raw.githubusercontent.com/${REPO}/main"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$MODE" == "fresh" ]]; then
  SUB="install-fresh.sh"
else
  SUB="update.sh"
fi

echo -e "${yellow}⬇️  下载子脚本: ${SUB}${plain}"
if ! curl -fsSL --retry 3 -o "$TMP_DIR/$SUB" "$BASE_URL/$SUB"; then
  echo -e "${red}❌ 下载子脚本失败: $BASE_URL/$SUB${plain}"
  exit 1
fi
chmod +x "$TMP_DIR/$SUB"

# 把 TAG 和 REPO 透传过去
exec bash "$TMP_DIR/$SUB" --tag "$TAG" --repo "$REPO"