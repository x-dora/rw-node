# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

RW-Node 是 [remnawave/node](https://github.com/remnawave/node) 的轻量化部署方案。**本仓库不包含 Node.js 应用源码**，源码来自上游仓库，通过 CI/CD 自动构建和打包。

## 架构

- **上游追踪**：`.upstream-version` 记录当前追踪的上游版本（如 `2.7.0`），由 Renovate 自动更新
- **CI/CD 流程**：`.upstream-version` 变更推送到 main 后触发 Release workflow → 克隆上游指定版本 → `npm ci && npm run build` → 打包发布 tar.gz + 构建 Docker 镜像
- **三种部署方式**：
  - Docker 镜像（`ghcr.io/x-dora/rw-node:latest` 轻量版 / `:latest-official` 官方兼容版）
  - PaaS HTTPS 直连镜像（`ghcr.io/x-dora/rw-node:latest-paas` / `:latest-go-paas`）
  - 一键脚本安装（`scripts/install.sh`，无 Docker 环境）

## 关键文件

- `scripts/install.sh` — 一键安装脚本（bash），处理 Node.js/Xray/Supervisord 安装、环境检测、systemd 配置
- `scripts/update.sh` — 更新脚本
- `scripts/uninstall.sh` — 卸载脚本
- `docker/Dockerfile` — 轻量版镜像（Go supervisord，无 Python，~380MB）
- `docker/Dockerfile.official` — 官方兼容版镜像（Python supervisord）
- `docker/Dockerfile.paas` — PaaS HTTPS 直连镜像（内置 Caddy Layer 4 前置，发布为 `:latest-paas` / `:<version>-paas`）
- `docker/Dockerfile.go-paas` — 非官方 Go 实现 PaaS HTTPS 直连镜像（发布为 `:latest-go-paas` / `:<rw-node-go-version>-go-paas`）
- `docker/docker-entrypoint.sh` / `docker-entrypoint.official.sh` — 标准容器入口脚本
- `docker/docker-entrypoint.paas.sh` / `docker-entrypoint.go-paas.sh` — PaaS 入口脚本，先启动 Caddy Layer 4 前置再启动 rw-node
- `docker/paas-caddy-front.sh` — PaaS Caddy 前置共享脚本，生成 Layer 4 TLS/HTTP 复用路由配置并加载静态伪装页面
- `config/start.sh` — 启动脚本（生成 supervisord 配置、启动服务）
- `config/systemd/rw-node.service` — systemd 服务定义
- `config/certs/free-provider-root-ca-bundle.pem` — PaaS HTTPS 直连时可追加到 Panel 数据库 `keygen.ca_cert` 的常见免费/托管平台 Root CA 参考包
- `config/env.sample` — 环境变量模板（`NODE_PORT`、`SECRET_KEY`、`XTLS_API_PORT`）
- `renovate.json` — 自动追踪上游 `remnawave/node` 新版本并提 PR

## GitHub Actions Workflows

- `release.yml` — 入口 workflow：解析版本号，按需触发 build 和 docker-build
- `build.yml` — 构建跨平台（amd64/arm64）tar.gz 发布包，创建 GitHub Release
- `docker-build.yml` — 构建并推送 Docker 镜像（轻量版 + 官方兼容版 + PaaS HTTPS 直连版，支持多架构）

## 环境变量

工作目录默认为 `/opt/rw-node`，可通过 `RW_NODE_DIR` 环境变量自定义。核心变量：`NODE_PORT`（默认 2222）、`SECRET_KEY`（必填）、`XTLS_API_PORT`（默认 61000）。

PaaS 版额外变量：

- `NODE_TLS_CLIENT_AUTH` — PaaS HTTPS 直连推荐设置为 `none`
- `PORT` — PaaS 下发的 HTTP 回源端口；Caddy HTTP 前置优先监听该端口，不存在时监听 3000
- `HTTP_FRONT_ENABLED` — 是否启动 Caddy HTTP 前置（默认 `true`；设为 `false` 时回退到旧的辅助 HTTP health server）
- `HTTP_FRONT_PORT` — Caddy HTTP 前置监听端口（默认 `${PORT:-3000}`）
- `XHTTP_UPSTREAM_PORT` — `/xh-` 前缀流量转发到的本机 xhttp 明文 HTTP 端口（默认 8080）
- `WS_UPSTREAM_PORT` — `/ws-` 前缀流量转发到的本机 WebSocket 明文 HTTP 端口（默认 8880）
- `CADDY_INDEX_PAGE` — Caddy 静态伪装页面资源（默认 `mikutap`，使用镜像内置默认页面，兼容 `CADDYIndexPage` 别名）
- `CADDY_DEFAULT_SITE_DIR` — 镜像内置默认静态页面目录（默认 `/opt/rw-node/default-www`）
- `RW_NODE_APP_DIR` — PaaS 镜像内应用文件目录（默认 `/opt/rw-node`，通常不要修改）

## 注意事项

- 所有 shell 脚本使用 `set -euo pipefail`，编辑时注意错误处理
- 安装脚本需 root 权限运行，包含多发行版（Ubuntu/Debian/CentOS/RHEL/Fedora/Alpine）适配
- Docker 镜像构建使用多阶段构建：amd64 平台构建 JS 代码，最终镜像跨平台运行
- PaaS 场景当前最推荐做法：在 Panel 端数据库 `keygen.ca_cert` 字段追加 PaaS HTTPS 域名证书链对应的一些公共证书 Root CA，节点设置 `NODE_TLS_CLIENT_AUTH=none`，Remnawave Panel 节点地址直连 PaaS 提供的 HTTPS 域名；`config/certs/free-provider-root-ca-bundle.pem` 可作为常见 Root CA 参考包
- PaaS 版默认启动 Caddy Layer 4 前置，在单端口上复用 TLS 和 HTTP 流量：TLS 连接（ClientHello）直接 TCP 代理到 `127.0.0.1:NODE_PORT`（TLS 直通，不终止）；非 TLS 连接代理到内部 `CADDY_HTTP_PORT`（= `HTTP_FRONT_PORT + 1`，自动计算）做路径路由。HTTP 路径路由规则：`/xh-*` → `127.0.0.1:8080`，`/ws-*` → `127.0.0.1:8880`（Caddy 到 Xray 一律使用明文 HTTP）；`/node/*` 和 `/vision/*` 转发到 `127.0.0.1:NODE_PORT` 的 HTTPS API（`tls_insecure_skip_verify`）；其他路径返回静态伪装页面
- `XTLS_API_PORT` 是内部端口，不应通过 Docker、VPS 防火墙或 PaaS 入站公开
- 不要把 PaaS 持久化卷挂载到 `/opt/rw-node` 或把 `RW_NODE_DIR` 指向空目录，否则会覆盖/绕开镜像内 `dist/` 和 `node_modules/`，导致入口脚本报 `application entrypoint is missing`
- 上游版本更新由 Renovate 自动提 PR，合并后自动触发完整构建和发布流程

## 提交规范

- Commit message 必须使用中文描述变更内容。
- Commit message 应遵循 Conventional Commits 格式：`<type>(<scope>): <中文摘要>`。
- 常用 `type` 包括 `feat`、`fix`、`perf`、`docs`、`refactor`、`test`、`chore`、`ci`、`build`、`revert`。
- 摘要使用简洁的中文动宾短语，不以句号结尾。
- 示例：`perf(caddy): 优化 xhttp 默认转发延迟`。
