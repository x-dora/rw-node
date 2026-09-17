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

`rw-node-go`、Caddy、geocheck 和可选的 `cloudflared` 都安装到仓库根目录下：

```text
.rw-node/
  bin/caddy
  bin/cloudflared
  bin/geocheck
  bin/rw-node-go
  bin/sshd-lite
  share/xray/geoip.dat
  share/xray/geosite.dat
  ssh/host_key
  .cloudflared-version
  .geocheck-version
  .rw-node-go-version
  conf/caddy/Caddyfile
  caddy/data/
  caddy/config/
```

当 `rw-node-go` 二进制或必需的 Xray 资源文件缺失时，`start.sh` 会下载 `rw-node-go`。当本地 Caddy 缺失或不可执行时，`start.sh` 会下载 Caddy。

当本地 geocheck 缺失时，`start.sh` 会下载 geocheck，并用指向 `.rw-node/bin/geocheck` 的 `GEOCHECK_BINARY_PATH` 启动 `rw-node-go`。这一步是 best-effort：下载失败只记录 `WARN` 告警，`start.sh` 继续启动，`/node/stats/get-geocheck` 降级为 A018 错误。

当 `ARGO_TOKEN` 非空，并且本地 `cloudflared` 缺失或不可执行时，`start.sh` 会下载 `cloudflared`。

## Caddy

启动入口会检查 `.rw-node/bin/caddy`。如果本地 Caddy 不存在，则通过 Caddy 官方 download API 下载带 `caddy-l4`（layer4 插件）的预编译二进制，复制到 `.rw-node/bin/caddy`，并设置权限为 `755`。

下载地址格式：

```text
https://caddyserver.com/api/download?os=linux&arch=${ARCH}&p=github.com/mholt/caddy-l4
```

Caddy 子进程会使用适合 rootless PaaS 的目录：

```text
HOME=<仓库根目录>
XDG_DATA_HOME=<仓库根目录>/.rw-node/caddy/data
XDG_CONFIG_HOME=<仓库根目录>/.rw-node/caddy/config
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

## SSH 入口（可选）

设置 `SSH_ENABLED=true` 并提供 `SSH_AUTHORIZED_KEYS` 后，启动入口会把静态编译的 `sshd-lite` 安装到 `.rw-node/bin/`，并在 `HTTP_FRONT_PORT` 上复用 SSH，客户端直接 `ssh -p <HTTP_FRONT_PORT> <user>@<host>` 即可登录，无需额外代理配置。

Caddy layer4 按连接首字节区分协议（三者互斥）：`0x16` 走 TLS 透传，`SSH-` 转发到 `127.0.0.1:${SSH_PORT}`，其余按明文 HTTP 走路径路由。sshd-lite 只监听回环地址，不接受外部直连，必须经 Caddy 入口。

**登录用户名随意填写。** [sshd-lite](https://github.com/x-dora/sshd-lite) 不做用户名校验，`ssh root@…`、`ssh user@…`、`ssh 999@…` 完全等价：它认证只看 `authorized_keys`，登录成功后直接以当前进程身份启动 shell。

这正是它相对 OpenSSH sshd 与 dropbear 的关键区别——后两者的每一条认证路径都要经过 `getpwnam`/`getpwuid`，容器以 `/etc/passwd` 中不存在的虚拟 uid 运行时（PaaS 平台常见，且这类环境通常不允许写 `/etc/passwd`），无论客户端填什么用户名都会认证失败。

公钥认证；`-L` / `-R` / `-D` 端口转发、交互式 pty、`ssh <host> <command>`（命令交给登录 shell 的 `-c`，管道与重定向可用）均已支持。

以下任一条不满足时入口自动关闭并输出 `WARN`，不影响节点其它功能：

- `SSH_AUTHORIZED_KEYS` 为空
- `sshd-lite` 下载失败或启动失败

host key 存放在 `.rw-node/ssh/host_key`，首次启动自动生成。容器重建会重新生成，客户端会提示 host key 变化；设置 `SSH_HOST_KEY` 可固定。

> SSH 是明文协议，只有 PaaS 把端口按 TCP 透传到容器时才能工作。若平台是 HTTP(S) 反代或经 cloudflared 隧道，`SSH-` 流量到不了容器。

## 环境变量

启动入口会保留已有环境变量。缺失变量使用 `.env`，`.env` 也缺失时使用以下默认值：

```text
NODE_PORT=2222
NODE_TLS_CLIENT_AUTH=none
INTERNAL_REST_PORT=61001
REQUIRE_SECRET_KEY=true
RW_NODE_DIR=<仓库根目录>
XRAY_LOCATION_ASSET=<仓库根目录>/.rw-node/share/xray
HTTP_FRONT_PORT=${PORT:-3000}
XHTTP_UPSTREAM_PORT=8080
WS_UPSTREAM_PORT=8880
SSH_ENABLED=false
SSH_PORT=22222
```

可以设置 `RW_NODE_GO_VERSION` 安装指定 `x-dora/rw-node-go` release。未设置时，启动入口使用 GitHub latest release。

`GEOCHECK_BINARY_PATH` 在 geocheck 安装成功后由启动入口自动设置并导出，指向 `.rw-node/bin/geocheck`；外部环境变量或 `.env` 已提供该变量时，启动入口跳过自动安装。可以设置 `GEOCHECK_VERSION` 安装指定 geocheck release（默认 `0.3.0`）。

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
5. 确保 geocheck 已安装，成功后导出 `GEOCHECK_BINARY_PATH`；失败只记录告警。
6. 当 `SSH_ENABLED=true` 时，确保 `sshd-lite` 已安装，并在生成 Caddy 配置前启动 SSH 服务；失败只记录告警，SSH 入口降级为关闭。
7. 当 `ARGO_TOKEN` 非空时，确保 `cloudflared` 已安装。
8. 生成 `.rw-node/conf/caddy/Caddyfile`。
9. 使用 `caddy validate --config .rw-node/conf/caddy/Caddyfile --adapter caddyfile` 校验配置；校验成功时只输出一行启动器日志，校验失败时输出 Caddy 原始错误。
10. 使用 `caddy run --config .rw-node/conf/caddy/Caddyfile --adapter caddyfile` 启动 Caddy。layer4 在 `HTTP_FRONT_PORT` 上同时接收 TLS、HTTP 和 SSH 连接。
11. 启动 `rw-node-go`。
12. 当 `ARGO_TOKEN` 非空时，启动 `cloudflared tunnel run --token "$ARGO_TOKEN"`，并使用 HTTP/2、Cloudflare DNS resolver 和自动 edge IP 版本连接 Cloudflare。
13. 当 Caddy 或 `rw-node-go` 提前退出，或启动入口收到 `SIGINT` / `SIGTERM` 时，终止所有子进程。
14. 当可选的 `cloudflared` 默认模式提前退出时，自动重试固定 Cloudflare edge 地址模式；固定 edge 地址模式仍退出时，记录日志并保持 Caddy 与 `rw-node-go` 继续运行。
