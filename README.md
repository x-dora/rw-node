# RW-Node 轻量化部署

RW-Node 是 [remnawave/node](https://github.com/remnawave/node) 的轻量化部署与打包方案，目标是在不改动上游业务逻辑的前提下，降低节点部署体积和运行依赖，并提供适合 VPS、容器和 PaaS 平台的开箱即用镜像与脚本。

本仓库**不维护 Remnawave Node 的应用源码**。应用源码来自上游 `remnawave/node`，本项目通过 GitHub Actions 按 `.upstream-version` 指定的上游版本自动拉取、构建、裁剪生产依赖并发布安装包和 Docker 镜像。因此，本项目更接近“构建/分发/部署层”，不是 Remnawave Node 的功能分叉。

项目提供四类交付物：

- 轻量 Docker 镜像：使用 Go 版 Supervisord，去掉 Python 运行时，适合常规 Docker 部署。
- 官方兼容 Docker 镜像：保留 Python Supervisord，尽量贴近官方镜像行为。
- PaaS HTTPS 直连镜像：内置 HAProxy HTTP 前置，支持在只提供 HTTP/HTTPS 回源端口的平台上按路径分流 `/node/*`、`/vision/*`、`/xh-*`、`/ws-*`。
- 一键脚本安装：适合没有 Docker 的 VPS/容器环境，自动安装 Node.js、Xray-core、Supervisord、systemd 服务或前台运行辅助脚本。

除官方 JS 兼容实现外，安装脚本和 PaaS 镜像还支持非官方 Go 实现 [x-dora/rw-node-go](https://github.com/x-dora/rw-node-go)。Go 实现用于更小体积和更少运行时依赖，但版本号、行为和上游 `remnawave/node` 不完全绑定；需要严格兼容官方 Node 行为时，应优先使用 JS 兼容实现。

典型使用场景：

- 在 VPS 上用一键脚本部署 Remnawave Node，并由 systemd 管理服务。
- 在 Docker / Compose 中运行轻量版或官方兼容版镜像。
- 在 Render、Koyeb、Railway、Fly.io 等 PaaS 场景中，通过平台 HTTPS 域名直连 Panel 和节点。
- 在只有单个公网 HTTP/HTTPS 端口的环境中，用 HAProxy 前置把 API、xhttp、WebSocket 流量按路径分流到本机不同端口。

需要注意的是，本项目不会替代 Remnawave Panel，也不会修改 Panel 的证书校验逻辑。PaaS HTTPS 直连场景下，仍需要在 Panel 端信任 PaaS 域名证书链对应的 Root CA，并按实际网络链路配置 `NODE_TLS_CLIENT_AUTH`、节点地址和 inbound 路径。

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
| `ghcr.io/x-dora/rw-node:latest-paas` | PaaS HTTPS 直连版 (内置 HAProxy HTTP 前置) | ~400MB |
| `ghcr.io/x-dora/rw-node:latest-go-paas` | 非官方 Go 实现 PaaS HTTPS 直连版 | 更小 |

除 `latest*` 标签外，Release workflow 也会发布固定版本标签：

- `ghcr.io/x-dora/rw-node:<version>`：轻量版，例如 `2.7.0`
- `ghcr.io/x-dora/rw-node:<version>-official`：官方兼容版
- `ghcr.io/x-dora/rw-node:<version>-paas`：PaaS HTTPS 直连版
- `ghcr.io/x-dora/rw-node:<rw-node-go-version>-go-paas`：Go 实现 PaaS 版，例如 `v1.0.3-go-paas`

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

PaaS 场景推荐直接使用 PaaS 分配的 HTTPS 域名。核心思路是让 Remnawave Panel 信任 PaaS HTTPS 域名所用证书链的公共 Root CA，然后让节点主 API 不再要求客户端证书。

推荐链路：

```text
Remnawave Panel -> https://<paas-domain> -> PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /node/* -> 127.0.0.1:NODE_PORT
```

需要做两处配置：

1. 在 Panel 端数据库中找到 `keygen` 记录，把 PaaS HTTPS 域名证书链对应的一些公共证书 Root CA 追加到 `ca_cert` 字段。
2. 在 PaaS 节点环境变量中设置 `NODE_TLS_CLIENT_AUTH=none`，然后在 Remnawave Panel 的节点地址里填写 PaaS 提供的 HTTPS 域名。

这样 Panel 可以通过正常的公共 CA 链校验 PaaS HTTPS 域名，节点侧也不会再因为 PaaS/HAProxy 前置无法透传客户端证书而拒绝连接。

仓库提供了一个常见免费/托管平台 Root CA 参考包：`config/certs/free-provider-root-ca-bundle.pem`。它包含 Let's Encrypt、Google Trust Services、Sectigo/USERTrust 的 8 张 Root CA，适合作为追加到 `keygen.ca_cert` 的起点；具体列表见 `config/certs/README.md`。如果 PaaS 使用自定义域名证书、私有 CA、企业代理证书或特殊区域证书链，需要额外追加实际链路对应的 Root CA。

如果想使用非官方的 Go 实现，可以改用 `latest-go-paas`。Go 实现来自 [x-dora/rw-node-go](https://github.com/x-dora/rw-node-go)，版本跟随 `rw-node-go` 自己的 release，不跟随 `remnawave/node` 的上游版本号。

PaaS 镜像默认会启动 HAProxy HTTP 前置，监听 `${PORT:-3000}`。当 PaaS 提供 HTTP/HTTPS 回源端口时，可以用同一个公网端口按路径前缀分流到本机 Xray inbound，并把 Panel 主 API 路径转发到本机 `NODE_PORT`。

```text
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /xh-* -> 127.0.0.1:8080
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /ws-* -> 127.0.0.1:8880
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /node/* -> 127.0.0.1:NODE_PORT (HTTPS, verify none)
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /vision/* -> 127.0.0.1:NODE_PORT (HTTPS, verify none)
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /health -> 200 ok
```

这里的 `/xh-*` 和 `/ws-*` 表示路径分别以 `/xh-` 和 `/ws-` 开头，例如 `/xh-a`、`/xh-test`、`/ws-a`。HAProxy 到 Xray 使用明文 HTTP，不做 HTTPS upstream。`/node/*` 和 `/vision/*` 会转发到本机 `NODE_PORT` 的 HTTPS 服务，并跳过 upstream 证书校验，以兼容节点自签证书。

除 `/health`、`/xh-*`、`/ws-*`、`/node/*`、`/vision/*` 之外的路径会直接返回 404。`HTTP_FRONT_ENABLED=false` 时不会启动 HAProxy 分流，只会在 PaaS 下发了 `PORT` 且该端口不等于 `NODE_PORT` 时启动一个简单 HTTP health server；这种模式不能承载 `/xh-*`、`/ws-*` 或 Panel API 转发。

#### PaaS 侧环境变量

使用镜像：

```text
ghcr.io/x-dora/rw-node:latest-paas
```

Go 实现镜像：

```text
ghcr.io/x-dora/rw-node:latest-go-paas
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
| `PORT` | - | PaaS 下发的 HTTP 回源端口；HAProxy 优先监听该端口 |
| `HTTP_FRONT_ENABLED` | `true` | 是否启动 HAProxy HTTP 前置；设为 `false` 时回退为旧的简单 health server |
| `HTTP_FRONT_PORT` | `${PORT:-3000}` | HAProxy HTTP 前置监听端口，通常不需要手动设置 |
| `XHTTP_UPSTREAM_PORT` | `8080` | `/xh-` 前缀流量转发到的本机 xhttp 明文 HTTP 端口 |
| `WS_UPSTREAM_PORT` | `8880` | `/ws-` 前缀流量转发到的本机 WebSocket 明文 HTTP 端口 |
| `RW_NODE_APP_DIR` | `/opt/rw-node` | PaaS 镜像内应用文件目录，通常不要修改 |

PaaS 示例：

```bash
docker run -d \
  --name rw-node-paas \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e NODE_PORT=2222 \
  -e NODE_TLS_CLIENT_AUTH=none \
  -e XTLS_API_PORT=61000 \
  ghcr.io/x-dora/rw-node:latest-paas
```

Go 实现 PaaS 示例：

```bash
docker run -d \
  --name rw-node-go-paas \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e NODE_PORT=2222 \
  -e NODE_TLS_CLIENT_AUTH=none \
  -e INTERNAL_REST_PORT=61001 \
  ghcr.io/x-dora/rw-node:latest-go-paas
```

Remnawave Panel 中节点地址填写 PaaS 提供的 HTTPS 域名，例如：

```text
https://rw-node.example-paas.app
```

Panel 数据库 `keygen.ca_cert` 字段需要包含该 HTTPS 域名证书链对应的公共 Root CA，否则 Panel 仍可能因为不信任 PaaS 证书链而拒绝连接。可以参考 `config/certs/free-provider-root-ca-bundle.pem`，但最终以实际 PaaS 域名的证书链为准。

如果使用 HAProxy HTTP 前置承载 xhttp/ws 流量，则客户端或面板下发的 xhttp/ws 配置应填写 PaaS 提供的 HTTP/HTTPS 域名和单个公网端口，并用不同路径前缀区分协议。xhttp inbound 固定监听本机 `8080` 明文 HTTP，ws inbound 固定监听本机 `8880` 明文 HTTP。`/xh`、`/xh/abc`、`/ws`、`/ws/abc` 不会匹配前置规则，只有以 `/xh-` 或 `/ws-` 开头的路径会被转发。

如果日志出现 `application entrypoint is missing` 或旧版本中的 `application files are missing in /opt/rw-node`，优先检查 PaaS 是否把持久化卷挂载到了 `/opt/rw-node` 并覆盖了镜像内应用文件。PaaS 镜像默认会从 `/opt/rw-node` 读取应用文件；不要把空卷挂载到这个路径，也不要把 `RW_NODE_DIR` 指向不包含 `dist/`、`node_modules/` 的目录。

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

# 安装 Cloudflare Tunnel 并写入 token
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --with-cloudflared \
  --cloudflared-token YOUR_TUNNEL_TOKEN

# 指定版本
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/2.5.2/scripts/install.sh) --version 2.5.2

# 静默安装（无交互）
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --secret-key YOUR_SECRET_KEY \
  --port 2222

# 指定 Xray-core 版本
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --secret-key YOUR_SECRET_KEY \
  --xray-version v26.3.27

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

#### 安装参数

| 参数 | 描述 | 默认值 |
|------|------|--------|
| `--impl <official|go>` | 安装实现；`official` 为 JS 兼容实现，`go` 为非官方 Go 实现 | `official` |
| `--version, -v <版本>` | 指定 JS 兼容实现版本；对应 `remnawave/node` / 本仓库 release 版本 | 最新 release |
| `--go-version <版本>` | 指定 `rw-node-go` release 版本，仅 `--impl go` 有效 | 最新 `rw-node-go` release |
| `--port, -p <端口>` | 节点主 API 监听端口 | `2222` |
| `--secret-key, -k <密钥>` | Remnawave Panel 中的节点密钥；非交互安装时必填 | - |
| `--xtls-api-port <端口>` | JS 兼容实现的 Xray API 内部端口 | `61000` |
| `--internal-rest-port <端口>` | Go 实现的 Internal REST 本机端口 | `61001` |
| `--node-tls-client-auth <mtls|optional|none>` | Go 实现主 API 的 TLS 客户端证书策略；PaaS HTTPS 直连常用 `none` | `mtls` |
| `--xray-version <版本>` | 指定 JS 兼容实现安装的 Xray-core 版本 | `v26.3.27` |
| `--with-cloudflared` | 安装 Cloudflare Tunnel 二进制；有 systemd 且 token 有效时启用服务 | 关闭 |
| `--cloudflared-token <令牌>` | 写入 Cloudflare Tunnel token，并自动启用 `--with-cloudflared` | - |

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

# 指定版本更新
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/update.sh) --version 2.7.0

# 非交互确认更新
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/update.sh) --yes

# 当前版本相同也重新部署
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/update.sh) --force --yes

# 卸载
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/uninstall.sh)
```

`update.sh` 仅支持 JS 兼容实现的在线更新，并会保留已有 `.env` 配置。Go 实现模式暂不走 `update.sh`，需要重新运行 `install.sh --impl go` 覆盖安装；覆盖安装会重新生成 `.env`，请提前备份自定义配置。`uninstall.sh` 会删除安装目录、systemd 服务和本项目创建的 `/usr/local/bin` 符号链接，必须在交互终端中确认后才会执行。

## 环境变量

| 变量名 | 描述 | 默认值 |
|--------|------|--------|
| `NODE_PORT` | 节点端口 | `2222` |
| `SECRET_KEY` | 面板密钥 | - |
| `NODE_TLS_CLIENT_AUTH` | Go 模式主 API 的 TLS 客户端证书策略；PaaS HTTPS 直连推荐设为 `none` | `mtls` |
| `XTLS_API_PORT` | Xray API 端口 | `61000` |
| `INTERNAL_REST_PORT` | Go 模式本机 Internal REST 端口，不要公开 | `61001` |
| `RW_NODE_DIR` | 工作目录（所有文件存放位置） | `/opt/rw-node` |
| `XRAY_LOCATION_ASSET` | Xray 资源文件目录；Go 模式和脚本安装会显式使用，手动迁移资源文件时可指定 | 脚本安装为 `${RW_NODE_DIR}/share/xray`；Go PaaS 镜像为 `/usr/local/share/xray` |
| `REQUIRE_SECRET_KEY` | Go 模式是否要求 `SECRET_KEY` | `true` |
| `SUPERVISORD_USER` | JS 兼容实现 Supervisord unix socket 用户名；通常自动随机生成 | 随机 |
| `SUPERVISORD_PASSWORD` | JS 兼容实现 Supervisord unix socket 密码；通常自动随机生成 | 随机 |
| `INTERNAL_REST_TOKEN` | JS 兼容实现内部 REST token；通常自动随机生成 | 随机 |

PaaS 镜像还支持 `PORT`、`HTTP_FRONT_ENABLED`、`HTTP_FRONT_PORT`、`XHTTP_UPSTREAM_PORT`、`WS_UPSTREAM_PORT`、`RW_NODE_APP_DIR` 等变量，详见上面的 “PaaS 侧环境变量”。标准 Docker 镜像通常只需要 `NODE_PORT`、`SECRET_KEY`、`XTLS_API_PORT`。

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
