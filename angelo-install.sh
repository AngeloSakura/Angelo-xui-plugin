#!/usr/bin/env bash
# angelo-install.sh — Angelo-xui-plugin 一键入口
# 用法:
#   bash <(curl -Ls .../angelo-install.sh) dev-latest           # 自动检测 fresh/update
#   bash <(curl -Ls .../angelo-install.sh) dev-latest --update
#   bash <(curl -Ls .../angelo-install.sh) dev-latest --fresh
set -euo pipefail

REPO="AngeloSakura/Angelo-xui-plugin"
VERSION="${1:-}"
if [[ -n "$VERSION" ]]; then shift; fi

MODE="auto"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update) MODE="update"; shift ;;
    --fresh)  MODE="fresh";  shift ;;
    --repo)   REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "❌ 必须指定版本: bash <(curl -Ls ...) dev-latest"
  exit 1
fi

# 自动检测
if [[ "$MODE" == "auto" ]]; then
  if [[ -x /usr/local/x-ui/x-ui ]] || [[ -x /usr/local/x-ui/bin/x-ui ]] || [[ -x /usr/bin/x-ui ]]; then
    MODE="update"
  else
    MODE="fresh"
  fi
fi

echo "===================================================="
echo " Angelo-xui-plugin 部署"
echo " 版本: $VERSION"
echo " 仓库: $REPO"
echo " 模式: $MODE"
echo "===================================================="

case "$MODE" in
  fresh)
    echo "⬇️  拉取 install-fresh.sh"
    exec bash -c "curl -fsSL 'https://raw.githubusercontent.com/${REPO}/main/install-fresh.sh' | bash -s -- --tag '${VERSION}'"
    ;;
  update)
    echo "⬇️  拉取 update.sh"
    exec bash -c "curl -fsSL 'https://raw.githubusercontent.com/${REPO}/main/update.sh' | bash -s -- --tag '${VERSION}'"
    ;;
esac
