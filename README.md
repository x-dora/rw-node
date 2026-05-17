# RW-Node Go PaaS Starter

此分支提供用于在 PaaS 环境运行 `rw-node-go` 的最小启动入口，并使用自动生成的 Caddy 作为前置代理。

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

`rw-node-go` 和 Caddy 都安装到仓库根目录下：

```text
.rw-node-go/
  bin/caddy
  bin/rw-node-go
  share/xray/geoip.dat
  share/xray/geosite.dat
  .caddy-version
  .rw-node-go-version
  conf/caddy/Caddyfile
  caddy/data/
  caddy/config/
```

当 `rw-node-go` 二进制或必需的 Xray 资源文件缺失时，`start.sh` 会下载 `rw-node-go`。当 `CADDY_BIN` 未设置，并且 `.rw-node-go/bin/caddy` 缺失或不可执行时，`start.sh` 会下载 Caddy。

## Caddy

启动入口优先使用 `CADDY_BIN` 指定的 Caddy 二进制路径，该路径必须存在且可执行。

如果没有设置 `CADDY_BIN`，启动入口会检查 `.rw-node-go/bin/caddy`。如果本地 Caddy 不存在，则通过 `caddyserver/caddy` 的 GitHub Releases API 获取 release 信息，按当前 Linux 架构选择官方 `tar.gz` 资产，解压出 `caddy`，复制到 `.rw-node-go/bin/caddy`，并设置权限为 `755`。

可以设置 `CADDY_VERSION` 安装指定 Caddy release tag，例如：

```text
CADDY_VERSION=v2.11.3
```

未设置 `CADDY_VERSION` 时，启动入口使用 GitHub latest release。

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

同时会关闭自动 HTTPS，并使用明文 HTTP 监听业务入口：

```text
auto_https off
http://:${HTTP_FRONT_PORT}
```

业务入口只启用 HTTP/1.1，避免明文监听场景下 Caddy 输出 HTTP/2、HTTP/3 需要 TLS 的启动警告：

```text
servers :${HTTP_FRONT_PORT} {
  protocols h1
}
```

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

Caddy 相关变量：

```text
CADDY_BIN=/path/to/caddy
CADDY_VERSION=v2.11.3
```

端口校验规则：

- `HTTP_FRONT_PORT`、`NODE_PORT`、`XHTTP_UPSTREAM_PORT`、`WS_UPSTREAM_PORT` 必须是合法 TCP 端口。
- `HTTP_FRONT_PORT` 不能等于 `NODE_PORT`。

## Caddy 路由

生成的 Caddy 配置对应 PaaS 前置代理行为：

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
5. 生成 `.rw-node-go/conf/caddy/Caddyfile`。
6. 使用 `caddy validate --config .rw-node-go/conf/caddy/Caddyfile --adapter caddyfile` 校验配置；校验成功时只输出一行启动器日志，校验失败时输出 Caddy 原始错误。
7. 使用 `caddy run --config .rw-node-go/conf/caddy/Caddyfile --adapter caddyfile` 启动 Caddy。
8. 启动 `rw-node-go`。
9. 当任一子进程提前退出，或启动入口收到 `SIGINT` / `SIGTERM` 时，终止 Caddy 和 `rw-node-go`。
