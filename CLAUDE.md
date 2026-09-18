# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

RW-Node 是 [remnawave/node](https://github.com/remnawave/node) 的轻量化部署方案，使用非官方 [x-dora/rw-node-go](https://github.com/x-dora/rw-node-go) Go 实现。**本仓库不包含应用源码**，源码来自上游仓库，通过 CI/CD 自动构建和打包。

## 架构

### 上游追踪与发布

- `.go-paas-version` 记录当前追踪的 rw-node-go 版本（如 `v1.2.0`），由 Renovate 自动更新
- `.front-version` 记录当前追踪的 rw-node-front 版本（前置分流进程，独立仓库），同样由 Renovate 更新
- 代码/配置变更（上述版本文件、`Dockerfile`、`docker-entrypoint.sh`、`lib/`、`scripts/`、`config/`）推送到 main 后触发 `release.yml` → `docker-build.yml` → 构建多架构 Docker 镜像
- 手动触发 `workflow_dispatch` 可强制构建指定版本

### 两种部署方式

- **Docker 镜像**（`ghcr.io/x-dora/rw-node:latest`）：Alpine 基础镜像，构建时下载 rw-node-go + rw-node-front，PaaS HTTPS 直连场景
- **一键脚本安装**（`scripts/install.sh`）：无 Docker 环境的裸机部署，自动安装 rw-node-go、rw-node-front、Xray geodata

### Shell 库架构

`lib/` 下的 shell 库使用 include guard 防重复加载（如 `_RW_NODE_CORE_LOADED`），依赖链：

```
core.sh  ← 基础（日志、.env 解析、端口校验、架构检测）
  ├── front.sh       ← 前置进程启动（依赖 site.sh，导出前端需要的环境变量）
  │     └── site.sh  ← 静态伪装页准备（下载/解压/发布，带目录安全白名单）
  ├── ssh.sh         ← sshd-lite 启动与降级
  ├── provision.sh   ← GitHub Release 下载（rw-node-go、rw-node-front、sshd-lite、cloudflared）
  └── cloudflared.sh ← Cloudflare Tunnel 启动
```

每个库文件开头通过 `source "${LIB_DIR}/core.sh"` 自动加载依赖，调用方只需 source 所需的顶层库。

### 前置分流（rw-node-front）

前置层是独立仓库 [x-dora/rw-node-front](https://github.com/x-dora/rw-node-front) 发布的一个进程，取代了原先的 Caddy + inbound watcher 组合。它在一个对外端口上按连接首字节分流（SSH / TLS / 明文 HTTP），自己轮询 `/internal/get-config` 并在进程内维护路由表、整体原子替换。版本由 `.front-version` 钉住，Renovate 自动更新。

之所以换掉 Caddy：实测**现网运行**的 Caddy 在 layer4 直通、file_server、reverse_proxy 三条路径上，每个字节都要走一遍用户态 `read()`/`write()`（传输 8 MiB 时 `rchar` 增加 8.44 MB），而两端都是裸 `*net.TCPConn` 时 `io.Copy` 会命中内核 `splice`（同样量级传输 `rchar` 只增加 189 字节）。在 CPU 配额被压到 0.15 核的 PaaS 上，这个差别直接换算成可承载带宽。附带收益是组件从 48MB Caddy + 26MB Python watcher 降到约 10MB 二进制、3MB 常驻。

两个入口脚本（`docker-entrypoint.sh` / `config/start.sh`）通过 `set_default_env()` 统一设置环境变量默认值，并由 `export_front_env()` 把前置进程需要的变量显式导出给它。

### 路由表刷新

前置进程按 `INBOUND_WATCHER_INTERVAL`（默认 15 秒）轮询 `/internal/get-config`，把 Xray config 解析成分流路由表后**整体原子替换**。支持 REALITY SNI 分流（L4 层）和 ws/xhttp/httpupgrade 路径分流（L4 裸转发），含冲突检测和兜底路由。

选择轮询而非推送：那需要在 rw-node-go 里加配置变更通知，而它的定位是对齐官方 remnawave/node 的 Panel-facing contract，不适合塞前端专用机制。轮询的代价在这个进程里也很低——解析只有一份 Go 实现、没有跨进程热重载、失败时保留上一份可用路由表（继续用一份稍旧的配置，比让全部分流失效安全）。

解析容错原则：任何字段缺失、类型不符或取值越界都只让该条 inbound 不参与分流，而不是让整份配置解析失败。注意 `port` 必须是 JSON **数字**——`json.Number` 的底层是 string，会把 `"port": "20002"` 这种字符串数字也当合法值收下，因此用 `any` + `float64` 断言。

### 流量路由（PaaS 单端口复用）

前置进程在 `HTTP_FRONT_PORT` 上靠连接首字节分流（各分支互斥）：

- **SSH**（首 4 字节 `SSH-`）→ TCP 直通到内置 sshd-lite；仅在 `SSH_ENABLED=true` 且提供公钥时启用
- **TLS ClientHello**（`0x16`）→ 解析 SNI 后直通：命中 REALITY `serverNames` 转对应 Xray 端口，其余（含 Panel SNI）转 `NODE_PORT`，全程**不终止 TLS**
- **其余按明文 HTTP 处理**，按路径决定：
  - `/health` → 本进程应答
  - `/node/*`、`/vision/*` → 反代 `NODE_PORT`（HTTPS；`SNI_VERIFICATION` 开启时带上派生的 Panel SNI）
  - 配置下发的 inbound 路径 → 对应 inbound 端口（**裸转发**）
  - `/xh-*` → `XHTTP_UPSTREAM_PORT`、`/ws-*` → `WS_UPSTREAM_PORT`（**裸转发**）
  - 其他 → 静态伪装页面

路径分流刻意放在 L4 而不是交给 `httputil.ReverseProxy`：后者在协议升级后同样是用户态 `io.CopyBuffer`，ws/xhttp 这个主流量就和 Caddy 一样吃不到 splice。直通路径先把 peek 到的首部字节补写出去，再用未被包装的 `*net.TCPConn` 做 `io.Copy`——用户态字节数因此恒等于首部大小，与传输总量无关（`bench/forward` 的 peek 模式验证过）。

Panel SNI 由前置进程自己从 `SECRET_KEY` 派生（复刻 rw-node-go 的 HKDF 链），不再依赖 `/internal/get-config` 注入的 `panelSni` 字段；派生逻辑必须与 rw-node-go 逐字节一致，golden 值钉在 rw-node-front 的测试里。

## 关键文件

- `scripts/install.sh` — 一键安装脚本（bash），安装 rw-node-go、rw-node-front、Xray geodata、共享库
- `scripts/uninstall.sh` — 卸载脚本
- `Dockerfile` — Go 实现 PaaS HTTPS 直连镜像
- `docker-entrypoint.sh` — PaaS 入口脚本，启动 rw-node-front 前置 + rw-node-go
- `lib/core.sh` — 核心工具库
- `lib/front.sh` — 前置进程启动（导出前端需要的环境变量、等待健康检查）
- `lib/site.sh` — 静态伪装页准备（下载/解压/发布，带目录安全白名单）
- `lib/ssh.sh` — sshd-lite 启动与降级
- `lib/provision.sh` — 组件下载安装库
- `lib/cloudflared.sh` — Cloudflare Tunnel 管理
- `.front-version` — 钉住 rw-node-front 版本，由 Renovate 更新
- `bench/forward` — TCP 转发性能对照工具（splice / buffer / peek 三种模式）
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
- `PORT` — PaaS 下发的 HTTP 回源端口；前置进程优先监听该端口
- `HTTP_FRONT_ENABLED` — 是否启动前置分流进程（Docker 默认 `true`，裸机默认 `false`）
- `HTTP_FRONT_PORT` — 前置进程监听端口（默认 `${PORT:-3000}`）
- `XHTTP_UPSTREAM_PORT` / `WS_UPSTREAM_PORT` — xhttp/WebSocket 上游端口（默认 8080/8880）
- `FRONT_INDEX_PAGE` — 静态伪装页面（默认 `mikutap`，支持多个预设和自定义 URL；旧名 `CADDY_INDEX_PAGE` 仍可用）
- `FRONT_DEFAULT_SITE_DIR` — 镜像内置默认静态页面目录
- `INBOUND_WATCHER_ENABLED` — 路由表刷新开关（默认 `true`）
- `INBOUND_WATCHER_INTERVAL` — 轮询 `/internal/get-config` 的间隔秒数（默认 `15`）
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
- `site.sh` 的 `reset_directory()` 有安全目录白名单，防止误删系统目录
- `/node/stats/get-geocheck` 依赖 geocheck 二进制（镜像内置 `/usr/local/bin/geocheck`；裸机由 `ensure_geocheck` 安装并经 `GEOCHECK_BINARY_PATH` 指定），缺失时稳定降级为 A018 错误
- SSH 入口只在 TCP 直通型 PaaS 上可用；若平台是 HTTP(S) 反代或走 cloudflared 隧道，明文 `SSH-` 流量到不了容器
- SSH 登录用户名不参与认证：内置 sshd-lite（x-dora/sshd-lite）不查系统用户库，客户端填 `root`、`user` 或任意字符串完全等价。这一点是关键——OpenSSH sshd 与 dropbear 的每条认证路径都要经过 `getpwnam`/`getpwuid`，容器以 `/etc/passwd` 中不存在的虚拟 uid 运行时（PaaS、OpenShift 任意 uid 模式）无法登录，且 dropbear 的第三方补丁也只覆盖密码认证
- `SSH_ENABLED` 开启后该端口等价于对外开放一个 shell，务必只使用公钥认证并妥善保管私钥

## 提交规范

- Commit message 必须使用中文描述变更内容。
- Commit message 应遵循 Conventional Commits 格式：`<type>(<scope>): <中文摘要>`。
- 常用 `type` 包括 `feat`、`fix`、`perf`、`docs`、`refactor`、`test`、`chore`、`ci`、`build`、`revert`。
- 摘要使用简洁的中文动宾短语，不以句号结尾。
- 示例：`perf(front): 优化 xhttp 默认转发延迟`。
