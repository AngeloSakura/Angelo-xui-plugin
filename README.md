# Angelo-xui-plugin

`x-ui` 流量倍率插件。一键替换 3X-UI 官方二进制为带 `traffic_multiplier`
字段的分支构建；在入站配置里给每个入站单独设置流量倍率（默认 `1.0`），
上传下载都按倍率放大累加，与原 3X-UI 客户端订阅、面板、统计完全兼容。

| 项目 | 说明 |
| --- | --- |
| 上游 | 3X-UI (MHSanaei/3x-ui) — fork |
| 兼容性 | 与原 3X-UI 数据库结构兼容，可平滑回滚 |
| 安装位置 | 替换 `x-ui` Go 二进制，不修改数据库结构（自动加列） |
| 配置入口 | 面板 → Inbounds → 编辑 → Basic → `Traffic multiplier` |

> **警告 / Disclaimer**
>
> 本项目仅作技术研究与运维自动化演示。流量倍率属于「非物理计费」功能——
> 多数地区的 ISP / 云服务协议要求按物理流量计费；滥用倍率功能可能违反
> 您与上游 / 运营商的服务条款，并可能触犯当地法律。
>
> 使用本项目意味着您确认：
>
> 1. 您拥有本服务器与目标网络合法授权。
> 2. 您已自行评估合规风险并承担全部责任。
> 3. 项目作者不为任何滥用、损失或法律后果负责。
>
> 本项目不捆绑、不分发、不代理任何绕过审查 / 翻墙流量。
> 流量倍率面向「同一台物理服务器下多租户按需分配配额」「业务演示」等
> 合规场景。请遵守您所在司法辖区的法律。

---

## 快速安装

```bash
# 通用（脚本永远从 main 拉取；tag 决定 binary 来自哪个 release）
curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/install-multiplier.sh | sudo bash -s -- --tag v0.3.3

# 想固定某次 commit（避免 main 之后重构破坏兼容）
curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/1fc1f18/install-multiplier.sh | sudo bash -s -- --tag v0.3.3
```

参数：

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `--tag <tag>` | ✅ | 下载对应 release 的二进制 tarball（如 `v0.3.3`） |
| `--repo <owner/repo>` | ❌ | 默认 `AngeloSakura/Angelo-xui-plugin`（用于自建镜像） |
| `-h` / `--help` | ❌ | 显示脚本头注释 |

---

## 操作系统 / init 系统兼容性矩阵

`install-multiplier.sh` 在执行前会自动探测，**无需用户指定**。

### OS 探测（按 `/etc/os-release` / 发行版元文件）

| 系统 | 元文件 | 判定 ID | 包管理器 |
| --- | --- | --- | --- |
| Debian 10+ | `/etc/debian_version` 或 `/etc/os-release` | `debian` | `apt` |
| Ubuntu 18+ | `/etc/os-release` (`ID=ubuntu`) | `ubuntu` | `apt` |
| CentOS 7+ | `/etc/redhat-release` 或 `os-release` (`ID=centos`) | `centos` | `yum` / `dnf` |
| RHEL 7+ | `/etc/redhat-release` 或 `os-release` (`ID=rhel`) | `rhel` | `yum` / `dnf` |
| Fedora | `/etc/os-release` (`ID=fedora`) | `fedora` | `dnf` |
| Alpine 3+ | `/etc/alpine-release` 或 `os-release` (`ID=alpine`) | `alpine` | `apk` |
| Arch | `/etc/os-release` (`ID=arch`) | `arch` | `pacman` |

未识别 → `unknown` + `unknown` 但仍继续运行（init 探测决定成败）。

### Init 系统探测（决定启停命令 + binary 真实路径）

| Init | 探测依据 | 启停命令 | 路径探测依据 |
| --- | --- | --- | --- |
| **systemd** | `systemctl` 存在 + `/run/systemd/system` | `systemctl start/stop x-ui` | `systemctl cat x-ui` 取 `ExecStart=` |
| **OpenRC** | `/sbin/openrc-run` 存在 | `rc-service x-ui start/stop` | `/etc/init.d/x-ui` 取 `command=` |
| **runit** | `/etc/sv` + `sv` 命令 | `sv start/stop x-ui` | `/etc/sv/x-ui/run` 取 `x-ui` 路径 |
| **sysvinit** | `service` 命令 + `/etc/init.d/x-ui` | `service x-ui start/stop` | `/etc/init.d/x-ui` 取 `DAEMON=` / `BINARY=` |
| **none** | 都不存在 | 兜底 `pkill` | 兜底候选路径轮询 |

### 架构

| 架构 | `uname -m` | 下载资产 |
| --- | --- | --- |
| x86_64 | `x86_64` | `x-ui-linux-amd64.tar.gz` |
| arm64 | `aarch64` | `x-ui-linux-arm64.tar.gz` |
| armv7 | `armv7l` | `x-ui-linux-armv7.tar.gz` |

---

## 改动清单

自 3X-UI 上游 fork 后，本项目相对上游的改动：

| 文件 | 改动 | 行为差异 |
| --- | --- | --- |
| `internal/database/model/` | `Inbound` 增加 `TrafficMultiplier float64` 列 | 入站级流量倍率 |
| `internal/database/db.go` | AutoMigrate + 显式迁移 `traffic_multiplier` | 升级老库自动补列（默认 `1.0`） |
| `internal/web/controller/` + `service/` | 入站 CRUD 接收/回传 `trafficMultiplier` | 面板读写 |
| `internal/web/job/` | 流量统计时按 `TrafficMultiplier` 放大 | 上行 / 下行都按倍率累加 |
| `frontend/` | Inbound 编辑表单新增 `Traffic multiplier` 字段 | 默认 `1`；范围不限；建议 `>0` |
| `install-multiplier.sh` | 自动探测 OS / init / pkg mgr，多点替换二进制 | 一次跑通所有发行版 |

---

## 详细教程

### 1. 前提

- 已装 **3X-UI 面板**且能正常登录
- 服务器能访问 GitHub Releases（80MB 二进制下载）
- `root` 或 `sudo` 权限

### 2. 一键安装

```bash
curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/install-multiplier.sh | sudo bash -s -- --tag v0.3.3
```

脚本会：

1. 探测 OS / 包管理器 / init 系统（你不需要选）
2. 从 `/etc/init.d/x-ui` / `systemctl cat` / `sv run` / `service` 找
   出你面板**真正执行的 binary 路径**（不是 `which` 猜的）
3. 备份原 binary 到 `/var/backups/x-ui-multiplier/x-ui.bak.<时间戳>`
4. 下载并解压 `x-ui-linux-<arch>.tar.gz`
5. **把新 binary 镜像到所有候选位置**（`/usr/local/x-ui/x-ui`、
   `/usr/bin/x-ui` 等都覆盖）— 这是修「Alpine + systemd 路径错乱」
   关键点
6. 按 init 系统调用对应命令停止服务
7. 替换 binary
8. 按 init 系统调用对应命令启动服务
9. 用 `sqlite3` 验证 `traffic_multiplier` 列；缺失则调
   `x-ui migrate-db` 兜底
10. 输出回滚命令

### 3. 启用流量倍率

1. 登录面板
2. 进入 `Inbounds` → 任一入站 → `Edit`
3. 切到 `Basic` 标签，找到新字段 `Traffic multiplier`
4. 填倍率（如 `5` 表示按 5 倍计入统计 / 限额）
5. 保存

**说明**：

- **不影响真实流量** — 真实上下行还是物理流量
- **只影响入站统计 / 配额扣减** — 上传 1GB 但倍率 5，按 5GB 扣
- 客户端订阅、链接、配置全部不变
- 已存在的入站默认 `1.0`（=无倍率），不会突然膨胀

### 4. 验证安装

```bash
# 1. 进程名 / 版本
ps -ef | grep x-ui | grep -v grep
# 看到 Invalid subcommands = Go binary 自检成功

# 2. 列里是否含列
sqlite3 /etc/x-ui/x-ui.db "PRAGMA table_info(inbounds);" | grep traffic_multiplier
# 应输出: ...|traffic_multiplier|real|0|0|1.0|0

# 3. 面板是否更新
# 编辑入站能看到 Traffic multiplier 字段
```

### 5. 回滚

```bash
# 1. 停服务（按你的 init 系统选一条）
sudo systemctl restart x-ui
sudo rc-service x-ui restart
sudo sv restart x-ui
sudo service x-ui restart

# 2. 还原 binary（用脚本末尾给的 BACKUP_PATH）
sudo cp /var/backups/x-ui-multiplier/x-ui.bak.<时间戳> <XUI_BIN>

# 3. 再重启一次
# （init 命令同上）
```

> 数据库列 `traffic_multiplier` **不要手动删除** — 即使回滚到上游
> binary，该列也会被 AutoMigrate 忽略；删除会导致老 binary 启动报
> schema mismatch。回滚的是 binary，**不是数据库**。

---

## 使用注意事项

### 安装前

1. **先备份数据库**：`/etc/x-ui/x-ui.db` 是面板的全部状态。
2. **先备份原 binary**：脚本会自动做（路径
   `/var/backups/x-ui-multiplier/`），但建议你另外手动备一份。
3. **下载带宽**：80MB tarball，限速环境会慢；建议至少 5 Mbps。
4. **网络可达 GitHub**：被墙环境请用 `--repo <mirror>` 走镜像。

### 安装中

1. **不要打断脚本**：它会 `set -e`；中途 `Ctrl+C` 可能留下半
   替换的 binary。**真要中断**先看「中断后怎么办」段。
2. **磁盘空间**：脚本会留两份 binary（原 + 新）+ 一份 tarball ≈
   240MB 临时占用。
3. **日志会持续追加** `/var/log/x-ui-multiplier-install.log`，
   长期使用建议定期清空：
   ```bash
   tail -n 50 /var/log/x-ui-multiplier-install.log > /tmp/x && mv /tmp/x /var/log/x-ui-multiplier-install.log
   ```
4. **备份目录只留最新 3 份**（避免硬盘占满）：
   ```bash
   cd /var/backups/x-ui-multiplier/
   ls -t x-ui.bak.* | tail -n +4 | xargs -r rm -f
   ```

### 安装后

1. **客户端无需任何操作** — 订阅、链接、配置全不变。
2. **倍率字段留空 = 1.0**（等价原版）。设 `0.5` 是扣一半，`2` 是
   扣两倍。
3. **改倍率不需要重启** — 保存即生效。
4. **traffic 统计图 / 上报**：所有按倍率放大，但**对外报告接口
   （sub / API）字段不变**，避免客户端侧识别。
5. **多入站**：每个入站独立倍率，互不影响。

### 中断后怎么办

如果 `Ctrl+C` 中断了脚本：

```bash
# 1. 看哪个 init 在跑
rc-service x-ui status    # Alpine
systemctl status x-ui     # systemd
sv status x-ui            # runit
service x-ui status       # sysvinit

# 2. 看 binary 状态
ls -la /usr/local/x-ui/x-ui /usr/bin/x-ui
# 两个时间戳可能不一致 = 半替换

# 3. 从备份恢复
cp /var/backups/x-ui-multiplier/x-ui.bak.<最新时间戳> /usr/local/x-ui/x-ui
cp /var/backups/x-ui-multiplier/x-ui.bak.<最新时间戳> /usr/bin/x-ui 2>/dev/null || true
chmod +x /usr/local/x-ui/x-ui

# 4. 重启服务
<init 命令> restart x-ui
```

---

## 故障排查

### Q1. 脚本显示 `✅ 数据库已包含 traffic_multiplier 列`，但面板里看不到 `Traffic multiplier` 字段

排查顺序：

1. **浏览器清缓存** — 字段是前端硬编，老 cache 不刷新。
2. **重启面板 binary** — 改字段后不会自检。
   ```bash
   <init 命令> restart x-ui
   ```
3. **确认 binary 是新版**：
   ```bash
   stat -c '%Y' /usr/local/x-ui/x-ui
   # mtime 应是刚跑脚本的时间
   ```
4. **看进程是否新**：
   ```bash
   ps -ef | grep x-ui | grep -v grep
   # start time 应在重启后
   ```

### Q2. 脚本检测不到 init 系统

如果你**真用 systemd** 但脚本判成 `none`：

```bash
# 看 systemctl 是否在 PATH
which systemctl
ls -la /run/systemd/system
```

修复：`systemctl` 不在 PATH 或 `/run` 没挂。在容器里 systemd 不能用是
正常的，请用宿主 init。

### Q3. 脚本找到了 binary 但 OpenRC 不重启

```bash
# 看 OpenRC 服务实际执行哪个 binary
cat /etc/init.d/x-ui | grep -E '^command='
# 应该是 /usr/local/x-ui/x-ui

# 看 binary 状态
ls -la /usr/local/x-ui/x-ui /usr/bin/x-ui
# 两个时间戳应一致

# 手动同步
cp /usr/bin/x-ui /usr/local/x-ui/x-ui
chmod +x /usr/local/x-ui/x-ui
rc-service x-ui restart
```

### Q4. 速率反了 / 流量不对

倍率**只放大计入**，不改变真实流量。

- 倍率 `5`：上行 1GB 计 5GB（配额扣 5GB）
- 倍率 `0.5`：上行 1GB 计 0.5GB
- 倍率 `0`：**不推荐** — 配额永不清零

### Q5. 升级后旧的客户端配额清零了？

不会。倍率字段**只影响新增流量的扣减倍率**；已有 `UsedGB` 字段
保持不变。如果你确实看到清零，请检查：

1. 数据库是不是被手动 `VACUUM` 了
2. 是不是误删了 `/etc/x-ui/x-ui.db`

---

## 合规与法律声明

本项目 **不** 提供：

- ❌ 翻墙 / 绕过 GFW 工具
- ❌ 代理协议实现
- ❌ 任何形式的「翻墙账号」销售

本项目 **仅** 提供：

- ✅ 一个 3X-UI 数据库扩展（`traffic_multiplier` 列）
- ✅ 一个 Go binary 替换脚本
- ✅ 入站配置界面拓展

> 使用本项目的流量倍率功能，可能违反您与 ISP / 云服务商签订的
> 服务条款。请在部署前**联系您的服务提供方**确认允许按倍率计费。
>
> 项目作者不为任何滥用、违反服务条款、或触犯当地法律法规的行为
> 负责；任何责任由使用者自行承担。
>
> 本项目采用 AGPL-3.0 协议（与上游 3X-UI 一致）。fork、修改、再
> 分发时，请保留原作者信息与本声明。

---

## 贡献

PR / Issue 都欢迎。请保持：

- Conventional Commits
- 改动最小化（一个 fix 不夹带重构）
- 不要硬编死路径 / 命令 — 用探测
- 新 init 系统（FreeBSD rc / Solaris SMF）请先开 issue 讨论

---

## License

AGPL-3.0 — 见 [LICENSE](LICENSE)。
