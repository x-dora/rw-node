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
| `ghcr.io/x-dora/rw-node:latest-paas-frp` | PaaS 反向 TCP 隧道版 (内置 frpc + HAProxy HTTP 前置) | ~400MB |
| `ghcr.io/x-dora/rw-node:latest-go-paas-frp` | 非官方 Go 实现 PaaS 反向 TCP 隧道版 (内置 frpc + HAProxy HTTP 前置) | 更小 |

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

### 方式一补充：PaaS + FRP 反向 TCP 隧道

当 PaaS 只提供 HTTP/HTTPS 入站端口，无法直接公开 `NODE_PORT` 的原始 TCP 连接时，可以使用 `latest-paas-frp` 镜像。该镜像会让容器主动连接到你的 VPS 上的 `frps`，由 VPS 对外提供节点 TCP 入口。

如果想使用非官方的 Go 实现，可以改用 `latest-go-paas-frp`。Go 实现来自 [x-dora/rw-node-go](https://github.com/x-dora/rw-node-go)，版本跟随 `rw-node-go` 自己的 release，不跟随 `remnawave/node` 的上游版本号。

PaaS 镜像默认还会启动 HAProxy HTTP 前置，监听 `${PORT:-3000}`。当 PaaS 提供 HTTP/HTTPS 回源端口时，可以用同一个公网端口按路径前缀分流到本机 Xray inbound：

```text
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /xh-* -> 127.0.0.1:8080
PaaS HTTP(S) -> HAProxy:${PORT:-3000} -> /ws-* -> 127.0.0.1:8880
```

这里的 `/xh-*` 和 `/ws-*` 表示路径分别以 `/xh-` 和 `/ws-` 开头，例如 `/xh-a`、`/xh-test`、`/ws-a`。HAProxy 到 Xray 使用明文 HTTP，不做 HTTPS upstream。

连接链路：

```text
Remnawave Panel -> VPS:FRP_REMOTE_PORT -> frps -> PaaS frpc -> 127.0.0.1:NODE_PORT -> rw-node HTTPS
```

这条链路只做 TCP 转发，不做 HTTPS 反代或 TLS 终止，因此控制台仍会看到 rw-node 自己的自签证书。

`frpc -> frps` 的控制/数据连接默认使用 TCP `7000`。如果 PaaS 出站网络只适合 HTTPS，或希望这段回连经过支持 WebSocket 的 CDN，可以把 PaaS 侧 `FRP_TRANSPORT_PROTOCOL` 改为 `websocket` 或 `wss`，通常配合 `FRP_SERVER_PORT=443`。这只改变容器回连 frps 的方式，不改变 Remnawave Panel 访问 `FRP_REMOTE_PORT` 的 raw TCP 节点入口。

#### VPS 侧一次性配置 frps

推荐直接使用仓库中的安装脚本：

```bash
sudo bash scripts/install-frps.sh \
  --token REPLACE_WITH_STRONG_RANDOM_TOKEN \
  --bind-port 7000 \
  --allow-port-start 22000 \
  --allow-port-end 22999
```

也可以手动下载 frp 并安装 `frps`，然后创建 `/etc/frp/frps.toml`：

```toml
bindPort = 7000
auth.token = "REPLACE_WITH_STRONG_RANDOM_TOKEN"

allowPorts = [
  { start = 22000, end = 22999 }
]
```

仓库也提供了示例文件：`config/frp/frps.toml.example` 和 `config/systemd/frps.service`。

如果要让 `frpc -> frps` 走 WSS/CDN，可以让 frps 直接监听 `443`，或用 Nginx/Caddy 在 `443` 终止 HTTPS 后反代到本机 frps 控制端口。frp 的 WebSocket 请求路径固定为 `/~!frp`，Nginx 示例：

```nginx
server {
    listen 443 ssl http2;
    server_name frps.example.com;

    ssl_certificate /etc/letsencrypt/live/frps.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/frps.example.com/privkey.pem;

    location /~!frp {
        proxy_pass http://127.0.0.1:7000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

启动服务：

```bash
sudo mkdir -p /etc/frp
sudo cp config/frp/frps.toml.example /etc/frp/frps.toml
sudo cp config/systemd/frps.service /etc/systemd/system/frps.service
sudo systemctl daemon-reload
sudo systemctl enable --now frps
```

防火墙需要放行：

- `7000/tcp`：PaaS 容器连接 `frps` 的控制端口
- `443/tcp`：可选，`frpc -> frps` 使用 `wss` 并经 HTTPS/CDN 回连时使用
- `22000-22999/tcp`：节点公网入口端口池

新增 PaaS 节点时不需要再修改 VPS 的 `frps.toml`，只需要从端口池中分配一个未使用端口。

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
| `FRP_SERVER_ADDR` | VPS IP 或域名 | `vps.example.com` |
| `FRP_TOKEN` | 与 `frps.toml` 一致的 token | `REPLACE_WITH_STRONG_RANDOM_TOKEN` |
| `FRP_REMOTE_PORT` | 该节点在 VPS 上占用的公网端口 | `22001` |

常用可选环境变量：

| 变量名 | 默认值 | 描述 |
|--------|--------|------|
| `NODE_PORT` | `2222` | rw-node 容器内 HTTPS 监听端口 |
| `XTLS_API_PORT` | `61000` | Xray API 内部端口，不要公开 |
| `INTERNAL_REST_PORT` | `61001` | Go 实现镜像的本机 internal REST 端口，不要公开 |
| `FRP_SERVER_PORT` | `7000` | frps 控制端口 |
| `FRP_TRANSPORT_PROTOCOL` | `tcp` | frpc 连接 frps 的传输协议，可选 `tcp`、`websocket`、`wss` |
| `FRP_TLS_SERVER_NAME` | `FRP_SERVER_ADDR` | 可选，覆盖 WSS/TLS 连接校验使用的 SNI/ServerName；`wss` 模式不填时自动使用 `FRP_SERVER_ADDR` |
| `FRP_TLS_TRUSTED_CA_FILE` | - | 可选，挂载自定义 CA 后用于校验 frps 源站证书 |
| `FRP_PROXY_NAME` | `rw-node-<随机字符>` | frp 代理唯一名称 |
| `FRP_PROXY_NAME_PREFIX` | `rw-node` | 自动生成 `FRP_PROXY_NAME` 时使用的前缀 |
| `FRP_ENABLED` | `true` | 设置为 `false` 可临时禁用 frpc |
| `FRP_WAIT_FOR_NODE` | `true` | 启动 frpc 前是否等待 `NODE_PORT` TCP 可连接 |
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
  -e XTLS_API_PORT=61000 \
  -e FRP_SERVER_ADDR=vps.example.com \
  -e FRP_SERVER_PORT=7000 \
  -e FRP_TOKEN=REPLACE_WITH_STRONG_RANDOM_TOKEN \
  -e FRP_REMOTE_PORT=22001 \
  ghcr.io/x-dora/rw-node:latest-paas-frp
```

WSS/CDN 回连示例：

```bash
docker run -d \
  --name rw-node-paas \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e NODE_PORT=2222 \
  -e XTLS_API_PORT=61000 \
  -e FRP_SERVER_ADDR=frps.example.com \
  -e FRP_SERVER_PORT=443 \
  -e FRP_TRANSPORT_PROTOCOL=wss \
  -e FRP_TOKEN=REPLACE_WITH_STRONG_RANDOM_TOKEN \
  -e FRP_REMOTE_PORT=22001 \
  ghcr.io/x-dora/rw-node:latest-paas-frp
```

Go 实现 PaaS 示例：

```bash
docker run -d \
  --name rw-node-go-paas \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e NODE_PORT=2222 \
  -e INTERNAL_REST_PORT=61001 \
  -e FRP_SERVER_ADDR=vps.example.com \
  -e FRP_SERVER_PORT=7000 \
  -e FRP_TOKEN=REPLACE_WITH_STRONG_RANDOM_TOKEN \
  -e FRP_REMOTE_PORT=22001 \
  ghcr.io/x-dora/rw-node:latest-go-paas-frp
```

Remnawave Panel 中节点地址填写 VPS 地址和 `FRP_REMOTE_PORT`，例如：

```text
vps.example.com:22001
```

不要填写 PaaS 分配的 HTTP/HTTPS 域名，也不要经过 CDN/HTTPS 反向代理。

如果使用 HAProxy HTTP 前置承载 xhttp/ws 流量，则客户端或面板下发的 xhttp/ws 配置应填写 PaaS 提供的 HTTP/HTTPS 域名和单个公网端口，并用不同路径前缀区分协议。xhttp inbound 固定监听本机 `8080` 明文 HTTP，ws inbound 固定监听本机 `8880` 明文 HTTP。`/xh`、`/xh/abc`、`/ws`、`/ws/abc` 不会匹配前置规则，只有以 `/xh-` 或 `/ws-` 开头的路径会被转发。

如果日志出现 `application entrypoint is missing` 或旧版本中的 `application files are missing in /opt/rw-node`，优先检查 PaaS 是否把持久化卷挂载到了 `/opt/rw-node` 并覆盖了镜像内应用文件。PaaS FRP 镜像默认会从 `/opt/rw-node` 读取应用文件；不要把空卷挂载到这个路径，也不要把 `RW_NODE_DIR` 指向不包含 `dist/`、`node_modules/` 的目录。

PaaS FRP 入口脚本会先启动 HAProxy HTTP 前置，再启动 rw-node，然后在启动 frpc 前等待 `NODE_PORT` 接受 TCP 连接；frpc readiness 不会请求 HTTP 路径，也不会要求 TLS 握手成功。如果平台或上游行为导致探测仍不适用，可以设置 `FRP_WAIT_FOR_NODE=false` 直接启动 frpc。

#### 新增节点流程

1. 在 PaaS 新建一个 `latest-paas-frp` 实例。
2. 从 `22000-22999` 中挑一个未使用端口，例如 `22002`，设置为 `FRP_REMOTE_PORT`。
3. 设置该节点对应的 `SECRET_KEY`。
4. 可选：设置易读的 `FRP_PROXY_NAME`，例如 `rw-node-02`；不设置时容器会自动生成 `rw-node-<随机字符>`。
5. 在 Remnawave Panel 中填写 `<VPS_IP_OR_DOMAIN>:<FRP_REMOTE_PORT>`。

建议维护一个简单端口表，例如 `22001 = rw-node-hk-01`、`22002 = rw-node-us-01`，避免多个节点使用同一个端口。

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
  --port 2222

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
| `XTLS_API_PORT` | Xray API 端口 | `61000` |
| `INTERNAL_REST_PORT` | Go 模式本机 Internal REST 端口，不要公开 | `61001` |
| `RW_NODE_DIR` | 工作目录（所有文件存放位置） | `/opt/rw-node` |
| `FRP_SERVER_ADDR` | PaaS FRP 版使用的 frps 地址 | - |
| `FRP_SERVER_PORT` | PaaS FRP 版使用的 frps 端口 | `7000` |
| `FRP_TRANSPORT_PROTOCOL` | PaaS FRP 版 frpc 连接 frps 的传输协议，可选 `tcp`、`websocket`、`wss` | `tcp` |
| `FRP_TLS_SERVER_NAME` | PaaS FRP 版 WSS/TLS 连接使用的 SNI/ServerName，`wss` 模式不填时自动使用 `FRP_SERVER_ADDR` | `FRP_SERVER_ADDR` |
| `FRP_TLS_TRUSTED_CA_FILE` | PaaS FRP 版 WSS/TLS 连接使用的自定义 CA 文件路径 | - |
| `FRP_TOKEN` | PaaS FRP 版使用的 frps token | - |
| `FRP_PROXY_NAME` | PaaS FRP 版代理名称，不填则自动生成 | `rw-node-<随机字符>` |
| `FRP_PROXY_NAME_PREFIX` | PaaS FRP 版自动代理名前缀 | `rw-node` |
| `FRP_REMOTE_PORT` | PaaS FRP 版 VPS 公网节点端口 | - |

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
