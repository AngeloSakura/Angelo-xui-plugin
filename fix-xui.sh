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

echo "===== [1/6] 修补 init 脚本 ====="
if [ -f "$INIT_D" ] && ! grep -q '^command_args="run"' "$INIT_D"; then
  cp -a "$INIT_D" "$INIT_D.bak.$(date +%s)" 2>/dev/null
  sed -i 's|^command="\(.*x-ui\)"$|command="\1"\ncommand_args="run"\ndirectory="/usr/local/x-ui"|' "$INIT_D"
  ok "init 脚本已修补"
else
  ok "init 脚本已是最新"
fi

echo "===== [2/6] 数据库 schema 兜底 ====="
# Angelo fork 的 model.Inbound 多了一个 traffic_multiplier 列。
# GORM AutoMigrate 在 x-ui 启动时本应补上，但若进程起不来、
# DB 路径不对、或二进制与 DB schema 版本不一致，老库就缺这一列，
# 下次启动会 panic (sql: missing destination name traffic_multiplier)。
# 用 sqlite3 主动 ALTER TABLE 兜底，无 sqlite3 就先装；装不到也不中断主流程。
INSTALLED_BY=""
if ! command -v sqlite3 >/dev/null 2>&1; then
  INSTALL_OUT=""
  if command -v apk >/dev/null 2>&1; then
    INSTALL_OUT=$(apk add --no-cache sqlite 2>&1) && INSTALLED_BY="apk"
  elif command -v apt-get >/dev/null 2>&1; then
    INSTALL_OUT=$(apt-get install -y sqlite3 2>&1) && INSTALLED_BY="apt-get"
  elif command -v dnf >/dev/null 2>&1; then
    INSTALL_OUT=$(dnf install -y sqlite 2>&1) && INSTALLED_BY="dnf"
  elif command -v yum >/dev/null 2>&1; then
    INSTALL_OUT=$(yum install -y sqlite 2>&1) && INSTALLED_BY="yum"
  fi
  if [ -n "$INSTALLED_BY" ] && command -v sqlite3 >/dev/null 2>&1; then
    ok "已装 sqlite3 ($INSTALLED_BY)"
  else
    warn "自动装 sqlite3 失败 — 跳过 schema 兜底，依靠 x-ui 启动时 GORM AutoMigrate"
    [ -n "$INSTALL_OUT" ] && echo "$INSTALL_OUT" | sed 's/^/    | /'
    echo "    你也可以手动装："
    echo "      Alpine:   apk add --no-cache sqlite"
    echo "      Debian:   apt-get install -y sqlite3"
    echo "      RHEL/Fedora: dnf install -y sqlite   (或 yum install -y sqlite)"
    echo "    或者直接用 busybox 自带的 sqlite (少数精简镜像):  busybox --list 2>/dev/null | grep -i sql"
  fi
fi

if command -v sqlite3 >/dev/null 2>&1; then
  for db in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db "$XUI_DIR/x-ui.db"; do
    [ -f "$db" ] || continue
    # 查 inbounds 表是否存在 + 是否已有 traffic_multiplier 列
    tbl=$(sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='inbounds' LIMIT 1;" 2>/dev/null)
    if [ -z "$tbl" ]; then
      warn "$db 没有 inbounds 表 — 跳过（新建或非 Angelo fork）"
      continue
    fi
    has=$(sqlite3 "$db" "PRAGMA table_info(inbounds);" 2>/dev/null | awk -F'|' '$2=="traffic_multiplier"{print $2}')
    if [ -z "$has" ]; then
      sqlite3 "$db" "ALTER TABLE inbounds ADD COLUMN traffic_multiplier REAL NOT NULL DEFAULT 1.0;" 2>&1
      if [ $? -eq 0 ]; then
        ok "$db: inbounds.traffic_multiplier 已补上 (default 1.0)"
      else
        warn "$db: ALTER TABLE 失败 — x-ui 启动时 GORM AutoMigrate 会再尝试"
      fi
    else
      ok "$db: inbounds.traffic_multiplier 已存在"
    fi
  done
else
  warn "sqlite3 不可用 — 跳过 schema 兜底，依靠 x-ui 启动时 AutoMigrate"
fi

echo "===== [3/6] 重启服务 ====="
rc-service x-ui restart 2>&1 || /etc/init.d/x-ui restart 2>&1
sleep 3

echo "===== [4/6] 健康检查 ====="
status=$(rc-service x-ui status 2>&1)
echo "$status"
echo "$status" | grep -q 'started' && ok "服务已 started" || { err "服务未 started"; }

echo "===== [5/6] 等待面板启动 ====="
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

echo "===== [6/6] 关键日志（最后 15 行）====="
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