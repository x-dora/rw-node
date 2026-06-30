# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

RW-Node 是 [remnawave/node](https://github.com/remnawave/node) 的轻量化部署方案，使用非官方 [x-dora/rw-node-go](https://github.com/x-dora/rw-node-go) Go 实现。**本仓库不包含应用源码**，源码来自上游仓库，通过 CI/CD 自动构建和打包。

## 架构

### 上游追踪与发布

- `.go-paas-version` 记录当前追踪的 rw-node-go 版本（如 `v1.2.0`），由 Renovate 自动更新
- 代码/配置变更（`.go-paas-version`、`docker/`、`lib/`、`scripts/`、`config/`）推送到 main 后触发 `release.yml` → `docker-build.yml` → 构建多架构 Docker 镜像
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

`lib/Caddyfile.template` 是三端（Docker entrypoint / 裸机 start.sh / reality-watcher）共用的 Caddy 配置模板，使用 `${PLACEHOLDER}` 占位符，由 `write_caddy_config()` (bash)、`generateCaddyConfig()` (JS/Python) 做字符串替换生成最终 Caddyfile。

### REALITY 动态分流

后台 watcher 轮询 rw-node-go 内部 API（`/internal/get-config`），提取 REALITY inbound 的 `serverNames` 和端口，自动生成 Caddy L4 SNI 分流规则并热重载。三种后端按优先级自动选择：jq（内嵌在 `caddy.sh`） > Node.js（`reality-watcher.js`） > Python（`reality-watcher.py`）。

### 流量路由（PaaS 单端口复用）

Caddy Layer 4 在 `HTTP_FRONT_PORT` 上做 TLS/非 TLS 分流：
- TLS ClientHello → TCP 直通到 `NODE_PORT`（不终止 TLS）
- REALITY SNI 匹配 → TCP 直通到 Xray 端口（watcher 动态注入）
- 非 TLS → 内部 `CADDY_HTTP_PORT`（= `HTTP_FRONT_PORT + 1`）做 HTTP 路径路由：
  - `/xh-*` → `XHTTP_UPSTREAM_PORT`（明文 HTTP）
  - `/ws-*` → `WS_UPSTREAM_PORT`（明文 HTTP）
  - `/node/*`、`/vision/*` → `NODE_PORT` HTTPS API（`tls_insecure_skip_verify`）
  - 其他 → 静态伪装页面

## 关键文件

- `scripts/install.sh` — 一键安装脚本（bash），安装 rw-node-go、Caddy L4、Xray geodata、共享库
- `scripts/uninstall.sh` — 卸载脚本
- `docker/Dockerfile` — Go 实现 PaaS HTTPS 直连镜像
- `docker/docker-entrypoint.sh` — PaaS 入口脚本，启动 Caddy L4 前置 + rw-node-go + REALITY watcher
- `lib/core.sh` — 核心工具库
- `lib/caddy.sh` — Caddy 管理（含 jq 版 REALITY watcher）
- `lib/Caddyfile.template` — Caddy 配置模板（三端共用）
- `lib/provision.sh` — 组件下载安装库
- `lib/cloudflared.sh` — Cloudflare Tunnel 管理
- `lib/reality-watcher.js` / `lib/reality-watcher.py` — REALITY watcher 的 Node.js/Python 后端
- `config/start.sh` — 裸机启动脚本（source lib/ 共享库）
- `config/systemd/rw-node.service` — systemd 服务定义
- `config/env.sample` — 环境变量模板
- `renovate.json` — Renovate 配置，自动追踪上游版本

## 开发与测试

### 本地 Docker 构建

```bash
docker build -f docker/Dockerfile -t rw-node:test .
docker run --rm -e SECRET_KEY=test -e NODE_PORT=2222 rw-node:test
```

构建参数 `RW_NODE_GO_VERSION` 可指定版本（默认 latest）。

### Shell 脚本检查

所有 shell 脚本使用 `set -euo pipefail`，并包含 `# shellcheck shell=bash` 指令。使用 shellcheck 检查：

```bash
shellcheck lib/*.sh config/start.sh docker/docker-entrypoint.sh scripts/*.sh
```

### 入口脚本对比

| 特性 | `docker/docker-entrypoint.sh` | `config/start.sh` |
|------|------|------|
| `HTTP_FRONT_ENABLED` 默认值 | `true` | `false` |
| .env 文件加载 | 不加载（Docker env） | `load_env_file` |
| 健康检查 | PaaS `PORT` 上的 busybox httpd | 无 |
| Lib 路径 | `/usr/local/lib/rw-node/` | `${WORK_DIR}/lib/` |

### Dry run / 环境检查

`core.sh` 内置两个调试机制：
- `RW_NODE_STARTER_INSPECT_ENV=1` — 打印所有解析后的环境变量并退出
- `RW_NODE_STARTER_DRY_RUN_EXIT=0` — 加载配置后以指定退出码退出，不启动进程

## 环境变量

工作目录默认 `/opt/rw-node`，可通过 `RW_NODE_DIR` 自定义。核心变量：`NODE_PORT`（默认 2222）、`SECRET_KEY`（必填）、`INTERNAL_REST_PORT`（默认 61001）。

PaaS 版额外变量：

- `NODE_TLS_CLIENT_AUTH` — PaaS HTTPS 直连推荐 `none`
- `PORT` — PaaS 下发的 HTTP 回源端口；Caddy HTTP 前置优先监听该端口
- `HTTP_FRONT_ENABLED` — 是否启动 Caddy HTTP 前置（Docker 默认 `true`，裸机默认 `false`）
- `HTTP_FRONT_PORT` — Caddy HTTP 前置监听端口（默认 `${PORT:-3000}`）
- `XHTTP_UPSTREAM_PORT` / `WS_UPSTREAM_PORT` — xhttp/WebSocket 上游端口（默认 8080/8880）
- `CADDY_INDEX_PAGE` — 静态伪装页面（默认 `mikutap`，支持多个预设和自定义 URL）
- `CADDY_DEFAULT_SITE_DIR` — 镜像内置默认静态页面目录
- `REALITY_SPLIT_ENABLED` — REALITY TLS 动态分流开关（默认 `true`）
- `REALITY_SPLIT_INTERVAL` — watcher 轮询间隔秒数（默认 `15`）
- `ARGO_TOKEN` — Cloudflare Tunnel Token（设置后启用 cloudflared）

## 注意事项

- 安装脚本需 root 权限，包含多发行版适配（Ubuntu/Debian/CentOS/RHEL/Fedora/Alpine）
- `INTERNAL_REST_PORT` 是内部端口，不应通过 Docker、防火墙或 PaaS 入站公开
- 不要把 PaaS 持久化卷挂载到 `/opt/rw-node` 或把 `RW_NODE_DIR` 指向空目录
- `CADDY_HTTP_PORT` 由 `HTTP_FRONT_PORT + 1` 自动计算，不可直接配置
- `caddy.sh` 的 `reset_directory()` 有安全目录白名单，防止误删系统目录

## 提交规范

- Commit message 必须使用中文描述变更内容。
- Commit message 应遵循 Conventional Commits 格式：`<type>(<scope>): <中文摘要>`。
- 常用 `type` 包括 `feat`、`fix`、`perf`、`docs`、`refactor`、`test`、`chore`、`ci`、`build`、`revert`。
- 摘要使用简洁的中文动宾短语，不以句号结尾。
- 示例：`perf(caddy): 优化 xhttp 默认转发延迟`。
