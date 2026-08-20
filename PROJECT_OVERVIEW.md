# 3x-ui 项目整理文档

> **项目路径：`c:\Users\Administrator\Desktop\3x-ui-main`**
> **整理时间：2026-08-20**
> **文档版本：v1.0**

---

## 目录

1. [项目概览](#1-项目概览)
2. [技术栈](#2-技术栈)
3. [目录结构](#3-目录结构)
4. [核心架构](#4-核心架构)
5. [数据模型](#5-数据模型)
6. [API 与路由](#6-api-与路由)
7. [后台任务（Cron Jobs）](#7-后台任务cron-jobs)
8. [请求生命周期](#8-请求生命周期)
9. [关键设计原则](#9-关键设计原则)
10. [支持的协议和特性](#10-支持的协议和特性)
11. [开发与构建](#11-开发与构建)
12. [环境变量](#12-环境变量)
13. [支持的语言与平台](#13-支持的语言与平台)
14. [后续功能修改入口指引](#14-后续功能修改入口指引)

---

## 1. 项目概览

### 1.1 项目简介

**3X-UI** 是一个先进的开源 Web 控制面板，用于管理 **Xray-core** 服务器。它提供简洁、多语言的界面，用于部署、配置和监控各种代理与 VPN 协议——从单台 VPS 到多节点部署。

作为原始 X-UI 项目的增强分支（fork），增加了更广泛的协议支持、更好的稳定性、按客户端的流量统计以及许多提升使用体验的功能。

### 1.2 核心特性

- **多协议入站**：VLESS、VMess、Trojan、Shadowsocks、WireGuard、Hysteria2、HTTP、SOCKS (Mixed)、Dokodemo-door / Tunnel、MTProto、TUN
- **现代传输与安全**：TCP (Raw)、mKCP、WebSocket、gRPC、HTTPUpgrade、XHTTP，通过 TLS、XTLS、REALITY 加密
- **回落 (Fallback)**：通过 Xray 的 fallback 功能在单个端口上提供多种协议（例如在 443 端口上同时使用 VLESS 和 Trojan）
- **按客户端管理**：流量配额、到期日期、IP 限制、实时在线状态、一键分享链接、二维码和订阅
- **流量统计**：按入站、按客户端、按出站统计，支持重置控制
- **多节点支持**：从单一面板管理并扩展到多台服务器
- **出站与路由**：WARP、NordVPN、自定义路由规则、负载均衡器和出站代理链
- **内置订阅服务器**：支持多种输出格式（raw / JSON / Clash）和自定义页面模板
- **Telegram 机器人**：用于远程监控和管理
- **RESTful API**：带有面板内置的 Swagger 文档
- **灵活的存储**：SQLite（默认）或 PostgreSQL
- **13 种界面语言**：支持深色和浅色主题
- **Fail2ban 集成**：用于强制执行按客户端的 IP 限制

### 1.3 项目模块

项目由两个**独立进程**和一个**托管子进程**组成：

| 服务/进程 | 包路径 | 用途 | 默认端口 |
| --- | --- | --- | --- |
| **面板 (Panel)** | `internal/web` | 管理 REST/WS API + 内嵌 SPA | 2053 |
| **订阅 (Subscription)** | `internal/sub` | 公共端点，向最终用户分发客户端配置 | `subPort` 设置 |
| **Xray-core** | 通过 `internal/xray` 托管 | 实际代理引擎（子进程） | `inbounds[].port` |
| **mtg-multi** | 通过 `internal/mtproto` 托管 | MTProto 代理子进程（多密钥） | 每个入站独立 |

---

## 2. 技术栈

### 2.1 后端（Go 1.26.6）

- **Web 框架**：Gin（`gin-gonic/gin`） + sessions（cookie store）、gzip
- **ORM**：GORM，支持 SQLite（默认）或 PostgreSQL
- **调度器**：`robfig/cron/v3`（秒级精度）用于所有后台任务
- **Xray 集成**：`xtls/xray-core` 作为库引入；面板通过它的 **gRPC API** 与运行中的 core 通信，并通过 shell 管理进程
- **Telegram 机器人**：`mymmrac/telego`
- **国际化**：`nicksnyder/go-i18n`
- **其他**：gorilla/websocket、gopsutil（系统状态）、go-qrcode、gotp（2FA TOTP）

### 2.2 前端（`frontend/`）

- **React 19** + **Ant Design 6** + **Vite 8** + **TypeScript**
- **数据层**：TanStack Query（`@tanstack/react-query`） + 原生 Fetch API + **Zod 4** schemas
- **路由**：react-router 8
- **图表**：uPlot（`frontend/src/components/viz/Sparkline.tsx`）
- **编辑器**：CodeMirror 6
- **构建输出** → `internal/web/dist/`，通过 `go:embed` 嵌入到 Go 二进制中
- 三个 HTML 入口：`index.html`（面板 SPA）、`login.html`、`subpage.html`

### 2.3 关键依赖

```
github.com/gin-gonic/gin v1.12.0
github.com/xtls/xray-core v1.260327.1
gorm.io/gorm v1.31.2
github.com/mymmrac/telego v1.11.1（Telegram 机器人）
github.com/robfig/cron/v3 v3.0.1
github.com/nicksnyder/go-i18n/v2
```

---

## 3. 目录结构

```
3x-ui/
├── main.go                      # 入口：CLI（run/migrate/setting/cert）、启动、信号处理
├── go.mod / go.sum              # Go 依赖（module path: github.com/mhsanaei/3x-ui/v3）
│
├── internal/                    # 所有后端 Go 代码（私有包）
│   ├── config/                  # 环境变量解析（XUI_DEBUG, XUI_DB_TYPE, XUI_DB_DSN 等）
│   ├── database/
│   │   ├── db.go                # InitDB：连接、AutoMigrate、seeders（~1.4k 行）
│   │   ├── migrate_data.go      # 数据迁移（seeders/normalizers）
│   │   ├── dialect.go           # SQLite vs Postgres SQL 差异处理
│   │   ├── dump_sqlite.go       # 数据库导出/备份
│   │   └── model/               # ⭐ 所有 GORM 模型（model.go ~1.4k 行）
│   ├── eventbus/                # 进程内 pub/sub（事件分发）
│   ├── tunnelmonitor/           # 可选隧道健康探测（独立于面板设置）
│   ├── xray/                    # Xray-core 集成（代理引擎包装）
│   │   ├── process.go           # 启动/管控 Xray 子进程（~750 行）
│   │   ├── api.go               # gRPC 客户端（add/remove user, stats）（~800 行）
│   │   ├── hot_diff.go          # ⭐ 计算最小化变更以避免完全重启（~500 行）
│   │   ├── config.go            # Xray 配置对象模型
│   │   ├── inbound.go           # 入站 JSON 整形
│   │   ├── client_traffic.go    # ClientTraffic 模型
│   │   ├── traffic.go           # 流量类型辅助
│   │   └── geodata/             # geosite/geoip .dat 流式读取
│   │
│   ├── web/                     # 面板服务器
│   │   ├── web.go               # ⭐ 服务器启动：initRouter + startTask
│   │   ├── controller/          # HTTP 处理器（薄）。每个资源一个文件
│   │   │   ├── inbound.go       # /panel/api/inbounds
│   │   │   ├── client.go        # /panel/api/clients（CRUD + bulk + ips）
│   │   │   ├── node.go          # /panel/api/nodes（多节点管理）
│   │   │   ├── host.go          # /panel/api/hosts（订阅主机覆盖）
│   │   │   ├── server.go        # /panel/api/server（状态、证书、日志）
│   │   │   ├── setting.go       # /panel/api/setting
│   │   │   ├── xray_setting.go  # /panel/api/xray（原始 Xray 配置编辑器）
│   │   │   ├── api.go           # /panel/api 网关（token auth）
│   │   │   ├── index.go         # login/logout/csrf/2FA
│   │   │   └── spa.go           # SPA fallback
│   │   ├── service/             # ⭐⭐ 业务逻辑（大部分实际工作）
│   │   │   ├── inbound.go              # 入站 CRUD 核心（~1.4k 行）
│   │   │   ├── inbound_node.go         # 节点同步：reconcile、流量合并（~1.1k 行）
│   │   │   ├── inbound_traffic.go      # 客户端流量统计（~1.1k 行）
│   │   │   ├── inbound_clients.go      # 入站内的客户端操作
│   │   │   ├── client_crud.go          # 客户端 CRUD
│   │   │   ├── client_bulk.go          # 批量客户端操作（~1.6k 行）
│   │   │   ├── client_inbound_apply.go # 客户端变更应用到 runtime（~1.2k 行）
│   │   │   ├── node.go                 # 节点服务：CRUD、探针、心跳（~1.1k 行）
│   │   │   ├── host.go                 # Host 行（订阅输出覆盖）
│   │   │   ├── server.go               # 服务管理：状态、证书、xray 安装（~2.2k 行）
│   │   │   ├── setting.go              # 设置服务（~1.3k 行）
│   │   │   ├── traffic_writer.go       # 批量持久化流量增量
│   │   │   ├── xray.go                 # XrayService：配置生成 + 重启（~1.2k 行）
│   │   │   ├── xray_setting.go         # 原始 Xray 配置持久化
│   │   │   ├── reality_scan.go         # REALITY 目标扫描器
│   │   │   ├── outbound_subscription.go# 出站订阅
│   │   │   ├── fallback.go             # Xray fallback
│   │   │   ├── email/                  # 邮件通知服务（SMTP）
│   │   │   ├── integration/            # 外部提供者：warp.go、nord.go
│   │   │   ├── outbound/               # 出站配置服务
│   │   │   ├── panel/                  # 面板级别服务
│   │   │   │   ├── user.go             # 管理员用户认证（bcrypt）
│   │   │   │   ├── api_token.go        # API 令牌 CRUD（SHA-256 哈希）
│   │   │   │   └── websocket.go        # WS hub / 推送服务
│   │   │   └── tgbot/                  # Telegram 机器人命令处理
│   │   ├── runtime/            # ⭐⭐ Local/Remote 节点抽象
│   │   │   ├── runtime.go      # Runtime 接口（契约）
│   │   │   ├── local.go        # 本地实现 → 本机 Xray gRPC API
│   │   │   ├── remote.go       # 远程实现 → 发送到子节点的 HTTPS
│   │   │   ├── tls_client.go   # 每节点 HTTP 客户端：verify/skip/pin/mtls
│   │   │   └── manager.go      # RuntimeFor(nodeID) → 选择 Local 或 Remote
│   │   ├── job/               # ⭐ 17 个 cron 任务
│   │   ├── middleware/        # Gin 中间件
│   │   ├── global/            # 全局单例：web/sub server、重启钩子
│   │   ├── network/           # 自定义网络监听器
│   │   ├── session/           # 会话/cookie 辅助
│   │   ├── websocket/         # WebSocket hub
│   │   ├── locale/ + translation/  # i18n 中间件 + 13 语言目录
│   │   ├── entity/            # 共享请求/响应 DTOs
│   │   └── dist/              # Vite 构建输出（go:embed）
│   │
│   ├── sub/                    # 订阅服务器（与面板分离）
│   │   ├── sub.go              # 服务器启动
│   │   ├── controller.go       # 路由：raw / JSON / Clash 订阅格式
│   │   ├── service.go          # ⭐ 链接/配置生成器（~2.5k 行）
│   │   ├── json_service.go     # JSON 订阅格式
│   │   ├── clash_service.go    # Clash/Mihomo YAML 格式
│   │   ├── host_sub.go         # Host 行覆盖
│   │   ├── vless_route.go      # VLESS 路由整形
│   │   └── links.go            # 链接辅助
│   │
│   ├── mtproto/               # 嵌入式 MTProto (Telegram) 代理
│   ├── logger/                # 应用程序日志（op/go-logging + lumberjack）
│   └── util/                  # 叶子辅助
│       ├── common/ crypto/ link/ wireguard/ ldap/ sys/ netsafe/
│
├── frontend/                  # React SPA（构建到 internal/web/dist）
│   ├── vite.config.js
│   ├── package.json
│   └── src/
│       ├── main.tsx / routes.tsx / queryClient.ts
│       ├── entries/           # 额外 HTML 入口：login.tsx, subpage.tsx
│       ├── pages/             # ⭐ 路由页面
│       │   ├── inbounds/      # 入站列表 + 入站表单（协议/安全/传输）
│       │   ├── clients/       # 客户端管理
│       │   ├── nodes/         # 多节点 UI
│       │   ├── hosts/         # 订阅主机覆盖 UI
│       │   ├── xray/          # 原始 Xray 配置 UI
│       │   ├── index/         # 仪表板/首页
│       │   └── settings/, groups/, sub/, login/, api-docs/
│       ├── api/               # 数据层：http-init, QueryProvider, queryKeys
│       │   └── queries/       # TanStack Query hooks
│       ├── schemas/           # Zod schemas
│       ├── generated/         # ⚠️ 从 Go 生成（不要手动编辑）
│       ├── components/        # 复用 UI（clients/ form/ geodata/ ui/ viz/）
│       ├── lib/               # 前端域逻辑（xray/ inbounds/ clients/）
│       └── test/              # Vitest + golden fixtures
│
├── tools/openapigen/          # Go 程序：从 Go 类型生成前端 src/generated/*
├── docs/                      # 文档站点（Next.js/Fumadocs）
├── media/                     # README 图片
│
├── Dockerfile / docker-compose.yml / DockerEntrypoint.sh / DockerInit.sh
├── install.sh / update.sh / x-ui.sh   # VPS 安装 + 管理 CLI
├── x-ui.service.*  / x-ui.rc          # systemd 单元
├── windows_files/                      # Windows 服务支持
└── .github/workflows/         # CI 工作流
```

---

## 4. 核心架构

### 4.1 双核心理念

#### 4.1.1 DB → Xray 配置管道

入站/客户端保存在数据库中。每次变更后，后端重新生成 Xray 配置并应用——优先使用 **热更新**（gRPC API 实时变更）而非完全重启。

**流程**：
1. 服务变更 DB 状态（入站/客户端/设置）
2. `XrayService`（`service/xray.go`）从 DB 状态构建新的 `xray.Config`（`GetXrayConfig`）
3. 尝试 **热应用**（`tryHotApply` → `xray/hot_diff.go`）：对旧/新配置做 diff，仅推送增量（add/remove inbound, add/remove user）——**无需重启进程**，连接得以保留
4. 如果 diff 不适用（结构性变更），回退到 **完全重启** Xray 进程（`xray/process.go`）

重启通过原子的"need restart"标志去重（`SetToNeedRestart` / `IsNeedRestartAndSetFalse`），由一个 `@every 30s` 的 cron 任务消费——窗口内的多次变更只会导致一次重启。

**关键文件**：
- `service/xray.go`（编排）
- `xray/hot_diff.go`（diff 算法）
- `xray/process.go`（进程生命周期）
- `xray/api.go`（gRPC 调用）
- `xray/config.go`（配置模型）

#### 4.1.2 Runtime 抽象（多节点）

一个"节点"（`model.Node`）是本面板控制的其他 3x-ui 实例。每个状态变更的入站/客户端操作都通过 `runtime.Runtime` 接口分发，以便**同一服务代码**无论目标是本地 Xray 还是远程节点都能工作。

**接口**（`internal/web/runtime/runtime.go`）：`Name`, `AddInbound`, `DelInbound`, `UpdateInbound`, `AddUser`, `RemoveUser`, `UpdateUser`, `DeleteUser`, `AddClient`, `RestartXray`, `ResetClientTraffic`, `ResetInboundTraffic`, `ResetAllTraffics`。

- **Local**（`local.go`）：直接调用本机 Xray gRPC API
- **Remote**（`remote.go`）：序列化操作并通过 HTTPS 发送到子节点的 API
- **TLS 模式**（`tls_client.go`，每节点 `TlsVerifyMode`）：
  - `verify`（默认，使用系统 CA）
  - `skip`（不验证）
  - `pin`（叶子证书 SHA-256 必须匹配 `PinnedCertSha256`）
  - `mtls`（主节点提供客户端证书；节点证书对照系统根证书检查）

**分发**：`manager.go` → `Manager.RuntimeFor(nodeID *int)`；`nil` nodeID → `Local`，否则是缓存/懒加载的 `Remote`。`InvalidateNode(id)` 丢弃缓存的远程客户端。

**节点身份与归因（难点）**：入站带有 `NodeID` **和** `OriginNodeGuid`。由于入站可以跨跃点推送，面板使用**稳定 GUID** 而非本地 ID 将流量和在线客户端归因到原始面板。相关逻辑：`service/inbound_node.go`（`ReconcileNode`, `SetRemoteTraffic`, GUID merge）。

**节点问题排查位置**：
- 操作未到达节点 → `runtime/remote.go` + `runtime/manager.go`
- 跨跃点流量/在线归因错误 → `service/inbound_node.go`（GUID merge 路径）
- 节点显示离线/状态陈旧 → `job/node_heartbeat_job.go` + `service/node.go`
- 离线节点的编辑在重连后未应用 → `service/inbound_node.go` + `service/node.go` 中的 dirty/reconcile 逻辑
- TLS/mTLS 握手失败 → `runtime/tls_client.go`, `service/node_mtls.go`

### 4.2 进程管理

`main.go` 启动时：
1. 加载环境变量和 .env 文件
2. 初始化节点令牌加密
3. 初始化数据库
4. 启动 Web 服务器（`internal/web`）
5. 启动订阅服务器（`internal/sub`）
6. 设置信号处理（SIGHUP：重启服务器；SIGUSR1：重启 xray-core；SIGTERM/Interrupt：优雅关闭）
7. 启动可选的隧道健康监控

**信号处理**：
- `SIGHUP`：重启面板和订阅服务器（不重启 Xray）
- `SIGUSR1`：重启 Xray-core
- `SIGTERM`/`SIGINT`：优雅关闭所有服务

### 4.3 入口与命令

`main.go` 提供以下 CLI 命令：

| 命令 | 说明 |
| --- | --- |
| `run` | 启动 Web 面板（默认） |
| `migrate` | 从旧的 x-ui 迁移数据 |
| `migrate-db` | SQLite ↔ .dump 转换或迁移到 PostgreSQL |
| `encrypt-tokens` | 使用配置的活动密钥加密节点 bearer 令牌 |
| `setting` | 配置面板设置（端口、用户名、密码、SSL、TG 机器人等） |
| `cert` | SSL 证书管理 |
| `setting -getApiToken` | 显示/重生 API 令牌 |

---

## 5. 数据模型

### 5.1 核心模型表

GORM 模型在 `internal/database/model/`（主要是 `model.go`），所有都在 `internal/database/db.go` 中注册 AutoMigrate。

| 模型 | 角色 | 关键字段 |
| --- | --- | --- |
| `User` | 管理员登录 | bcrypt 密码、`LoginEpoch`（使会话失效） |
| `Inbound` | Xray 入站 | `Tag`（唯一）、`Port`、`Protocol`、`Settings`/`StreamSettings`/`Sniffing`（JSON）、`Enable`、`TrafficReset`、`NodeID`、**`OriginNodeGuid`** |
| `Client` | 内存中的客户端视图 | UUID/email/flow/limits（从入站 JSON 解析；不持久化） |
| `ClientRecord` | 持久化客户端 | 实际保存在 `clients` 表，包含 `Email`（唯一）、`SubID`、`UUID`、`Password`、`TotalGB`、`ExpiryTime`、`LimitIP`、`Group` 等 |
| `ClientGroup` | 客户端分组 | `Name`（唯一）、`ResetUp`/`ResetDown`（按组重置） |
| `ClientInbound` | 客户端-入站映射 | `ClientId`、`InboundId` |
| `ClientHwid` | 客户端硬件 ID | `SubID`、`HwidHash`（SHA-256）、`UserAgent`、`DeviceOS` 等 |
| `ClientExternalLink` | 客户端外部链接 | `Kind`（link/subscription）、`Value`、`Remark` |
| `InboundFallback` | 入站 fallback 关系 | `MasterId`、`ChildId`、`Path`、`Dest` |
| `Host` | 订阅主机覆盖 | `InboundId`、`Address`、`Port`、`SNI`、`Security` 等 |
| `Node` | 远程 3x-ui 节点 | `Address`、`ApiToken`、`TlsVerifyMode`、`Status`、`XrayVersion` 等 |
| `NodeClientTraffic` | 节点客户端流量 | `NodeId`、`Email`、`Up`/`Down` |
| `NodeClientIp` | 节点客户端 IP | `NodeId`、`Email`、`Ip` |
| `ClientGlobalTraffic` | 跨主节点总流量 | `Email`、`Up`/`Down`/`Total` |
| `Setting` | 键值配置 | `Key`、`Value` |
| `ApiToken` | API 令牌 | `Name`（唯一）、`Token`（SHA-256 哈希）、`Scope`、`ExpiresAt` |
| `OutboundTraffics` | Xray 出站流量统计 | `Tag`（唯一）、`Up`/`Down`/`Total` |
| `OutboundSubscription` | 出站订阅 | `Url`、`Enabled`、`UpdateInterval` 等 |
| `HistoryOfSeeders` | 跟踪已执行的 seeder | `SeederName` |

### 5.2 数据库支持

- **SQLite**（默认）：单文件 `/etc/x-ui/x-ui.db`（Linux）或可执行目录（Windows）
- **PostgreSQL**：可选（`XUI_DB_TYPE=postgres`），推荐用于大量客户端或多节点设置

**连接配置**：
```
XUI_DB_TYPE=postgres
XUI_DB_DSN=postgres://xui:password@127.0.0.1:5432/xui?sslmode=disable
```

**迁移现有 SQLite 到 PostgreSQL**：
```bash
x-ui migrate-db --dsn "postgres://xui:password@127.0.0.1:5432/xui?sslmode=disable"
```

---

## 6. API 与路由

### 6.1 面板 API（`/panel/api/*`）

所有 API 路由在 `internal/web/web.go` 的 `initRouter()` 中注册。控制器位于 `internal/web/controller/`，每个资源一个文件。

#### 主要路由

| 路由 | 文件 | 用途 |
| --- | --- | --- |
| `POST /panel/api/inbounds` | `inbound.go` | 入站 CRUD |
| `GET/POST/DELETE /panel/api/clients` | `client.go` | 客户端 CRUD + bulk + ips + onlines |
| `GET/POST/PUT/DELETE /panel/api/groups` | `group.go` | 客户端分组管理 |
| `GET/POST/PUT/DELETE /panel/api/nodes` | `node.go` | 多节点管理 |
| `GET/POST/PUT/DELETE /panel/api/hosts` | `host.go` | 订阅主机覆盖 |
| `GET/POST /panel/api/server` | `server.go` | 状态、xray 版本、证书、日志、DB 导入/导出 |
| `GET/POST /panel/api/setting` | `setting.go` | 面板设置 + API 令牌 |
| `GET/POST /panel/api/xray` | `xray_setting.go` | 原始 Xray 配置编辑器、WARP/Nord、geodata |
| `POST /panel/api/login` | `index.go` | 登录/登出/CSRF/2FA |
| `GET /panel/api/openapi.json` | 自动生成 | OpenAPI/Swagger 文档 |

### 6.2 订阅 API（`/sub/*`）

订阅服务器在 `internal/sub`，独立运行。路由：

- `GET /sub/{subId}` — 原始链接列表
- `GET /sub/{subId}/json` — JSON 格式订阅
- `GET /sub/{subId}/clash` — Clash/Mihomo YAML

订阅路径通过 `subPath` 设置（默认 `/sub/`）和子域路径配置。

### 6.3 中间件链

Gin 引擎中的中间件（按顺序）：

1. **SecurityHeaders** — 安全 HTTP 头
2. **MaxBodyBytes**（10 MiB；importDB 豁免）— 请求体大小限制
3. **DomainValidator**（如果设置了 webDomain）— 域名验证
4. **gzip** — 响应压缩
5. **sessions**("3x-ui") — Cookie 会话
6. **base-path / cache-control context** — 路径前缀
7. **Localizer** — 国际化
8. **ConfigEnvelope**（仅 API 路由）— zstd + SHA-256 压缩
9. **CSRF**（仅 API 路由）— 防跨站请求伪造

---

## 7. 后台任务（Cron Jobs）

所有任务在 `internal/web/web.go` → `startTask()` 中注册。每个任务是 `internal/web/job/` 中的结构体，带 `Run()` 方法。

| 调度 | 任务 | 用途/条件 |
| --- | --- | --- |
| `@every 1s` | `check_xray_running_job` | Xray 死后重启（连续 2 次下线检查） |
| `@every 30s` | （内联函数） | 去抖动 Xray 重启——消费"need restart"标志 |
| `@every 5s` | `xray_traffic_job` | 从 Xray 拉取流量统计（5s 启动延迟） |
| `@every 5s` | `node_heartbeat_job` | 探测子节点（在线/离线） |
| `@every 5s` | `node_traffic_sync_job` | 拉取并合并节点流量；推送协调 |
| `@every 10s` | `check_client_ip_job` | 强制执行每客户端 IP 限制 |
| `@every 10s` | `mtproto_job` | 协调 `mtg` 边车与启用的 MTProto 入站 |
| `@every 5m` | `outbound_subscription_job` | 刷新出站提供者配置 |
| `@every 10m` | `clear_logs_job`（`PruneXrayLogsJob`） | Xray access/error 日志超过 64 MiB 时截断 |
| `@hourly` | `warp_ip_job`、`periodic_traffic_reset_job("hourly")` | WARP IP 轮换；流量重置 |
| `@daily` | `clear_logs_job`、`periodic_traffic_reset_job("daily")`、`periodic_traffic_reset_job("monthly")` | IP 限制和 Xray 日志清理；每日重置和月度重置 |
| `@weekly` | `periodic_traffic_reset_job("weekly")` | 每周流量重置 |
| `@every 1m` | `ldap_sync_job` | 仅 LDAP 启用时；配置调度 |
| `@daily` | `stats_notify_job` | 仅 TG 机器人启用时；配置调度 |
| `@every 2m` | `check_hash_storage` | 仅 TG 机器人启用时；过期机器人回调哈希 |
| `@every 1m` | `check_cpu_usage` | 仅配置了 CPU 警报时；发布 `cpu.high` |
| `@every 1m` | `check_memory_usage` | 仅配置了内存警报时；发布 `memory.high` |
| 可配置 | `free_os_memory` | 仅 `sys.MemoryReleaseIntervalMinutes() > 0` 时；将堆返回给 OS |

---

## 8. 请求生命周期

### 8.1 管理 API 请求（例如"添加客户端"）

```
浏览器（React fetch）
  → POST {basePath}/panel/api/...
    → Gin 引擎（internal/web/web.go: initRouter）
      → 中间件链：SecurityHeaders → MaxBodyBytes → [DomainValidator] → gzip
                  → sessions("3x-ui") → base-path → Localizer
                  → API 路由添加：ConfigEnvelope（zstd + SHA-256）→ CSRF
        → Controller（internal/web/controller/*.go）   // 仅 HTTP 关注点：bind、validate、respond
          → Service（internal/web/service/*.go）        // 业务逻辑 + 事务
            → GORM → DB（internal/database）             // 持久化
            → runtime.Runtime dispatch                  // 应用到 Xray（Local）或节点（Remote）
              → Local：internal/xray（gRPC API 或配置重新生成 + 重启）
              → Remote：internal/web/runtime/remote.go → HTTPS → 子节点 API
```

**控制器层薄。业务逻辑在 service 中。** 当行为出错时，bug 几乎总是在 service 文件中，而不是 controller。

### 8.2 订阅请求（最终用户获取配置）

```
最终用户 → GET {subPath}/{subId}   （独立服务器, internal/sub）
  → internal/sub/controller.go（路由：raw / JSON / Clash 变体，受 feature flag 控制）
    → internal/sub/service.go（~2.5k 行——链接/配置构建器）
      → 从 DB 读取入站+客户端+主机，按协议渲染分享链接 / Clash YAML / JSON
```

### 8.3 后台工作（cron 任务）

在 `internal/web/web.go` → `startTask()` 中调度。每个任务是 `internal/web/job/` 中的结构体。

---

## 9. 关键设计原则

### 9.1 修复大小匹配 Bug 大小

找到根本原因，然后做出**最小变更**来消除它——一个单行 guard 胜过一个新的子系统。小 bug 不应获得新列、新任务、新抽象、新配置旋钮或新辅助层。如果修复确实需要新架构，请先说明并获得一致同意；不要在未经请求的情况下与修复一起交付。

### 9.2 注释规范

已提交的 Go/TS 注释：每个注释块**最多 2 行**。让名字承载含义，**重命名**而非注释；将 2 行用于名字无法承载的**为什么**——一个不变量、一个 issue 编号、一个不明显的约束。豁免：`//go:build`、`//go:generate` 等指令。HTML `<!-- -->` 也可以。

### 9.3 路由注册规范

新的 `g.POST`/`g.GET` 在 `internal/web/controller/` 中**必须**有以下配套项：
1. `frontend/src/pages/api-docs/endpoints.ts` 中匹配条目
2. 然后 `make gen`（或 `cd frontend && npm run gen`）

由 `TestRouteRegistryContract`（`internal/web/routes_contract_test.go`）双向固定：缺失或陈旧条目会导致 `make test-go` 失败。范围：`/panel/api/*` + 少数会话路由；子服务器路由豁免。

### 9.4 响应示例规范

响应示例来自 Go 结构的 `example:` 标签，通过 `tools/openapigen`——**不要手写**。新结构必须添加到 openapigen 的 `StructAllow` 允许列表（`tools/openapigen/main.go`），否则会从 schemas/examples 中静默省略（并且 `build-openapi.mjs` 会因缺少 schema 而失败）。

### 9.5 文档同步规范

新的或重命名的端点有**第四步**没有任何东西检查：复制 `frontend/public/openapi.json` → `docs/public/openapi.json`，然后 `cd docs && pnpm gen:api` 刷新 `docs/content/docs/en/reference/api/` 下的 MDX。`docs-ci.yml` 仅在 `docs/**` 上触发。

### 9.6 i18n 规范

新的英文 i18n 键必须：
1. 添加到 `internal/web/translation/` 中的**每个** locale JSON（13 个文件）
2. 必须在**同一提交**中从 `frontend/src` 或 Go 引用

`frontend/src/test/i18n-dead-keys.test.ts` 双向失败。它是前端测试，所以运行 `npm test`，不仅仅是 `make test-go`。

### 9.7 数据库变更规范

DB/模型变更需要 `internal/database/db.go` 中的迁移。

### 9.8 Runtime 抽象规则

每个状态变更的入站/客户端操作都通过 `runtime.Runtime`（`internal/web/runtime/`）分发——**绝不**直接转向 `internal/xray/api.go`，**绝不**从 controller 或 cron 任务调用。直接调用会通过每个本地测试，但在每个多节点部署中静默破坏。

### 9.9 提交规范

Conventional commits：`type(area): short imperative summary`，然后是解释 why 的正文。使用的类型：`fix`、`feat`、`chore`、`refactor`、`perf`、`docs`、`style`。

### 9.10 Go 规范

- 仅 stdlib `testing`（无 testify）。表驱动，`t.Run` 子测试，`t.Helper()` 用于辅助函数
- 断言精确值/类型化错误/发射字符串，从不只 `err != nil`
- 优先使用真实依赖而非 mocks：通过 `database.InitDB(filepath.Join(t.TempDir(), "x-ui.db"))` + `t.Cleanup(...)` 创建临时 DB；`httptest` 用于 HTTP
- 测试必须**没有修复就失败**。编写它，还原修复，看着它变红，然后恢复
- 测试**实际可能破坏的内容**。无需为 getter、常量、重命名、纯映射查找或函数永远不会收到的输入编写测试
- 代码必须通过 `golangci-lint run`（gofumpt + goimports 格式）：`make lint`
- Postgres、xray-gRPC-e2e 和 scale 测试 `t.Skip`，除非设置了 `XUI_TEST_PG_DSN`、`XUI_DB_TYPE`+`XUI_DB_DSN`、`XRAY_E2E_BINARY` 或 `XUI_SCALE_TEST`

### 9.11 前端规范（摘要）

- 仅 Ant Design 6——无 Tailwind/shadcn。有针对性的调整，而非重写
- TS strict；oxlint 的 `typescript/no-explicit-any` 是错误
- `src/schemas/` 中的 Zod schemas 是事实来源；用 `z.infer` 推断类型，从不手写
- **不要编辑 `src/generated/`**
- Node 24（`.nvmrc`）——`make gen` 直接导入 `.ts` 并需要其类型剥离；Node 22 以 `ERR_UNKNOWN_FILE_EXTENSION` 失败
- `npm test` 包含一个 headless-Chromium Storybook 项目，所以运行 `npx playwright install --with-deps chromium` 一次，否则 `make verify` 失败
- 编辑 `frontend/src` 不会改变用户看到的，直到将 Vite 构建重新生成到 `internal/web/dist/`
- 在 `XUI_DEBUG=true` 中，HTML 从冻结的嵌入 FS 提供，但 JS/CSS 来自磁盘——`npm run build` 后，**必须**重启 `go run .`，否则会出现带 404 的空白页面

---

## 10. 支持的协议和特性

### 10.1 入站协议

| 协议 | 说明 |
| --- | --- |
| **VLESS** | 轻量级代理协议 |
| **VMess** | V2Ray 原生协议 |
| **Trojan** | 伪装成 HTTPS 的代理 |
| **Shadowsocks** | 经典代理协议 |
| **WireGuard** | 现代 VPN 协议 |
| **Hysteria2** | 基于 QUIC 的高性能协议 |
| **HTTP** | HTTP 代理 |
| **SOCKS (Mixed)** | SOCKS4/5 混合代理 |
| **Dokodemo-door / Tunnel** | 任意门协议 |
| **TUN** | 虚拟网卡模式 |
| **MTProto** | Telegram 代理协议 |

### 10.2 传输方式

- **TCP** (Raw)
- **mKCP**
- **WebSocket**
- **gRPC**
- **HTTPUpgrade**
- **XHTTP**

### 10.3 安全特性

- **TLS**
- **XTLS**
- **REALITY**

### 10.4 流量管理

- 按入站、客户端、出站分别统计
- 流量配额（`TotalGB`）
- 定期重置（never / hourly / daily / weekly / monthly）
- 到期日期（`ExpiryTime`）
- IP 限制（`LimitIP`）
- 硬件 ID 限制（`LimitHwid`）

### 10.5 客户端特性

- 一键分享链接（vless://, vmess://, trojan://, ss://, hysteria2://, wireguard://）
- 二维码生成
- 订阅链接（raw / JSON / Clash）
- 自动续期（calendar renewal）
- 客户端分组（Client Groups）
- 外部链接合并（External Links）
- HOST 覆盖（Host Override）

### 10.6 路由与出站

- WARP
- NordVPN
- 自定义路由规则
- 负载均衡器
- 出站代理链
- 出站订阅（自动获取并合并第三方配置）

### 10.7 监控与通知

- Fail2ban 集成
- 实时在线状态
- Telegram 机器人通知
- 邮件通知（SMTP）
- 系统指标监控（CPU/内存）
- 流量警告
- 节点心跳监控

---

## 11. 开发与构建

### 11.1 关键命令

```bash
# 完整验证（fast gate）
make verify

# 单独运行各步骤
make gen          # 重新生成 Zod/OpenAPI
make lint         # Go + frontend lint
make test         # Go（-shuffle=on）+ frontend
make race         # 竞态检测
make build        # 构建
make build-storybook  # 构建 Storybook
```

### 11.2 完整 CI 流程

`ci.yml` 还会运行 `make race`、`make vulncheck`、live-Postgres 任务（SKIP 算作失败）和 30 秒 fuzz 烟雾测试（`FuzzParseLink`/`FuzzDecodeCertPin`）——当你接触 DB/dialect 或解析器代码时本地运行这些。

### 11.3 常见工作流

#### 11.3.1 修改后端代码

```bash
# 1. 修改 Go 代码
# 2. 重新生成前端类型
cd frontend && npm run gen

# 3. 重新构建前端
cd frontend && npm run build

# 4. 重启 Go 服务器
go run .
```

#### 11.3.2 修改前端代码

```bash
# 1. 修改 frontend/src 中的代码
# 2. 重新构建
cd frontend && npm run build

# 3. 重启 Go 服务器（重要！否则看到空白页面）
go run .
```

#### 11.3.3 修改协议配置

如果你修改了产生分享链接的代码（`service/client_link.go` 或 `internal/sub/service.go`），运行 `npm run test`（golden fixtures）。仅对有意的输出更改重新生成快照（`npx vitest run -u`），不要为了使红测试变绿。

#### 11.3.4 修改数据库模型

```bash
# 1. 在 internal/database/db.go 中添加迁移
# 2. 编写迁移测试
# 3. 确保 make verify 通过
make verify
```

---

## 12. 环境变量

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `XUI_DB_TYPE` | 数据库后端：`sqlite` 或 `postgres` | `sqlite` |
| `XUI_DB_DSN` | PostgreSQL 连接字符串（当 `XUI_DB_TYPE=postgres` 时） | — |
| `XUI_DB_FOLDER` | SQLite 数据库文件所在目录 | `/etc/x-ui` |
| `XUI_DB_MAX_OPEN_CONNS` | 最大打开连接数（PostgreSQL 连接池） | — |
| `XUI_DB_MAX_IDLE_CONNS` | 最大空闲连接数（PostgreSQL 连接池） | — |
| `XUI_INIT_WEB_BASE_PATH` | Web 面板的初始 URI 路径 | `/` |
| `XUI_ENABLE_FAIL2BAN` | 启用基于 Fail2ban 的 IP 限制 | `true` |
| `XUI_LOG_LEVEL` | 日志级别（`debug`、`info`、`warning`、`error`） | `info` |
| `XUI_DEBUG` | 启用调试模式 | `false` |
| `XUI_TUNNEL_HEALTH_MONITOR` | 启用隧道健康监控 | `false` |
| `XUI_TUNNEL_HEALTH_PROXY` | 探测请求所经过的代理 | — |
| `XUI_TUNNEL_HEALTH_URL` | 用于检测隧道健康状况的探测 URL | `https://www.cloudflare.com/cdn-cgi/trace` |
| `XUI_TUNNEL_HEALTH_INTERVAL` | 两次探测之间的间隔 | `30s` |
| `XUI_TUNNEL_HEALTH_TIMEOUT` | 单次探测的超时时间 | `10s` |
| `XUI_TUNNEL_HEALTH_FAILURES` | 触发重启前的连续失败次数 | `3` |
| `XUI_TUNNEL_HEALTH_COOLDOWN` | 两次连续重启之间的最小间隔 | `5m` |
| `XUI_PPROF` | 启用 pprof 性能分析（监听 127.0.0.1:6060） | `false` |
| `XUI_NONINTERACTIVE` | 无人值守安装模式 | `false` |

---

## 13. 支持的语言与平台

### 13.1 支持的 UI 语言（13 种）

English · فارسی · العربية · 中文（简体） · 中文（繁體） · Español · Русский · Українська · Türkçe · Tiếng Việt · 日本語 · Bahasa Indonesia · Português (Brasil)

### 13.2 支持的操作系统

Ubuntu、Debian、Armbian、Fedora、CentOS、RHEL、AlmaLinux、Rocky Linux、Oracle Linux、Amazon Linux、Virtuozzo、Arch、Manjaro、Parch、openSUSE (Tumbleweed / Leap)、Alpine、**Windows**

### 13.3 支持的架构

`amd64` · `386` · `arm64` (aarch64) · `armv7` · `armv6` · `armv5` · `s390x`

### 13.4 安装方式

- **Linux/macOS**：`bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)`
- **Docker**：`docker compose up -d`（默认 SQLite）或 `docker compose --profile postgres up -d`
- **Cloud-init**：`XUI_NONINTERACTIVE=1` 无人值守安装
- **Windows**：通过 `windows_files/` 中的服务支持

---

## 14. 后续功能修改入口指引

### 14.1 要添加新协议

1. 在 `internal/database/model/model.go` 的 `Protocol` 常量中添加新协议
2. 在 `internal/xray/` 中实现配置生成
3. 在 `internal/sub/service.go` 中添加分享链接生成
4. 在 `frontend/src/schemas/protocols/` 中添加 Zod schema
5. 在 `frontend/src/pages/inbounds/` 中添加配置 UI
6. 在 `frontend/src/lib/xray/` 中添加前端域逻辑

### 14.2 要添加新 API 端点

1. 在 `internal/web/controller/` 中创建/修改 controller 文件
2. 在 `internal/web/service/` 中实现业务逻辑
3. 在 `frontend/src/pages/api-docs/endpoints.ts` 中注册路由
4. 运行 `make gen` 重新生成类型
5. 编写测试（`internal/web/routes_contract_test.go` 会自动验证）

### 14.3 要修改面板设置

1. 在 `internal/web/service/setting.go` 中添加 getter/setter
2. 在 `frontend/src/pages/settings/` 中添加 UI
3. 在 `internal/web/translation/` 的 13 个 locale JSON 中添加 i18n 键
4. 编写测试

### 14.4 要添加新 Cron 任务

1. 在 `internal/web/job/` 中创建任务结构体
2. 在 `internal/web/web.go` 的 `startTask()` 中注册
3. 编写测试

### 14.5 要修改数据库模型

1. 在 `internal/database/model/model.go` 中修改模型
2. 在 `internal/database/db.go` 中添加迁移
3. 编写迁移测试
4. 运行 `make verify`

### 14.6 要添加新多节点同步逻辑

1. 在 `internal/web/runtime/runtime.go` 的 `Runtime` 接口中添加新方法
2. 在 `internal/web/runtime/local.go` 和 `remote.go` 中实现
3. 在 `internal/web/service/` 中调用新方法
4. 编写测试

### 14.7 要修改订阅输出格式

1. 在 `internal/sub/service.go` 中修改链接生成
2. 在 `internal/sub/json_service.go` 或 `clash_service.go` 中修改对应格式
3. 在 `frontend/src/lib/xray/` 中同步更新前端域逻辑
4. 运行 `npm run test` 验证 golden fixtures

### 14.8 要添加新 i18n 键

1. 在 `internal/web/translation/` 的 13 个 locale JSON 中添加键
2. 在 `frontend/src` 或 Go 中引用该键
3. 编写测试（`frontend/src/test/i18n-dead-keys.test.ts` 会自动验证）

---

## 附录 A：常用路径速查

| 用途 | 路径 |
| --- | --- |
| 入口 | `main.go` |
| Web 启动 | `internal/web/web.go` |
| 订阅启动 | `internal/sub/sub.go` |
| 入站 CRUD | `internal/web/controller/inbound.go` + `internal/web/service/inbound.go` |
| 客户端 CRUD | `internal/web/controller/client.go` + `internal/web/service/client_crud.go` |
| 节点管理 | `internal/web/controller/node.go` + `internal/web/service/node.go` |
| 主机覆盖 | `internal/web/controller/host.go` + `internal/web/service/host.go` |
| 用户认证 | `internal/web/controller/index.go` + `internal/web/service/panel/user.go` |
| API 令牌 | `internal/web/service/panel/api_token.go` |
| Xray 配置 | `internal/xray/config.go` + `internal/web/service/xray.go` |
| Xray 进程管理 | `internal/xray/process.go` |
| Xray gRPC API | `internal/xray/api.go` |
| Xray 热更新 | `internal/xray/hot_diff.go` |
| Runtime 抽象 | `internal/web/runtime/` |
| 订阅生成 | `internal/sub/service.go` |
| 流量统计 | `internal/web/service/inbound_traffic.go` + `internal/web/service/traffic_writer.go` |
| Cron 任务 | `internal/web/job/` |
| 事件总线 | `internal/eventbus/` |
| 数据库模型 | `internal/database/model/model.go` |
| 数据库初始化 | `internal/database/db.go` |
| 配置解析 | `internal/config/config.go` |
| 国际化 | `internal/web/locale/` + `internal/web/translation/` |
| 前端入口 | `frontend/src/main.tsx` |
| 前端路由 | `frontend/src/routes.tsx` |
| 前端数据层 | `frontend/src/api/` |
| 前端域逻辑 | `frontend/src/lib/` |
| 前端生成的类型 | `frontend/src/generated/` |

---

## 附录 B：定义完成（提交 PR 前）

1. `make verify` 通过——其 `gen-check` 已经运行 `make gen` 并在脏的 `frontend/src/generated` / `frontend/public/openapi.json` 上失败
2. 差异聚焦；重构与功能工作分开

---

**文档结束**

> 本文档基于对整个 3x-ui 项目的深入分析整理而成。所有路径、文件名、函数名均经过源码验证。
> 如需修改项目功能，请参考"第 14 节：后续功能修改入口指引"。
