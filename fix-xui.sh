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
# 4a. 没有 sqlite3 就装
if ! command -v sqlite3 >/dev/null 2>&1; then
  warn "未检测到 sqlite3 — 尝试自动安装"
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache sqlite 2>&1 | tail -3
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get install -y sqlite3 2>&1 | tail -3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sqlite 2>&1 | tail -3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y sqlite 2>&1 | tail -3
  fi
  command -v sqlite3 >/dev/null 2>&1 && ok "sqlite3 安装成功" || warn "sqlite3 安装失败 — 继续用常见端口猜测"
fi

port=""
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
  port=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='port' LIMIT 1;" 2>/dev/null)
  if [ -n "$port" ]; then
    ok "从数据库读出 panel 端口: $port"
  fi
fi

# 4b. 候选端口列表：DB 端口 + 解析 x-ui 自身日志里的 [::]:PORT + 常见兜底
LOG_CAND=""
for f in /var/log/messages /var/log/syslog /usr/local/x-ui/x-ui.log /var/log/x-ui.log; do
  [ -r "$f" ] || continue
  # 抓 "Web server running HTTP on [::]:NNNNN" 这类
  hits=$(grep -oE 'Web server running HTTP on \[::\]:[0-9]+' "$f" 2>/dev/null | tail -3 | grep -oE '[0-9]+$')
  if [ -n "$hits" ]; then
    LOG_CAND="$hits"
    break
  fi
done

candidates=""
for src in "$port" $LOG_CAND 2053 2083 2087 2095 2096 54321 80 443; do
  case " $candidates " in *" $src "*) ;; *) [ -n "$src" ] && candidates="$candidates $src";; esac
done

# 4c. 试到真 HTTP 响应（2xx/3xx/4xx/5xx 都算"连接成功"，000/无 = 失败）
echo "--- 端口连通性测试（候选：${candidates}）---"
REACHABLE=""
for p in $candidates; do
  for i in 1 2 3; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$p/" 2>/dev/null)
    case "$code" in
      2*|3*|4*|5*)
        ok "  :$p → HTTP $code ✅"
        [ -z "$REACHABLE" ] && REACHABLE="$p:$code"
        break ;;
      *)
        [ "$i" = "3" ] && printf '  :%s → 无响应\n' "$p"
        ;;
    esac
    sleep 1
  done
done

if [ -n "$REACHABLE" ]; then
  ok "面板可达: http://127.0.0.1:${REACHABLE%:*}/"
else
  err "未能连接 panel — 进程在跑但所有候选端口无响应"
  err "可能原因：面板绑到非 127.0.0.1、数据库被破坏、x-ui 启动未完全"
fi

echo "===== [5/5] 关键日志（最后 30 行）====="
for f in /var/log/x-ui.log /usr/local/x-ui/x-ui.log /var/log/messages; do
  [ -r "$f" ] && { echo "--- $f ---"; tail -n 30 "$f"; break; }
done

echo "===== 完毕 ====="
echo "如仍未恢复：可一键回滚到上次成功的备份"
ls -t /var/backups/x-ui-multiplier/x-ui.bak.* 2>/dev/null | head -1