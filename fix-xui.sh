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

echo "===== [4/5] 等待面板启动 ====="
LISTEN_LINE=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  sleep 1
  for f in /var/log/messages /var/log/syslog /usr/local/x-ui/x-ui.log /var/log/x-ui.log; do
    [ -r "$f" ] || continue
    LISTEN_LINE=$(tail -n 50 "$f" 2>/dev/null | grep -E 'Web server running HTTP on' | tail -1)
    if [ -n "$LISTEN_LINE" ]; then break 2; fi
  done
done

if [ -n "$LISTEN_LINE" ]; then
  ok "$LISTEN_LINE"
else
  warn "15 秒内未在日志中看到 Web server running — x-ui 可能仍在启动或启动失败"
fi

echo "===== [5/5] 关键日志（最后 15 行）====="
for f in /var/log/messages /var/log/syslog /usr/local/x-ui/x-ui.log /var/log/x-ui.log; do
  if [ -r "$f" ]; then
    echo "--- $f ---"
    grep -E 'x-ui|xray|Web server|Sub server|ERROR|FATAL|panic' "$f" 2>/dev/null | tail -n 15
    break
  fi
done

echo "===== 完毕 ====="
echo "服务状态: rc-service x-ui status"
echo "如需回滚:  cp /var/backups/x-ui-multiplier/x-ui.bak.<时间戳> /usr/local/x-ui/x-ui && rc-service x-ui restart"