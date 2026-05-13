# RW-Node 轻量化部署

Remnawave Node 轻量化部署方案，**无需 Python**。

## 功能特性

- 🚀 一键安装/卸载/更新（无需 Docker）
- 🐳 轻量化 Docker 镜像（无 Python，使用 Go 版 Supervisord）
- 📦 容器环境自动检测（支持 Docker/LXC/Podman）
- 🌐 内置 Cloudflare Tunnel 支持（可选）
- 🔄 自动同步上游版本构建

## 部署方式

### 方式一：Docker 部署（推荐）

**镜像版本：**

| 标签 | 描述 | 大小 |
|------|------|------|
| `ghcr.io/x-dora/rw-node:latest` | 轻量版 (Go Supervisord, 无 Python) | **~380MB** |
| `ghcr.io/x-dora/rw-node:latest-official` | 官方兼容版 (Python Supervisord) | ~450MB |
| `ghcr.io/x-dora/rw-node:latest-paas-frp` | PaaS HTTPS 直连版 (历史标签名，内置 HAProxy HTTP 前置；frpc 后续会删除) | ~400MB |
| `ghcr.io/x-dora/rw-node:latest-go-paas-frp` | 非官方 Go 实现 PaaS HTTPS 直连版 (历史标签名；frpc 后续会删除) | 更小 |

```bash
# 轻量版（推荐）
docker run -d \
  --name rw-node \
  --restart unless-stopped \
  -e NODE_PORT=2222 \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e XTLS_API_PORT=61000 \
  -p 2222:2222 \
  ghcr.io/x-dora/rw-node:latest

# 官方兼容版
docker run -d \
  --name rw-node \
  --restart unless-stopped \
  -e NODE_PORT=2222 \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e XTLS_API_PORT=61000 \
  -p 2222:2222 \
  ghcr.io/x-dora/rw-node:latest-official
```

Docker Compose:

```yaml
services:
  rw-node:
    image: ghcr.io/x-dora/rw-node:latest  # 或 :latest-official
    container_name: rw-node
    restart: unless-stopped
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=YOUR_SECRET_KEY
      - XTLS_API_PORT=61000
    ports:
      - "2222:2222"
```

### 方式一补充：PaaS HTTPS 直连（推荐）

现在 PaaS 场景最推荐的接入方式是直接使用 PaaS 分配的 HTTPS 域名，不再通过 `frpc -> frps` 反向 TCP 隧道。核心思路是让 Remnawave Panel 信任 PaaS HTTPS 域名所用证书链的公共 Root CA，然后让节点主 API 不再要求客户端证书。

推荐链路：

```text
Remnawave Panel -> https://<paas-domain> -> PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /node/* -> 127.0.0.1:NODE_PORT
```

需要做两处配置：

1. 在 Panel 端数据库中找到 `keygen` 记录，把 PaaS HTTPS 域名证书链对应的一些公共证书 Root CA 追加到 `ca_cert` 字段。
2. 在 PaaS 节点环境变量中设置 `NODE_TLS_CLIENT_AUTH=none`，然后在 Remnawave Panel 的节点地址里填写 PaaS 提供的 HTTPS 域名。

这样 Panel 可以通过正常的公共 CA 链校验 PaaS HTTPS 域名，节点侧也不会再因为 PaaS/HAProxy 前置无法透传客户端证书而拒绝连接。`frpc`、VPS `frps`、`FRP_REMOTE_PORT` 都不再是推荐部署所需组件。

仓库提供了一个常见免费/托管平台 Root CA 参考包：`config/certs/free-provider-root-ca-bundle.pem`。它包含 Let's Encrypt、Google Trust Services、Sectigo/USERTrust 的 8 张 Root CA，适合作为追加到 `keygen.ca_cert` 的起点；具体列表见 `config/certs/README.md`。如果 PaaS 使用自定义域名证书、私有 CA、企业代理证书或特殊区域证书链，需要额外追加实际链路对应的 Root CA。

当前 PaaS 镜像仍然沿用 `latest-paas-frp` / `latest-go-paas-frp` 这两个历史标签名，并且镜像内暂时还包含 frpc。后续版本会删除 frpc 相关能力，新的部署不建议再依赖 FRP 链路。

如果想使用非官方的 Go 实现，可以改用 `latest-go-paas-frp`。Go 实现来自 [x-dora/rw-node-go](https://github.com/x-dora/rw-node-go)，版本跟随 `rw-node-go` 自己的 release，不跟随 `remnawave/node` 的上游版本号。

PaaS 镜像默认会启动 HAProxy HTTP 前置，监听 `${PORT:-3000}`。当 PaaS 提供 HTTP/HTTPS 回源端口时，可以用同一个公网端口按路径前缀分流到本机 Xray inbound，并把 Panel 主 API 路径转发到本机 `NODE_PORT`。

```text
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /xh-* -> 127.0.0.1:8080
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /ws-* -> 127.0.0.1:8880
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /node/* -> 127.0.0.1:NODE_PORT (HTTPS, verify none)
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /vision/* -> 127.0.0.1:NODE_PORT (HTTPS, verify none)
```

这里的 `/xh-*` 和 `/ws-*` 表示路径分别以 `/xh-` 和 `/ws-` 开头，例如 `/xh-a`、`/xh-test`、`/ws-a`。HAProxy 到 Xray 使用明文 HTTP，不做 HTTPS upstream。`/node/*` 和 `/vision/*` 会转发到本机 `NODE_PORT` 的 HTTPS 服务，并跳过 upstream 证书校验，以兼容节点自签证书。

#### PaaS 侧环境变量

使用镜像：

```text
ghcr.io/x-dora/rw-node:latest-paas-frp
```

Go 实现镜像：

```text
ghcr.io/x-dora/rw-node:latest-go-paas-frp
```

必填环境变量：

| 变量名 | 描述 | 示例 |
|--------|------|------|
| `SECRET_KEY` | Remnawave Panel 中的节点密钥 | `YOUR_SECRET_KEY` |

常用可选环境变量：

| 变量名 | 默认值 | 描述 |
|--------|--------|------|
| `NODE_PORT` | `2222` | rw-node 容器内 HTTPS 监听端口 |
| `NODE_TLS_CLIENT_AUTH` | `mtls` | PaaS HTTPS 直连推荐设置为 `none`，避免 PaaS/HAProxy 前置无法透传客户端证书导致 Panel 连接失败 |
| `XTLS_API_PORT` | `61000` | Xray API 内部端口，不要公开 |
| `INTERNAL_REST_PORT` | `61001` | Go 实现镜像的本机 internal REST 端口，不要公开 |
| `FRP_ENABLED` | `true` | 推荐设置为 `false` 禁用 frpc；frpc 将在后续版本删除 |
| `PORT` | - | PaaS 下发的 HTTP 回源端口；HAProxy 优先监听该端口 |
| `HTTP_FRONT_ENABLED` | `true` | 是否启动 HAProxy HTTP 前置；设为 `false` 时回退为旧的简单 health server |
| `HTTP_FRONT_PORT` | `${PORT:-3000}` | HAProxy HTTP 前置监听端口，通常不需要手动设置 |
| `XHTTP_UPSTREAM_PORT` | `8080` | `/xh-` 前缀流量转发到的本机 xhttp 明文 HTTP 端口 |
| `WS_UPSTREAM_PORT` | `8880` | `/ws-` 前缀流量转发到的本机 WebSocket 明文 HTTP 端口 |
| `RW_NODE_APP_DIR` | `/opt/rw-node` | PaaS FRP 镜像内应用文件目录，通常不要修改 |

PaaS 示例：

```bash
docker run -d \
  --name rw-node-paas \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e NODE_PORT=2222 \
  -e NODE_TLS_CLIENT_AUTH=none \
  -e XTLS_API_PORT=61000 \
  -e FRP_ENABLED=false \
  ghcr.io/x-dora/rw-node:latest-paas-frp
```

Go 实现 PaaS 示例：

```bash
docker run -d \
  --name rw-node-go-paas \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e NODE_PORT=2222 \
  -e NODE_TLS_CLIENT_AUTH=none \
  -e INTERNAL_REST_PORT=61001 \
  -e FRP_ENABLED=false \
  ghcr.io/x-dora/rw-node:latest-go-paas-frp
```

Remnawave Panel 中节点地址填写 PaaS 提供的 HTTPS 域名，例如：

```text
https://rw-node.example-paas.app
```

Panel 数据库 `keygen.ca_cert` 字段需要包含该 HTTPS 域名证书链对应的公共 Root CA，否则 Panel 仍可能因为不信任 PaaS 证书链而拒绝连接。可以参考 `config/certs/free-provider-root-ca-bundle.pem`，但最终以实际 PaaS 域名的证书链为准。

如果使用 HAProxy HTTP 前置承载 xhttp/ws 流量，则客户端或面板下发的 xhttp/ws 配置应填写 PaaS 提供的 HTTP/HTTPS 域名和单个公网端口，并用不同路径前缀区分协议。xhttp inbound 固定监听本机 `8080` 明文 HTTP，ws inbound 固定监听本机 `8880` 明文 HTTP。`/xh`、`/xh/abc`、`/ws`、`/ws/abc` 不会匹配前置规则，只有以 `/xh-` 或 `/ws-` 开头的路径会被转发。

如果日志出现 `application entrypoint is missing` 或旧版本中的 `application files are missing in /opt/rw-node`，优先检查 PaaS 是否把持久化卷挂载到了 `/opt/rw-node` 并覆盖了镜像内应用文件。PaaS FRP 镜像默认会从 `/opt/rw-node` 读取应用文件；不要把空卷挂载到这个路径，也不要把 `RW_NODE_DIR` 指向不包含 `dist/`、`node_modules/` 的目录。

#### FRP 旧方案

FRP 反向 TCP 隧道是旧方案，仅建议已有部署临时保留。后续版本会删除 frpc，因此不建议新部署继续配置 `FRP_SERVER_ADDR`、`FRP_TOKEN`、`FRP_REMOTE_PORT`、VPS `frps` 或端口池。

旧 FRP 链路如下：

```text
Remnawave Panel -> VPS:FRP_REMOTE_PORT -> frps -> PaaS frpc -> 127.0.0.1:NODE_PORT -> rw-node HTTPS
```

如果仍需临时使用旧方案，需要自行维护 VPS 侧 `frps`、`allowPorts` 端口池和 PaaS 侧 FRP 环境变量。迁移到 HTTPS 直连后，应设置 `FRP_ENABLED=false` 并移除 VPS 侧对应端口开放。

### 方式二：一键脚本安装

#### 系统要求

- Linux（Ubuntu/Debian/CentOS/RHEL/Fedora/Alpine）
- x86_64 或 arm64 架构
- Root 权限
- bash 和 curl（大多数系统已预装）

> 安装器会自动补齐 git / unzip / jq / xz 等依赖，**无需 Python**

#### 安装

```bash
# 一键安装
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh)

# 安装时启用 Cloudflare Tunnel
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) --with-cloudflared

# 指定版本
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/2.5.2/scripts/install.sh) --version 2.5.2

# 静默安装（无交互）
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --secret-key YOUR_SECRET_KEY \
  --port 2222

# 非官方 Go 实现最简安装（无 Node.js / Supervisord / 外部 Xray）
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --impl go \
  --secret-key YOUR_SECRET_KEY \
  --port 2222 \
  --node-tls-client-auth mtls

# 固定 rw-node-go 版本
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --impl go \
  --go-version v1.0.3 \
  --secret-key YOUR_SECRET_KEY \
  --port 2222
```

`--impl go` 使用 [x-dora/rw-node-go](https://github.com/x-dora/rw-node-go) 的 release 包，是非官方 Go 实现；它的 `--go-version` 跟随 `rw-node-go` 的 `v1.x` 项目版本，不是 `remnawave/node` 的 `2.x` 版本。默认不传 `--impl` 时仍安装官方 JS 兼容实现。

#### 管理命令

**有 Systemd 的环境（物理机/VM）：**

```bash
# 服务管理
systemctl {start|stop|restart|status} rw-node

# 查看日志
journalctl -u rw-node -f
```

**容器/无 Systemd 环境：**

```bash
# 启动
rw-node-start

# 停止
rw-node-stop

# 状态
rw-node-status
```

**通用命令：**

```bash
# Xray 日志
xlogs
xerrors

# 更新
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/update.sh)

# 卸载
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/uninstall.sh)
```

## 环境变量

| 变量名 | 描述 | 默认值 |
|--------|------|--------|
| `NODE_PORT` | 节点端口 | `2222` |
| `SECRET_KEY` | 面板密钥 | - |
| `NODE_TLS_CLIENT_AUTH` | Go 模式主 API 的 TLS 客户端证书策略；PaaS HTTPS 直连推荐设为 `none` | `mtls` |
| `XTLS_API_PORT` | Xray API 端口 | `61000` |
| `INTERNAL_REST_PORT` | Go 模式本机 Internal REST 端口，不要公开 | `61001` |
| `RW_NODE_DIR` | 工作目录（所有文件存放位置） | `/opt/rw-node` |
| `FRP_ENABLED` | 是否启动旧 FRP frpc；PaaS HTTPS 直连推荐设为 `false`，后续会删除 frpc | `true` |
| `FRP_SERVER_ADDR` | 旧 FRP 方案使用的 frps 地址，新部署不推荐配置 | - |
| `FRP_SERVER_PORT` | 旧 FRP 方案使用的 frps 端口 | `7000` |
| `FRP_TRANSPORT_PROTOCOL` | 旧 FRP 方案中 frpc 连接 frps 的传输协议，可选 `tcp`、`websocket`、`wss` | `tcp` |
| `FRP_TLS_SERVER_NAME` | 旧 FRP 方案 WSS/TLS 连接使用的 SNI/ServerName，`wss` 模式不填时自动使用 `FRP_SERVER_ADDR` | `FRP_SERVER_ADDR` |
| `FRP_TLS_TRUSTED_CA_FILE` | 旧 FRP 方案 WSS/TLS 连接使用的自定义 CA 文件路径 | - |
| `FRP_TOKEN` | 旧 FRP 方案使用的 frps token | - |
| `FRP_PROXY_NAME` | 旧 FRP 方案代理名称，不填则自动生成 | `rw-node-<随机字符>` |
| `FRP_PROXY_NAME_PREFIX` | 旧 FRP 方案自动代理名前缀 | `rw-node` |
| `FRP_REMOTE_PORT` | 旧 FRP 方案 VPS 公网节点端口 | - |

### 自定义工作目录

所有配置、日志、运行时文件都存放在工作目录中（默认 `/opt/rw-node`）：

```bash
# 安装时指定工作目录
RW_NODE_DIR=/data/rw-node bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh)

# Docker 使用默认工作目录（镜像内固定为 `/opt/rw-node`）
docker run -d \
  -e NODE_PORT=2222 \
  -e SECRET_KEY=YOUR_KEY \
  ghcr.io/x-dora/rw-node:latest
```

## 与官方镜像的区别

| 特性 | 官方镜像 | 本项目轻量版 | 本项目官方兼容版 |
|------|----------|-------------|-----------------|
| Python | ✅ 需要 | ❌ 不需要 | ✅ 需要 |
| Supervisord | Python 版 | Go 版 | Python 版 |
| 镜像大小 | ~480MB | **~380MB** | ~450MB |
| node_modules 优化 | ❌ | ✅ | ✅ |
| 健康检查 | ❌ | ✅ | ✅ |
| 容器环境检测 | ❌ | ✅ | ✅ |

## 目录结构

所有文件统一存放在工作目录（默认 `/opt/rw-node`）：

```
${RW_NODE_DIR}/                 # 工作目录（默认 /opt/rw-node）
├── .env                        # 环境变量配置
├── start.sh                    # 启动脚本
├── dist/                       # 编译后的代码
├── libs/                       # 库文件
├── node_modules/               # 依赖
├── node/                       # Node.js 二进制
├── package.json
├── bin/                        # 可执行文件
│   ├── xray                    # Xray 内核
│   ├── rw-core -> xray         # Xray 符号链接
│   ├── supervisord             # Supervisord (Go 版)
│   ├── cloudflared             # Cloudflare Tunnel（可选）
│   ├── xlogs                   # 日志查看脚本
│   ├── xerrors                 # 错误日志脚本
│   └── rw-node-status          # 状态查看脚本
├── share/
│   └── xray/                   # Xray 资源文件
│       ├── geoip.dat
│       └── geosite.dat
├── conf/                       # 运行时配置
│   └── supervisord.conf        # 动态生成
├── run/                        # 运行时文件
│   ├── supervisord-*.sock
│   ├── supervisord-*.pid
│   └── remnawave-internal-*.sock
└── logs/                       # 日志文件
    ├── supervisord.log
    ├── xray.out.log
    └── xray.err.log
```

## 许可证

AGPL-3.0-only

## 相关链接

- [Remnawave Panel 文档](https://docs.rw/)
- [原始 Node 仓库](https://github.com/remnawave/node)
- [Go Supervisord](https://github.com/ochinchina/supervisord)
