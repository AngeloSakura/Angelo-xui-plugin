#!/bin/sh
# Angelo-xui-plugin 一键：诊断 + 恢复
# 适用: openrc + /usr/local/x-ui + Angelo fork + /tmp 配额

set +e
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*"; }

[ "$(id -u)" -ne 0 ] && { err "需要 root: sudo $0"; exit 1; }

XUI_BIN=/usr/local/x-ui/x-ui
XUI_DIR=/usr/local/x-ui
INIT_D=/etc/init.d/x-ui
DB=/etc/x-ui/x-ui.db

[ ! -x "$XUI_BIN" ] && { err "找不到 $XUI_BIN"; exit 1; }

echo "===== [1/5] 修补 init 脚本 ====="
if [ -f "$INIT_D" ] && ! grep -q '^command_args="run"' "$INIT_D"; then
  cp -a "$INIT_D" "$INIT_D.bak.$(date +%s)" 2>/dev/null
  sed -i 's|^command="\(.*x-ui\)"$|command="\1"\ncommand_args="run"\ndirectory="/usr/local/x-ui"|' "$INIT_D"
  ok "init 脚本已修补"
else
  ok "init 脚本已是最新"
fi

echo "===== [2/5] 重启服务 ====="
rc-service x-ui restart 2>&1 || /etc/init.d/x-ui restart 2>&1
sleep 3

echo "===== [3/5] 健康检查 ====="
status=$(rc-service x-ui status 2>&1)
echo "$status"
echo "$status" | grep -q 'started' && ok "服务已 started" || { err "服务未 started"; }

echo "===== [4/5] 读面板端口 + curl 自检 ====="
port=""
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
  port=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='port' LIMIT 1;" 2>/dev/null)
fi
if [ -z "$port" ]; then
  warn "无法读出 panel 端口（无 sqlite3 或 DB 不存在），尝试常见端口"
  for p in 2053 2083 2087 2095 54321; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$p/" 2>/dev/null)
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      port=$p; ok "尝试到 $p → $code"; break
    fi
  done
fi
if [ -n "$port" ]; then
  for i in 1 2 3 4 5 6 7 8; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port/" 2>/dev/null)
    echo "  尝试 :$port ($i/8) → ${code:-无}"
    case "$code" in
      2*|3*|4*|5*) ok "面板可达: HTTP $code on :$port"; break ;;
    esac
    sleep 1
  done
else
  warn "未找到可用端口，请检查数据库设置"
fi

echo "===== [5/5] 关键日志（最后 30 行）====="
for f in /var/log/x-ui.log /usr/local/x-ui/x-ui.log /var/log/messages; do
  [ -r "$f" ] && { echo "--- $f ---"; tail -n 30 "$f"; break; }
done

echo "===== 完毕 ====="
echo "如仍未恢复：可一键回滚到上次成功的备份"
ls -t /var/backups/x-ui-multiplier/x-ui.bak.* 2>/dev/null | head -1