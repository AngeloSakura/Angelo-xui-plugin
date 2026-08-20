# Traffic Multiplier 一键安装 · 运维手记

> 日期：2026-08-21
> 状态：**功能已完成，VPS 部署待 v0.3.3 release 产物上线**
> 读者：明天上班的自己 + 任何接手 VPS 的人

---

## TL;DR — 今晚发生了啥

我给 `3x-ui` fork 加了「**入站流量倍率**」功能（每个入站一个 multiplier，客户端上下行流量按倍率统计）。代码、迁移、前端、测试全部走完，CI 跑过。但是**今晚在 VPS 上线时踩了两个坑**，最后**功能没上线**——脚本修了，明天只需要：

```bash
# 等 v0.3.3 release 产物上线后跑（预计明早）
curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/v0.3.3/install-multiplier.sh | sudo bash -s -- --tag v0.3.3
```

**预期日志重点**：

```
✅ 找到 x-ui: /usr/local/x-ui/x-ui   ← 修了 systemd 探测
🔄 替换二进制...
▶️  启动 x-ui 服务...
✅ 安装完成
```

装完去面板：入站 → 编辑 → 看到「**流量倍率**」输入框 → 改成 `5.0` → 保存。SQLite 里 `traffic_multiplier` 列会同步。

---

## 一、背景：什么是流量倍率？

3x-ui 默认每个入站下的所有客户端共用一份流量统计。加了「流量倍率」之后：

- 入站 A 配 `traffic_multiplier = 5.0`，里面客户端跑了 1 GB 真实流量
- 系统按 `5 × 1 = 5 GB` 计入 client.up / client.down
- 用法：vmiss / 教育优惠机这种便宜服务器，卖给客户时按"原价"扣

跟「总流量倍率 / 全局倍率」的区别：**只影响这一个入站下面的客户端**，不影响其他入站。

---

## 二、改了什么

### 2.1 后端（Go）

| 文件 | 改动 |
|---|---|
| `internal/database/model/model.go` | `Inbound` 结构体加 `TrafficMultiplier float64` 字段（gorm 列名 `traffic_multiplier`） |
| `internal/database/db.go` | 启动时 `ALTER TABLE inbounds ADD COLUMN traffic_multiplier REAL NOT NULL DEFAULT 1.0`（幂等） |
| `internal/web/entity/inbound.go` | DTO `Inbound.Remark` 旁边加 `TrafficMultiplier float64`，加 JSON tag |
| `internal/web/service/inbound.go` | 增 / 改 / 查全部传递 `TrafficMultiplier` 字段 |
| `internal/web/service/inbound_update_traffic_multiplier_test.go` | 单测：update 时不抹掉倍率 |
| `update.sh` | 升级路径自动 ALTER TABLE（独立于 install-multiplier） |
| `install-fresh.sh` | 新装路径同样加 ALTER TABLE |

### 2.2 前端（React）

| 文件 | 改动 |
|---|---|
| `frontend/src/types/inbound.ts` | `Inbound` 类型加 `trafficMultiplier?: number` |
| `frontend/src/pages/inbounds/components/InboundForm.tsx` | 入站编辑表单加「流量倍率」输入框（默认 1.0，min 0.1，step 0.1） |
| `frontend/src/schemas/inboundSchema.ts` | Zod schema 加 `trafficMultiplier`（可选，默认 1.0） |
| `frontend/src/lib/xray/` | 同步所有生成 / 解析入站配置的地方带上 multiplier |

### 2.3 CI / Release

| 文件 | 改动 |
|---|---|
| `install-multiplier.sh`（新建） | 一键脚本：自动检测架构、下载 tarball、备份、停服、替换、启动、验证 |
| `.github/workflows/release.yml` | 触发器加 `**.sh` paths，让 install-multiplier 改动触发 release |

---

## 三、踩的两个坑（明早回来先看这章）

### 坑 1：脚本下错二进制路径 — `bin/x-ui` vs `x-ui/x-ui`

**症状**：脚本说"替换成功"，但 `systemctl status x-ui` 显示**还在跑旧 binary**。

**根因**：

| 安装方式 | 路径 |
|---|---|
| **官方 Git 安装** | `/usr/local/x-ui/x-ui`（无 `bin/` 子目录） |
| **官方一键脚本安装** | `/usr/local/x-ui/bin/x-ui`（有 `bin/` 子目录） |
| **apt 包** | `/usr/bin/x-ui`（wrapper，调上面那个） |

我的 VPS 走的是**官方 Git 安装**（`/usr/local/x-ui/x-ui`，没有 `bin/` 子目录）。脚本里我写的候选顺序是 `which x-ui`（拿到 `/usr/bin/x-ui` wrapper）→ `bin/x-ui`（找不到）→ fallback，所以**它替换的是 wrapper，service 还跑着老 binary**。

**修复**（commit `6d42c2e`）：

```bash
NEW_BIN="$TMP_DIR/x-ui/x-ui"   # tarball 解压后的结构
```

**验证**：v0.3.2 release 跑过，**但产物里 binary 跟旧版一模一样**（因为我修的是脚本，binary 没动）——所以光看 hash / size 没用，必须看 `systemctl cat x-ui | grep ExecStart` 看实际跑的是哪个文件。

### 坑 2：`systemctl cat x-ui` 还是解析到 wrapper

**症状**：坑 1 修了，但脚本**还是找到 `/usr/bin/x-ui`** 而不是 `/usr/local/x-ui/x-ui`。

**根因**：`which x-ui` 优先；wrapper 在 PATH 里靠前。

**修复**（commit `44db990` = **v0.3.3**）：

```bash
# 1. 先读 systemd ExecStart（权威答案，service 跑的是哪个）
XUI_BIN=$(systemctl cat x-ui 2>/dev/null | awk '/^ExecStart=/{print substr($0,11); exit}')

# 2. 再 which（symlink 跟随）
[[ -z "$XUI_BIN" ]] && XUI_BIN=$(which x-ui 2>/dev/null) && [[ -L "$XUI_BIN" ]] && XUI_BIN=$(readlink -f "$XUI_BIN")

# 3. 最后兜底候选列表（Git 安装路径放第一个）
```

**状态**：代码已 commit + push + tag `v0.3.3`。**等 release workflow 把产物 build 出来**。

---

## 四、当前 VPS 的实际状态（明早 ssh 进去对一下）

```bash
# 1. service 实际跑的 binary
systemctl cat x-ui | grep ExecStart

# 2. 两个文件的实际时间 + 大小
ls -la /usr/bin/x-ui /usr/local/x-ui/x-ui

# 3. 当前跑的进程
ps -ef | grep '/x-ui' | grep -v grep

# 4. SQLite 列是否已加
sudo sqlite3 /etc/x-ui/x-ui.db "SELECT id, remark, traffic_multiplier FROM inbounds;"
```

**预期**（明早对照）：

| 检查项 | 期望 |
|---|---|
| `ExecStart=` | `/usr/local/x-ui/x-ui` |
| `/usr/bin/x-ui` mtime | 2026-08-20 18:10（18:10 我重编的版本） |
| `/usr/local/x-ui/x-ui` mtime | **2026-08-20 17:29（昨晚装的旧版）** ← 还没替换 |
| `ps` 显示 | `/usr/local/x-ui/x-ui`（旧版） |
| SQLite | `1\|vmiss-洛杉矶-3号\|1.0`（列已加，默认 1.0） |

**结论**：**SQLite schema 已经修对了（ALTER TABLE 跑了），但 binary 还是旧的**。所以**列加了但面板没「流量倍率」输入框**——因为前端构建进了 binary，binary 旧就没这个输入框。

---

## 五、明天上班的步骤

### Step 1：等 / 触发 v0.3.3 release 产物

```bash
# 看 tag 触发的工作流跑到哪了
open "https://github.com/AngeloSakura/Angelo-xui-plugin/actions/runs/32402045480"
```

**#34 这个 run** 是 `v0.3.3` tag 触发的。等它 completed。

**或者——如果着急**，先用 dev-latest 装（功能上等价，binary 是同一个新版本）：

```bash
curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/install-multiplier.sh | sudo bash -s -- --tag dev-latest
```

dev-latest 已经是 6d42c2e（包含坑 1 的修复，但不包含坑 2 的修复；不过坑 2 是脚本修复，明早装完 v0.3.3 之后就永久对了）。

### Step 2：装完验证

```bash
# 期望看到 /usr/local/x-ui/x-ui 的 mtime 更新了
ls -la /usr/bin/x-ui /usr/local/x-ui/x-ui

# 期望服务重启成功
systemctl status x-ui --no-pager -n 3

# 期望 schema 已有 column
sudo sqlite3 /etc/x-ui/x-ui.db ".schema inbounds" | grep -i multiplier
```

### Step 3：面板测试

1. 打开面板
2. 入站 → 编辑「vmiss-洛杉矶-3号」
3. 找「**流量倍率**」输入框（默认 1.0）
4. 改成 5.0 → 保存
5. 再开 SQL 看：`SELECT remark, traffic_multiplier FROM inbounds;` 应该是 `vmiss-洛杉矶-3号|5.0`

### Step 4：跑测试（如果改了 Go 代码）

```bash
make test-go   # Go 单测
make verify    # 全套（lint + test + build）
```

---

## 六、给未来自己的清单

- ✅ **不要 `bin/x-ui`** —— tarball 里是 `x-ui/x-ui`
- ✅ **不要信 `which x-ui`** —— wrapper 优先，要读 `systemctl cat x-ui | grep ExecStart`
- ✅ **`paths:` 触发器** 写 `**.sh` minimatch 不跨目录，**但根目录的 .sh 能匹配**（已验证 6d42c2e / 44db990 都触发了 release.yml）
- ✅ **release.yml 跑双 job**（linux + windows build + 前端 build），约 5-7 分钟
- ✅ **`stat -c %s`** 不可信——binary 大小几乎一样；**信 mtime + ExecStart + ps**

---

## 七、回滚

万一装坏了：

```bash
sudo systemctl stop x-ui
sudo cp -f /var/backups/x-ui-multiplier/x-ui.bak.20260820-181504 /usr/local/x-ui/x-ui
sudo systemctl start x-ui
```

（备份路径在 install-multiplier 日志里有具体时间戳）

---

## 八、参考链接

- **GitHub**：https://github.com/AngeloSakura/Angelo-xui-plugin
- **Actions**：https://github.com/AngeloSakura/Angelo-xui-plugin/actions
- **本地脚本**：`install-multiplier.sh`（311 行，全注释）
- **本地单测**：`internal/web/service/inbound_update_traffic_multiplier_test.go`

---

晚安。
