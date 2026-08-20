# Angelo-xui-plugin

一个针对 [3X-UI](https://github.com/mhsanaei/3x-ui) 的扩展插件：在原有入站（inbound）上增加 **流量倍率（Traffic multiplier）** 功能，让你可以让子节点上报的流量乘以一个倍数再计入主节点配额。

## 这是什么

**问题场景：**
- 你有一个主 3X-UI + 多个子节点 VPS
- 主 3X-UI 限制用户总流量 X GB
- 你想让某些入站"5 倍计入"——比如专线入站实际跑 20 GB 算 100 GB，加速消耗用户的配额

**本插件做的事：**

| 位置 | 改动 |
|---|---|
| 数据库 `inbounds` 表 | 增加 `traffic_multiplier REAL` 列，默认 `1.0` |
| 子节点面板 | 增加 "Traffic multiplier" 字段（UI 编辑入站时可设） |
| 子节点后端 | 在统计用户流量时，把 Xray 上报的字节数乘以 multiplier 后再写入数据库 |
| 主节点 | 不需要改，主 3X-UI 自动读取子节点数据库里放大后的数值 |

**纯增量、向后兼容：**
- 没有装插件的入站 multiplier=1.0，行为跟原版完全一致
- 装回原版二进制数据库列保留无害，只是新面板字段不显示

## 一键安装（在 VPS 上）

> **前提**：先在该 VPS 上装好原版 3X-UI（[官方安装脚本](https://github.com/mhsanaei/3x-ui#installation)）。

在 VPS 上执行一行命令即可：

```bash
curl -sSL https://raw.githubusercontent.com/AngeloSakura/Angelo-xui-plugin/main/install-multiplier.sh \
  | sudo bash -s -- --tag v0.1
```

arm64 VPS 同一条命令，脚本会自动检测架构下载对应产物。

脚本会自动：
1. ✅ 检测架构（amd64 / arm64 / armv7）
2. ✅ 从 GitHub Release 下载对应 tarball
3. ✅ 备份原 `/usr/local/x-ui/bin/x-ui` 到 `/var/backups/x-ui-multiplier/`
4. ✅ 停止 x-ui 服务、替换二进制、启动服务
5. ✅ 检查数据库 `traffic_multiplier` 列是否已自动添加
6. ✅ 出错自动回滚

安装日志：`/var/log/x-ui-multiplier-install.log`

## 配置倍率

1. 登录子节点 3X-UI 面板
2. 进 **Inbounds** → 点要改的入站 → **Edit**
3. 在 **Basic** 标签页里找到 **Traffic multiplier** 字段（在 "periodic traffic reset" 字段附近）
4. 输入倍率（例如 `5`）
5. 保存

> **修改后 5 秒内生效**。下一步所有用户流量都会按倍率放大。

## 回滚

```bash
sudo cp /var/backups/x-ui-multiplier/x-ui.bak.<时间戳> /usr/local/x-ui/bin/x-ui
sudo systemctl restart x-ui
```

数据库里多出来的列不会被原版二进制破坏，回滚后只是面板上看不到字段。

## 触发新 Release

代码有改动时，推一个 git tag 即可触发 GitHub Actions 自动 build：

```powershell
git tag v0.2
git push origin v0.2
```

Actions 会自动：
- build linux/amd64 + linux/arm64 + linux/armv7 + ... + windows/amd64
- 打包成 `x-ui-linux-{arch}.tar.gz`
- 上传到 GitHub Release 页

详见 `.github/workflows/release.yml`（沿用 3X-UI 原项目的完整 workflow）。

## 自己本地 build（可选）

```bash
# 在 Linux / WSL / macOS 上
go build -o x-ui .

# 在 Windows 上需要 MinGW + sqlite3
```

## 文件清单

```
Angelo-xui-plugin/
├── install-multiplier.sh         # VPS 一键安装脚本
├── .github/workflows/release.yml # (沿用) GitHub Actions 自动 build
├── internal/web/service/         # 后端代码改动
├── database/                     # 数据库迁移 (GORM AutoMigrate)
├── web/                          # 前端代码改动
└── README-MULTIPLIER.md          # 本文档
```

## 兼容性

- 3X-UI: 主线 `master` 分支
- Go: 1.26.x
- 数据库: SQLite (GORM AutoMigrate 自动加列)

## License

本插件是 3X-UI 项目的衍生版本，沿用上游 License。