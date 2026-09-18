# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

RW-Node 是 [remnawave/node](https://github.com/remnawave/node) 的轻量化部署方案，使用非官方 [x-dora/rw-node-go](https://github.com/x-dora/rw-node-go) Go 实现。**本仓库不包含应用源码**，源码来自上游仓库，通过 CI/CD 自动构建和打包。

## 架构

### 上游追踪与发布

- `.go-paas-version` 记录当前追踪的 rw-node-go 版本（如 `v1.2.0`），由 Renovate 自动更新
- 代码/配置变更（`.go-paas-version`、`Dockerfile`、`docker-entrypoint.sh`、`lib/`、`scripts/`、`config/`）推送到 main 后触发 `release.yml` → `docker-build.yml` → 构建多架构 Docker 镜像
- 手动触发 `workflow_dispatch` 可强制构建指定版本

### 两种部署方式

- **Docker 镜像**（`ghcr.io/x-dora/rw-node:latest`）：Alpine 基础镜像，构建时下载 rw-node-go + Caddy L4，PaaS HTTPS 直连场景
- **一键脚本安装**（`scripts/install.sh`）：无 Docker 环境的裸机部署，自动安装 rw-node-go、Caddy、Xray geodata

### Shell 库架构

`lib/` 下的 shell 库使用 include guard 防重复加载（如 `_RW_NODE_CORE_LOADED`），依赖链：

```
core.sh  ← 基础（日志、.env 解析、端口校验、架构检测）
  ├── caddy.sh      ← Caddy 配置生成、静态伪装页面、REALITY watcher
  ├── provision.sh   ← GitHub Release 下载（rw-node-go、Caddy、cloudflared）
  └── cloudflared.sh ← Cloudflare Tunnel 启动
```

每个库文件开头通过 `source "${LIB_DIR}/core.sh"` 自动加载依赖，调用方只需 source 所需的顶层库。

### Caddyfile 模板系统

`lib/Caddyfile.template` 是 Docker entrypoint / 裸机 start.sh / inbound-watcher 共用的 Caddy 配置模板，使用 `${PLACEHOLDER}` 占位符。**占位符替换只有一处实现**：bash 的 `write_caddy_config()`。新增占位符只需改模板和这一个函数，任何其它语言都不再复制模板替换逻辑。两个入口脚本（`docker-entrypoint.sh` / `config/start.sh`）通过 `set_default_env()` 统一设置环境变量默认值。L4 处理通过 HTTP server 的 `listener_wrappers` 内嵌，而非独立 app，避免 Caddy app 启动顺序竞态。

### Inbound 动态分流

后台 watcher 轮询 rw-node-go 内部 API（`/internal/get-config`），提取所有可分流的 inbound 配置，自动生成 Caddy 分流规则并热重载。支持 REALITY SNI 分流（L4 层）和 ws/xhttp/httpupgrade 路径分流（HTTP 层），含冲突检测和兜底路由。

职责严格分离：

- **轮询、查重、配置生成、写文件、热重载**全部在 `lib/caddy.sh`（`_start_inbound_watcher` + `render_inbound_routing`），三个后端共用同一份。
- **后端只做数据解析**：把 API 原始 JSON 归一化成 tab 分隔的路由记录写到 stdout，不碰 Caddyfile。三种后端按优先级自动选择：jq（`parse_inbound_config_jq`，内嵌在 `caddy.sh`） > Node.js（`inbound-watcher.js`） > Python（`inbound-watcher.py`）。

记录协议（`panel` / `reality` / `http` / `conflict` 四类，字段以 tab 分隔）之所以不是 JSON，是因为跑 Node/Python 后端的机器不一定有 jq，bash 需要零依赖就能读。三个后端的输出必须**逐字节一致**，改动任一后端后要交叉比对。

### 流量路由（PaaS 单端口复用）

Caddy Layer 4 在 `HTTP_FRONT_PORT` 上做协议分流，靠连接首字节区分（三者互斥）：
- TLS ClientHello（`0x16`）→ TCP 直通到 `NODE_PORT`（不终止 TLS）
- SSH（首 4 字节 `SSH-`）→ TCP 直通到内置 sshd-lite；仅在 `SSH_ENABLED=true` 且提供公钥时注入该规则
- REALITY SNI 匹配 → TCP 直通到 Xray 端口（watcher 动态注入）
- 其余按明文 HTTP 处理 → 直接由 HTTP handler 处理路径路由（通过 `listener_wrappers` 穿透）：
  - ws/xhttp/httpupgrade 精确路径 → 对应 inbound 端口（watcher 动态注入）
  - 兜底：`/xh-*` → `XHTTP_UPSTREAM_PORT`、`/ws-*` → `WS_UPSTREAM_PORT`
  - `/node/*`、`/vision/*` → `NODE_PORT` HTTPS API（`tls_insecure_skip_verify`）
  - 其他 → 静态伪装页面

## 关键文件

- `scripts/install.sh` — 一键安装脚本（bash），安装 rw-node-go、Caddy L4、Xray geodata、共享库
- `scripts/uninstall.sh` — 卸载脚本
- `Dockerfile` — Go 实现 PaaS HTTPS 直连镜像
- `docker-entrypoint.sh` — PaaS 入口脚本，启动 Caddy L4 前置 + rw-node-go + inbound watcher
- `lib/core.sh` — 核心工具库
- `lib/caddy.sh` — Caddy 管理（含 jq 版 inbound watcher、路由渲染、模板替换）
- `lib/Caddyfile.template` — Caddy 配置模板（占位符只由 `write_caddy_config()` 替换）
- `lib/provision.sh` — 组件下载安装库
- `lib/cloudflared.sh` — Cloudflare Tunnel 管理
- `lib/inbound-watcher.js` / `lib/inbound-watcher.py` — Inbound watcher 的 Node.js/Python 后端，只做 JSON→路由记录解析
- `config/start.sh` — 裸机启动脚本（source lib/ 共享库）
- `config/systemd/rw-node.service` — systemd 服务定义
- `config/env.sample` — 环境变量模板
- `config/panel/disable-tls-verify.cjs` — Panel 证书校验预加载脚本，PaaS 场景挂载到 Panel 容器跳过节点证书校验
- `renovate.json` — Renovate 配置，自动追踪上游版本

## 开发与测试

### 本地 Docker 构建

```bash
docker build -t rw-node:test .
docker run --rm -e SECRET_KEY=test -e NODE_PORT=2222 rw-node:test
```

构建参数 `RW_NODE_GO_VERSION` 可指定版本（默认 latest）。

### Shell 脚本检查

所有 shell 脚本使用 `set -euo pipefail`，并包含 `# shellcheck shell=bash` 指令。使用 shellcheck 检查：

```bash
shellcheck lib/*.sh config/start.sh docker-entrypoint.sh scripts/*.sh
```

### 入口脚本对比

| 特性 | `docker-entrypoint.sh` | `config/start.sh` |
|------|------|------|
| `HTTP_FRONT_ENABLED` 默认值 | `true` | `false` |
| .env 文件加载 | 不加载（Docker env） | `load_env_file` |
| 健康检查 | PaaS `PORT` 上的 busybox httpd | 无 |
| Lib 路径 | `/usr/local/lib/rw-node/` | `${WORK_DIR}/lib/` |

## 环境变量

工作目录默认 `/opt/rw-node`，可通过 `RW_NODE_DIR` 自定义。核心变量：`NODE_PORT`（默认 2222）、`SECRET_KEY`（必填）、`INTERNAL_REST_PORT`（默认 61001）。`SECRET_KEY` 支持分片拼接：当平台限制环境变量长度时，可设置 `SECRET_KEY_1`、`SECRET_KEY_2`、`SECRET_KEY_3` …，`set_default_env()` 会自动按序号拼接为 `SECRET_KEY`。

PaaS 版额外变量：

- `NODE_TLS_CLIENT_AUTH` — PaaS HTTPS 直连推荐 `none`
- `SNI_VERIFICATION` — Panel 派生 SNI 门控开关（默认 `false`，对齐官方 node 3.4.1）；开启后 watcher 自动注入 `@panel` L4 规则与 `/node/*` upstream 的 `tls_server_name`
- `GEOCHECK_BINARY_PATH` — geocheck 二进制路径覆盖（默认 `/usr/local/bin/geocheck`，裸机安装自动设置）
- `PORT` — PaaS 下发的 HTTP 回源端口；Caddy HTTP 前置优先监听该端口
- `HTTP_FRONT_ENABLED` — 是否启动 Caddy HTTP 前置（Docker 默认 `true`，裸机默认 `false`）
- `HTTP_FRONT_PORT` — Caddy HTTP 前置监听端口（默认 `${PORT:-3000}`）
- `XHTTP_UPSTREAM_PORT` / `WS_UPSTREAM_PORT` — xhttp/WebSocket 上游端口（默认 8080/8880）
- `CADDY_INDEX_PAGE` — 静态伪装页面（默认 `mikutap`，支持多个预设和自定义 URL）
- `CADDY_DEFAULT_SITE_DIR` — 镜像内置默认静态页面目录
- `INBOUND_WATCHER_ENABLED` — Inbound 动态分流开关（默认 `true`）
- `INBOUND_WATCHER_INTERVAL` — watcher 轮询间隔秒数（默认 `15`）
- `ARGO_TOKEN` — Cloudflare Tunnel Token（设置后启用 cloudflared）
- `SSH_ENABLED` — 在 `HTTP_FRONT_PORT` 上复用 SSH 入口（默认 `false`）；需同时提供 `SSH_AUTHORIZED_KEYS`
- `SSH_PORT` — 内置 sshd-lite 的本地监听端口（默认 `22222`，只绑 `127.0.0.1`）
- `SSH_AUTHORIZED_KEYS` — 登录公钥，支持 `SSH_AUTHORIZED_KEYS_1`/`_2`/`_3` 分片拼接，与 `SECRET_KEY` 同规则
- `SSH_HOST_KEY` — 可选，固定 host key 内容，避免容器重启后客户端报 host key 变化
- `SSHD_LITE_BIN` — 可选，指定已有 sshd-lite 二进制路径（设置后不下载）

## 注意事项

- 安装脚本需 root 权限，包含多发行版适配（Ubuntu/Debian/CentOS/RHEL/Fedora/Alpine）
- `INTERNAL_REST_PORT` 是内部端口，不应通过 Docker、防火墙或 PaaS 入站公开
- 不要把 PaaS 持久化卷挂载到 `/opt/rw-node` 或把 `RW_NODE_DIR` 指向空目录
- `caddy.sh` 的 `reset_directory()` 有安全目录白名单，防止误删系统目录
- `/node/stats/get-geocheck` 依赖 geocheck 二进制（镜像内置 `/usr/local/bin/geocheck`；裸机由 `ensure_geocheck` 安装并经 `GEOCHECK_BINARY_PATH` 指定），缺失时稳定降级为 A018 错误
- SSH 入口只在 TCP 直通型 PaaS 上可用；若平台是 HTTP(S) 反代或走 cloudflared 隧道，明文 `SSH-` 流量到不了容器
- SSH 登录用户名不参与认证：内置 sshd-lite（x-dora/sshd-lite）不查系统用户库，客户端填 `root`、`user` 或任意字符串完全等价。这一点是关键——OpenSSH sshd 与 dropbear 的每条认证路径都要经过 `getpwnam`/`getpwuid`，容器以 `/etc/passwd` 中不存在的虚拟 uid 运行时（PaaS、OpenShift 任意 uid 模式）无法登录，且 dropbear 的第三方补丁也只覆盖密码认证
- `SSH_ENABLED` 开启后该端口等价于对外开放一个 shell，务必只使用公钥认证并妥善保管私钥

## 提交规范

- Commit message 必须使用中文描述变更内容。
- Commit message 应遵循 Conventional Commits 格式：`<type>(<scope>): <中文摘要>`。
- 常用 `type` 包括 `feat`、`fix`、`perf`、`docs`、`refactor`、`test`、`chore`、`ci`、`build`、`revert`。
- 摘要使用简洁的中文动宾短语，不以句号结尾。
- 示例：`perf(caddy): 优化 xhttp 默认转发延迟`。
