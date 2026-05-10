# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

RW-Node 是 [remnawave/node](https://github.com/remnawave/node) 的轻量化部署方案。**本仓库不包含 Node.js 应用源码**，源码来自上游仓库，通过 CI/CD 自动构建和打包。

## 架构

- **上游追踪**：`.upstream-version` 记录当前追踪的上游版本（如 `2.7.0`），由 Renovate 自动更新
- **CI/CD 流程**：`.upstream-version` 变更推送到 main 后触发 Release workflow → 克隆上游指定版本 → `npm ci && npm run build` → 打包发布 tar.gz + 构建 Docker 镜像
- **三种部署方式**：
  - Docker 镜像（`ghcr.io/x-dora/rw-node:latest` 轻量版 / `:latest-official` 官方兼容版）
  - PaaS + FRP 反向 TCP 隧道镜像（`ghcr.io/x-dora/rw-node:latest-paas-frp`，用于 PaaS 不能公开自定义 TCP 入站端口的场景，内置 HAProxy HTTP 前置）
  - 一键脚本安装（`scripts/install.sh`，无 Docker 环境）

## 关键文件

- `scripts/install.sh` — 一键安装脚本（bash），处理 Node.js/Xray/Supervisord 安装、环境检测、systemd 配置
- `scripts/install-frps.sh` — VPS 侧 frps 一次性安装脚本，生成 `/etc/frp/frps.toml` 并配置 systemd
- `scripts/update.sh` — 更新脚本
- `scripts/uninstall.sh` — 卸载脚本
- `docker/Dockerfile` — 轻量版镜像（Go supervisord，无 Python，~380MB）
- `docker/Dockerfile.official` — 官方兼容版镜像（Python supervisord）
- `docker/Dockerfile.paas-frp` — PaaS 反向 TCP 隧道版镜像（内置 frpc + HAProxy，发布为 `:latest-paas-frp` / `:<version>-paas-frp`）
- `docker/docker-entrypoint.sh` / `docker-entrypoint.official.sh` — 标准容器入口脚本
- `docker/docker-entrypoint.paas-frp.sh` — PaaS FRP 入口脚本，先启动 HAProxy HTTP 前置，再启动 rw-node、生成 `frpc.toml`、等待本地 HTTPS 就绪后启动 frpc
- `config/start.sh` — 启动脚本（生成 supervisord 配置、启动服务）
- `config/systemd/rw-node.service` — systemd 服务定义
- `config/systemd/frps.service` — VPS 侧 frps systemd 服务模板
- `config/frp/frps.toml.example` — VPS 侧 frps 配置示例，默认控制端口 7000、节点端口池 22000-22999
- `config/env.sample` — 环境变量模板（`NODE_PORT`、`SECRET_KEY`、`XTLS_API_PORT`）
- `renovate.json` — 自动追踪上游 `remnawave/node` 新版本并提 PR

## GitHub Actions Workflows

- `release.yml` — 入口 workflow：解析版本号，按需触发 build 和 docker-build
- `build.yml` — 构建跨平台（amd64/arm64）tar.gz 发布包，创建 GitHub Release
- `docker-build.yml` — 构建并推送 Docker 镜像（轻量版 + 官方兼容版 + PaaS FRP 版，支持多架构）

## 环境变量

工作目录默认为 `/opt/rw-node`，可通过 `RW_NODE_DIR` 环境变量自定义。核心变量：`NODE_PORT`（默认 2222）、`SECRET_KEY`（必填）、`XTLS_API_PORT`（默认 61000）。

PaaS FRP 版额外变量：

- `FRP_SERVER_ADDR` — VPS 上 frps 的地址（必填）
- `FRP_SERVER_PORT` — frps 控制端口（默认 7000）
- `FRP_TOKEN` — frps/frpc 共享鉴权 token（必填）
- `FRP_PROXY_NAME` — frp 代理唯一名称（可选；不填时自动生成 `rw-node-<随机字符>`，仅允许字母、数字、点、下划线、短横线）
- `FRP_PROXY_NAME_PREFIX` — 自动生成 `FRP_PROXY_NAME` 时使用的前缀（默认 `rw-node`）
- `FRP_REMOTE_PORT` — VPS 对外暴露的节点 TCP 端口（必填，需在 frps `allowPorts` 范围内）
- `FRP_ENABLED` — 是否启动 frpc（默认 `true`）
- `FRP_WAIT_FOR_NODE` — 启动 frpc 前是否等待 `NODE_PORT` TCP 可连接（默认 `true`；必要时可设为 `false` 避免 readiness 误杀）
- `PORT` — PaaS 下发的 HTTP 回源端口；HAProxy HTTP 前置优先监听该端口，不存在时监听 3000
- `HTTP_FRONT_ENABLED` — 是否启动 HAProxy HTTP 前置（默认 `true`；设为 `false` 时回退到旧的辅助 HTTP health server）
- `HTTP_FRONT_PORT` — HAProxy HTTP 前置监听端口（默认 `${PORT:-3000}`）
- `XHTTP_UPSTREAM_PORT` — `/xh-` 前缀流量转发到的本机 xhttp 明文 HTTP 端口（默认 8080）
- `WS_UPSTREAM_PORT` — `/ws-` 前缀流量转发到的本机 WebSocket 明文 HTTP 端口（默认 8880）
- `RW_NODE_APP_DIR` — PaaS FRP 镜像内应用文件目录（默认 `/opt/rw-node`，通常不要修改）

## 注意事项

- 所有 shell 脚本使用 `set -euo pipefail`，编辑时注意错误处理
- 安装脚本需 root 权限运行，包含多发行版（Ubuntu/Debian/CentOS/RHEL/Fedora/Alpine）适配
- Docker 镜像构建使用多阶段构建：amd64 平台构建 JS 代码，最终镜像跨平台运行
- PaaS FRP 版必须保持 raw TCP 转发：Remnawave Panel → VPS `FRP_REMOTE_PORT` → frps → PaaS frpc → `127.0.0.1:NODE_PORT`，中间不能做 HTTPS 反代、TLS 终止、CDN HTTP 代理或证书替换，否则节点自签证书验证会失败
- PaaS FRP 版默认启动 HAProxy HTTP 前置用于 PaaS HTTP/HTTPS 回源场景：`${PORT:-3000}` → `/xh-*`（以 `/xh-` 开头）→ `127.0.0.1:8080`，`${PORT:-3000}` → `/ws-*`（以 `/ws-` 开头）→ `127.0.0.1:8880`；HAProxy 到 Xray 一律使用明文 HTTP
- PaaS FRP 入口脚本的 readiness 只验证 `NODE_PORT` TCP 可连接，不应使用 HTTP 状态码或 TLS 握手作为启动 frpc 的条件；如平台行为特殊，可用 `FRP_WAIT_FOR_NODE=false` 跳过
- `XTLS_API_PORT` 是内部端口，不应通过 Docker、frp、VPS 防火墙或 PaaS 入站公开
- VPS 侧 frps 只需一次性配置 `bindPort`、`auth.token` 和 `allowPorts` 端口池；新增节点时只需分配新的 `FRP_REMOTE_PORT`，`FRP_PROXY_NAME` 可手动指定或由容器自动生成，不要为每个节点修改 frps 服务端配置
- 不要把 PaaS 持久化卷挂载到 `/opt/rw-node` 或把 `RW_NODE_DIR` 指向空目录，否则会覆盖/绕开镜像内 `dist/` 和 `node_modules/`，导致入口脚本报 `application entrypoint is missing`
- 上游版本更新由 Renovate 自动提 PR，合并后自动触发完整构建和发布流程
