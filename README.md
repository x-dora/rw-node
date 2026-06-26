# RW-Node Go PaaS Starter

此分支提供用于在 PaaS 环境运行 `rw-node-go` 的最小启动入口，并使用自动生成的 Caddy（带 layer4 插件）作为前置代理。

安装、配置生成和进程编排逻辑集中在 `start.sh`。`index.js` 与 `app.py` 只作为兼容不同 PaaS/runtime 的包装器：启动 Bash 脚本、继承输出，并使用脚本的退出状态共同退出。

可以任选一个入口启动：

```bash
npm start
```

```bash
uv run python app.py
```

```bash
bash start.sh
```

启动入口只支持 Linux `x64` 和 `arm64`。运行环境需要提供 `bash`、`curl`、`tar`、`chmod` 以及常见 GNU/coreutils 工具。

## 文件

- `start.sh`：唯一的安装、配置生成和启动编排入口。
- `index.js`：Node.js 包装器，只负责启动 `start.sh`。
- `app.py`：Python 包装器，只负责启动 `start.sh`。
- `.env.example`：环境变量示例。
- `package.json`：Node.js 启动元数据。
- `pyproject.toml`：Python 启动元数据。

## `.env`

启动时会读取仓库根目录的 `.env`。变量优先级固定为：

```text
外部环境变量 > .env > 脚本默认值
```

也就是说，如果系统、PaaS、Shell 或容器已经提供了某个环境变量，`.env` 中的同名变量不会覆盖它。

可以复制示例文件后修改：

```bash
cp .env.example .env
```

真实 `.env` 已加入 `.gitignore`，不应提交到仓库。

`.env` 支持以下格式：

```text
KEY=value
export KEY=value
KEY="value"
KEY='value'
```

支持空行和 `#` 注释。不支持命令替换、变量展开或任意 Bash 代码；格式不合法的行会导致启动失败并输出行号。

## 安装目录

`rw-node-go`、Caddy 和可选的 `cloudflared` 都安装到仓库根目录下：

```text
.rw-node-go/
  bin/caddy
  bin/cloudflared
  bin/rw-node-go
  share/xray/geoip.dat
  share/xray/geosite.dat
  .cloudflared-version
  .rw-node-go-version
  conf/caddy/Caddyfile
  caddy/data/
  caddy/config/
```

当 `rw-node-go` 二进制或必需的 Xray 资源文件缺失时，`start.sh` 会下载 `rw-node-go`。当本地 Caddy 缺失或不可执行时，`start.sh` 会下载 Caddy。

当 `ARGO_TOKEN` 非空，并且本地 `cloudflared` 缺失或不可执行时，`start.sh` 会下载 `cloudflared`。

## Caddy

启动入口会检查 `.rw-node-go/bin/caddy`。如果本地 Caddy 不存在，则通过 Caddy 官方 download API 下载带 `caddy-l4`（layer4 插件）的预编译二进制，复制到 `.rw-node-go/bin/caddy`，并设置权限为 `755`。

下载地址格式：

```text
https://caddyserver.com/api/download?os=linux&arch=${ARCH}&p=github.com/mholt/caddy-l4
```

Caddy 子进程会使用适合 rootless PaaS 的目录：

```text
HOME=<仓库根目录>
XDG_DATA_HOME=<仓库根目录>/.rw-node-go/caddy/data
XDG_CONFIG_HOME=<仓库根目录>/.rw-node-go/caddy/config
```

生成的 `Caddyfile` 会关闭 Caddy admin 端点和配置持久化，避免在 PaaS 运行时额外打开本地管理端口或写入 autosave 配置：

```text
admin off
persist_config off
```

Caddy 全局日志级别设置为 `WARN`，用于减少启动时的普通 info 日志，同时保留警告和错误：

```text
log {
  level WARN
}
```

同时会关闭自动 HTTPS，Caddy 的 HTTP 服务只在内部端口监听：

```text
auto_https off
http://:${CADDY_HTTP_PORT}
```

内部 HTTP 端口 `CADDY_HTTP_PORT` 自动计算为 `HTTP_FRONT_PORT + 1`，不需要手动配置。

业务入口只启用 HTTP/1.1，避免明文监听场景下 Caddy 输出 HTTP/2、HTTP/3 需要 TLS 的启动警告：

```text
servers :${CADDY_HTTP_PORT} {
  protocols h1
}
```

## Layer4

Caddy 使用 layer4 插件在 `HTTP_FRONT_PORT` 上同时接收 TLS 和 HTTP 连接：

```text
layer4 {
  :${HTTP_FRONT_PORT} {
    @tls tls
    route @tls {
      proxy 127.0.0.1:${NODE_PORT}
    }
    route {
      proxy 127.0.0.1:${CADDY_HTTP_PORT}
    }
  }
}
```

- TLS 连接（panel 等 HTTPS 客户端）直接透传到 `NODE_PORT`，由 `rw-node-go` 处理 TLS 握手。
- 非 TLS 连接（HTTP 请求）转发到内部 Caddy HTTP 端口，走路径路由。

这种设计同时兼容两种部署场景：
- **端口转发容器**：外部直接转发 TCP，TLS 客户端可直连。
- **HTTPS 反代 PaaS**：PaaS 终止 TLS 后发送 HTTP，layer4 识别为非 TLS，转给内部 HTTP 路由。

## 环境变量

启动入口会保留已有环境变量。缺失变量使用 `.env`，`.env` 也缺失时使用以下默认值：

```text
NODE_PORT=2222
NODE_TLS_CLIENT_AUTH=none
INTERNAL_REST_PORT=61001
REQUIRE_SECRET_KEY=true
RW_NODE_DIR=<仓库根目录>
XRAY_LOCATION_ASSET=<仓库根目录>/.rw-node-go/share/xray
HTTP_FRONT_PORT=${PORT:-3000}
XHTTP_UPSTREAM_PORT=8080
WS_UPSTREAM_PORT=8880
```

可以设置 `RW_NODE_GO_VERSION` 安装指定 `x-dora/rw-node-go` release。未设置时，启动入口使用 GitHub latest release。

`CADDY_HTTP_PORT` 为内部自动计算的端口（`HTTP_FRONT_PORT + 1`），不需要手动设置。

Cloudflare Tunnel 开关：

```text
ARGO_TOKEN=
```

`ARGO_TOKEN` 非空时，启动入口会自动启动 `cloudflared`：

```bash
cloudflared tunnel --no-autoupdate --protocol http2 --edge-ip-version auto --tag "rw_node_port=$HTTP_FRONT_PORT" run --dns-resolver-addrs 1.1.1.1:53 --dns-resolver-addrs 1.0.0.1:53 --token "$ARGO_TOKEN"
```

## Cloudflare Tunnel

`ARGO_TOKEN` 指 Cloudflare remotely-managed tunnel token，不是 Cloudflare API token。只要该变量非空，启动入口就会把 `cloudflared` 作为受管子进程启动。

Cloudflare 侧 Public hostname / Published application 的 Service 应配置为：

```text
http://localhost:${HTTP_FRONT_PORT}
```

启动器不会直接把内部端口暴露到公网。`HTTP_FRONT_PORT` 是 Caddy 的统一入口，Caddy 再按路径转发到 `XHTTP_UPSTREAM_PORT`、`WS_UPSTREAM_PORT` 和 `NODE_PORT`。这种方式让隧道只穿透一个本地端口，避免 Cloudflare 侧配置多个内部服务端口。

`cloudflared` 启动时会附带：

```text
--tag "rw_node_port=${HTTP_FRONT_PORT}"
```

这个 tag 用于让 Cloudflare 连接器侧看到当前节点期望穿透的端口元信息；它不替代 Cloudflare 侧的 Public hostname 路由配置。仅凭 `ARGO_TOKEN` 本身，启动器无法动态修改 Cloudflare 侧 hostname 到本地端口的映射。

启动器会让 `cloudflared` 默认通过 `1.1.1.1:53` 和 `1.0.0.1:53` 解析 Cloudflare Tunnel 的 SRV 记录，并使用 `--edge-ip-version auto` 自动选择 Cloudflare edge IP 版本。如果默认启动失败，启动器会自动重试一次固定 edge 地址模式，通过 `--edge` 传入 Cloudflare 官方 IPv4 edge 地址，绕过 `_v2-origintunneld._tcp.argotunnel.com` 的 SRV 查询。如果运行环境禁止访问 Cloudflare Tunnel edge 端口，`cloudflared` 仍可能退出。启动器会记录 `cloudflared fixed-edge startup failed; continuing without Cloudflare Tunnel`，并保持 Caddy 与 `rw-node-go` 继续运行。

端口校验规则：

- `HTTP_FRONT_PORT`、`NODE_PORT`、`XHTTP_UPSTREAM_PORT`、`WS_UPSTREAM_PORT` 必须是合法 TCP 端口。
- `HTTP_FRONT_PORT` 不能等于 `NODE_PORT`。
- `CADDY_HTTP_PORT`（`HTTP_FRONT_PORT + 1`）不能与 `NODE_PORT`、`XHTTP_UPSTREAM_PORT`、`WS_UPSTREAM_PORT` 冲突。

## Caddy 路由

生成的 Caddy 配置使用 layer4 前置 + 内部 HTTP 路由：

- TLS 连接透传到 `127.0.0.1:${NODE_PORT}`，由 `rw-node-go` 直接处理。
- HTTP 连接转发到内部 `CADDY_HTTP_PORT`，按以下路径路由：
  - `/health` 返回 `200`，响应体为 `ok`，不附带尾随换行。
  - `/xh-*` 转发到 `127.0.0.1:${XHTTP_UPSTREAM_PORT}`。
  - `/ws-*` 转发到 `127.0.0.1:${WS_UPSTREAM_PORT}`。
  - `/node/*` 通过 HTTPS 转发到 `127.0.0.1:${NODE_PORT}`，并跳过证书校验。
  - `/vision/*` 通过 HTTPS 转发到 `127.0.0.1:${NODE_PORT}`，并跳过证书校验。
  - 其它路径返回 `404`。

生成的 `Caddyfile` 会直接写入具体端口值，不依赖 Caddy 自己展开环境变量。

## 进程行为

`start.sh` 会执行以下流程：

1. 读取 `.env`，并按优先级补齐默认环境变量。
2. 校验平台、架构和端口。
3. 确保 Caddy 已安装。
4. 确保 `rw-node-go` 已安装。
5. 当 `ARGO_TOKEN` 非空时，确保 `cloudflared` 已安装。
6. 生成 `.rw-node-go/conf/caddy/Caddyfile`。
7. 使用 `caddy validate --config .rw-node-go/conf/caddy/Caddyfile --adapter caddyfile` 校验配置；校验成功时只输出一行启动器日志，校验失败时输出 Caddy 原始错误。
8. 使用 `caddy run --config .rw-node-go/conf/caddy/Caddyfile --adapter caddyfile` 启动 Caddy。layer4 在 `HTTP_FRONT_PORT` 上同时接收 TLS 和 HTTP 连接。
9. 启动 `rw-node-go`。
10. 当 `ARGO_TOKEN` 非空时，启动 `cloudflared tunnel run --token "$ARGO_TOKEN"`，并使用 HTTP/2、Cloudflare DNS resolver 和自动 edge IP 版本连接 Cloudflare。
11. 当 Caddy 或 `rw-node-go` 提前退出，或启动入口收到 `SIGINT` / `SIGTERM` 时，终止所有子进程。
12. 当可选的 `cloudflared` 默认模式提前退出时，自动重试固定 Cloudflare edge 地址模式；固定 edge 地址模式仍退出时，记录日志并保持 Caddy 与 `rw-node-go` 继续运行。
