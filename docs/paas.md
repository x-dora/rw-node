# PaaS HTTPS 直连

PaaS 镜像适合 Render、Koyeb、Railway、Fly.io 等只提供 HTTP/HTTPS 回源端口的平台。它在容器内启动 Caddy HTTP 前置，把平台 HTTPS 域名收到的请求按路径转发到本机不同服务，并把未命中特定路径的请求伪装成静态页面。

推荐镜像：

```text
ghcr.io/x-dora/rw-node:latest
```

## 推荐链路

```text
Remnawave Panel
  -> https://<paas-domain>
  -> PaaS HTTP(S)
  -> Caddy:${PORT:-3000}
  -> /node/* 或 /vision/*
  -> 127.0.0.1:NODE_PORT
```

PaaS 前置通常无法透传 Remnawave Node 原本使用的客户端证书，因此 PaaS HTTPS 直连推荐在节点环境变量中设置：

```text
NODE_TLS_CLIENT_AUTH=none
```

同时，Remnawave Panel 源码硬编码了 `rejectUnauthorized: true`，且只信任 Panel 自身 CA 签发的证书。PaaS 场景下节点位于平台 HTTPS 反代之后，Panel 看到的是平台公共证书（如 Let's Encrypt）而非节点自签证书，因此需要让 Panel 同时信任系统公共 Root CA。

做法是将本仓库提供的预加载脚本 [`config/panel/disable-tls-verify.cjs`](../config/panel/disable-tls-verify.cjs) 挂载到 Panel 容器，并通过 `NODE_OPTIONS` 在启动时加载。该脚本会将 Node.js 内置的系统公共 Root CA（Mozilla CA bundle）合并到 Panel 的信任链中，使 Panel 既信任自身 CA 签发的直连节点证书，也信任 PaaS 平台的公共 HTTPS 证书，同时仍然拒绝中间人的随机自签证书。

Panel docker-compose 示例：

```yaml
services:
  remnawave:
    image: remnawave/backend:latest
    volumes:
      - ./disable-tls-verify.cjs:/opt/app/disable-tls-verify.cjs:ro
    environment:
      - NODE_OPTIONS=--max-old-space-size=16384 --require /opt/app/disable-tls-verify.cjs
```

> `--max-old-space-size=16384` 是 Panel 镜像原有的 `NODE_OPTIONS` 默认值，必须保留。如果 Panel 拆分部署（rest-api / scheduler / processor），每个服务都需要同样的 `volumes` 和 `NODE_OPTIONS`。

## 快速示例

```bash
docker run -d \
  --name rw-node-paas \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e NODE_PORT=2222 \
  -e NODE_TLS_CLIENT_AUTH=none \
  -e INTERNAL_REST_PORT=61001 \
  ghcr.io/x-dora/rw-node:latest
```

Remnawave Panel 中节点地址填写 PaaS 提供的 HTTPS 域名，例如：

```text
https://rw-node.example-paas.app
```

## Caddy 路由规则

PaaS 镜像默认启动 Caddy HTTP 前置，监听 `${PORT:-3000}`。当 PaaS 提供 HTTP/HTTPS 回源端口时，可以用同一个公网端口按路径分流到本机服务：

```text
PaaS HTTP(S) -> Caddy:${PORT:-3000} -> /xh-*     -> 127.0.0.1:8080
PaaS HTTP(S) -> Caddy:${PORT:-3000} -> /ws-*     -> 127.0.0.1:8880
PaaS HTTP(S) -> Caddy:${PORT:-3000} -> /node/*   -> 127.0.0.1:NODE_PORT (HTTPS, verify none)
PaaS HTTP(S) -> Caddy:${PORT:-3000} -> /vision/* -> 127.0.0.1:NODE_PORT (HTTPS, verify none)
PaaS HTTP(S) -> Caddy:${PORT:-3000} -> /health   -> 200 ok
PaaS HTTP(S) -> Caddy:${PORT:-3000} -> 其他路径   -> 静态伪装页面
```

`/xh-*` 和 `/ws-*` 表示路径分别以 `/xh-` 和 `/ws-` 开头，例如 `/xh-a`、`/xh-test`、`/ws-a`。Caddy 到 Xray 使用明文 HTTP，不做 HTTPS upstream。

`/node/*` 和 `/vision/*` 会转发到本机 `NODE_PORT` 的 HTTPS 服务，并跳过 upstream 证书校验，以兼容节点自签证书。

除 `/health`、`/xh-*`、`/ws-*`、`/node/*`、`/vision/*` 之外的路径会从静态伪装页面目录返回文件；找不到文件时回退到 `index.html`。`/xh`、`/xh/abc`、`/ws`、`/ws/abc` 不会匹配前置代理规则，会落到静态页面。

`HTTP_FRONT_ENABLED=false` 时不会启动 Caddy 分流，也不会加载静态伪装页面，只会在 PaaS 下发了 `PORT` 且该端口不等于 `NODE_PORT` 时启动一个简单 HTTP health server。这种模式不能承载 `/xh-*`、`/ws-*` 或 Panel API 转发。

## 静态伪装页面

`CADDY_INDEX_PAGE` 用于指定 Caddy 未命中代理路径时展示的静态页面资源，默认值是 `mikutap`。PaaS 镜像会在构建阶段预置默认 mikutap 页面，运行时默认只复制镜像内置资源，不会在冷启动时同步访问 GitHub。为了兼容参考项目中的变量名，也支持 `CADDYIndexPage` 作为别名；如果两个变量同时存在，优先使用 `CADDY_INDEX_PAGE`。

资源值可以是内置关键字、`http://` / `https://` URL、本地文件路径或本地目录路径。URL 或本地文件可以指向 zip、tar.gz 或单个 HTML 文件；压缩包内会自动查找最靠前的 `index.html` 所在目录作为站点根目录。

`CADDY_SITE_DIR` 是 Caddy 实际服务的生成目录，入口脚本启动时会重建它。不要把自有静态页挂载到 `CADDY_SITE_DIR`，也不要把 `CADDY_INDEX_PAGE` 指向 `CADDY_SITE_DIR` 本身、其中的文件或包含 `CADDY_SITE_DIR` 的父目录；本地静态页应放在其他独立目录，再通过 `CADDY_INDEX_PAGE=/path/to/site` 指定。

为避免误删持久化目录，自定义 `CADDY_SITE_DIR` 如果已经非空，必须包含入口脚本生成的 `.rw-node-caddy-site-dir` marker 文件才允许重建。首次使用自定义生成目录时应指向一个空目录；默认 `${RW_NODE_DIR}/www` 会自动初始化 marker。

示例：

```bash
docker run -d \
  --name rw-node-paas \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e NODE_PORT=2222 \
  -e NODE_TLS_CLIENT_AUTH=none \
  -e CADDY_INDEX_PAGE=webgl-fluid-simulation \
  ghcr.io/x-dora/rw-node:latest
```

常用内置关键字：

| 关键字 | 资源 |
|--------|------|
| `mikutap` | 镜像构建阶段预置的 mikutap 页面 |
| `mikutap-remote` | `https://github.com/AYJCSGM/mikutap/archive/master.zip` |
| `caddy` | Caddy welcome 页面 |
| `3dcelist` | 3DCEList 元素周期表 |
| `spotify` | Spotify Landing Page Redesign |
| `dev-landing-page` | dev-landing-page |
| `free-for-dev` | free-for-dev |
| `tailwind-landing-page` | tailwindtoolbox Landing Page |
| `simple-landing-page` | simple-landing-page |
| `startbootstrap-new-age` | StartBootstrap New Age |
| `webgl-fluid-simulation` | WebGL Fluid Simulation |
| `loruki` | loruki-website |
| `bongo-cat` | bongo.cat |

如果静态页面资源下载失败、路径不存在或压缩包内没有 `index.html`，入口脚本会生成一个最小 fallback 页面，避免 Caddy 前置启动失败。

## 环境变量

必填环境变量：

| 变量名 | 描述 | 示例 |
|--------|------|------|
| `SECRET_KEY` | Remnawave Panel 中的节点密钥 | `YOUR_SECRET_KEY` |

常用可选环境变量：

| 变量名 | 默认值 | 描述 |
|--------|--------|------|
| `NODE_PORT` | `2222` | rw-node 容器内 HTTPS 监听端口 |
| `NODE_TLS_CLIENT_AUTH` | `mtls` | PaaS HTTPS 直连推荐设置为 `none`，避免 PaaS/Caddy 前置无法透传客户端证书导致 Panel 连接失败 |
| `XTLS_API_PORT` | `61000` | Xray API 内部端口，不要公开 |
| `INTERNAL_REST_PORT` | `61001` | Go 实现镜像的本机 internal REST 端口，不要公开 |
| `PORT` | - | PaaS 下发的 HTTP 回源端口；Caddy 优先监听该端口 |
| `HTTP_FRONT_ENABLED` | `true` | 是否启动 Caddy HTTP 前置；设为 `false` 时回退为简单 health server |
| `HTTP_FRONT_PORT` | `${PORT:-3000}` | Caddy HTTP 前置监听端口，通常不需要手动设置 |
| `XHTTP_UPSTREAM_PORT` | `8080` | `/xh-` 前缀流量转发到的本机 xhttp 明文 HTTP 端口 |
| `WS_UPSTREAM_PORT` | `8880` | `/ws-` 前缀流量转发到的本机 WebSocket 明文 HTTP 端口 |
| `CADDY_INDEX_PAGE` | `mikutap` | 静态伪装页面资源，支持内置关键字、URL、本地文件或本地目录 |
| `CADDY_SITE_DIR` | `${RW_NODE_DIR}/www` | Caddy 静态伪装页面生成目录，启动时会重建；自定义非空目录需要 `.rw-node-caddy-site-dir` marker |
| `CADDY_DEFAULT_SITE_DIR` | `/opt/rw-node/default-www` | 镜像内置默认静态页面目录，通常不需要手动设置 |
| `RW_NODE_APP_DIR` | `/opt/rw-node` | PaaS 镜像内应用文件目录，通常不要修改 |
| `INBOUND_WATCHER_ENABLED` | `true` | 是否启用 Inbound 动态分流 watcher，详见下方说明 |
| `INBOUND_WATCHER_INTERVAL` | `15` | Inbound watcher 轮询间隔（秒） |

## Inbound 动态分流

Go PaaS 镜像默认启用 Inbound 动态分流（`INBOUND_WATCHER_ENABLED=true`）。启用后，后台 watcher 会轮询 rw-node-go 内部 API，自动提取 Panel 下发的所有 inbound 配置，按协议类型生成对应的分流规则并热重载 Caddy。

支持的分流方式：

- **REALITY SNI 分流**（L4 层）：提取 REALITY inbound 的 `serverNames` 和端口，生成 Caddy Layer 4 SNI 规则，TLS + 匹配的 SNI 直通到对应 Xray 端口
- **HTTP 路径分流**（HTTP 层）：提取 ws/xhttp/httpupgrade inbound 的 path 和端口，为每个 path 生成精确路由规则
- **冲突检测**：同一 path 被多个不同端口的 inbound 使用时，发出警告并跳过该 path
- **兜底路由**：无具体 ws/xhttp inbound 时，保留 `/xh-*` → `XHTTP_UPSTREAM_PORT` 和 `/ws-*` → `WS_UPSTREAM_PORT` 通配符路由

分流效果：

```text
PaaS 入站端口
  ├─ TLS + SNI 匹配 REALITY 伪装域名 → 127.0.0.1:REALITY_PORT（TCP 直通）
  ├─ TLS + 其他 SNI（Panel 连接等）   → 127.0.0.1:NODE_PORT
  └─ 非 TLS                           → Caddy HTTP 路径路由
                                          ├─ /ws-a  → 127.0.0.1:8080
                                          ├─ /xh-b  → 127.0.0.1:8081
                                          └─ 其他   → 静态伪装页面
```

Panel 连接使用 PaaS HTTPS 域名作为 SNI，REALITY 客户端使用伪装域名（如 `www.microsoft.com`）作为 SNI，两者天然不同，Caddy Layer 4 可以按 SNI 区分。

Inbound 配置由 Panel 动态下发，watcher 会在每次轮询时检查配置变化，仅在路由状态改变时重载 Caddy。Panel 未下发配置或没有可分流的 inbound 时，保持默认兜底行为。

设为 `INBOUND_WATCHER_ENABLED=false` 可完全禁用此功能。

## xhttp / WebSocket 路径

如果使用 Caddy HTTP 前置承载 xhttp/ws 流量，客户端或面板下发的 xhttp/ws 配置应填写 PaaS 提供的 HTTP/HTTPS 域名和单个公网端口，并用不同路径前缀区分协议。

- xhttp inbound 默认转发到本机 `8080` 明文 HTTP。
- ws inbound 默认转发到本机 `8880` 明文 HTTP。
- 只有以 `/xh-` 或 `/ws-` 开头的路径会被转发。

## 常见问题

### Panel 无法连接节点

优先检查三点：

1. Remnawave Panel 中节点地址是否填写 PaaS 提供的 HTTPS 域名。
2. 节点环境变量是否设置了 `NODE_TLS_CLIENT_AUTH=none`。
3. Panel 容器是否配置了 `NODE_OPTIONS` 预加载脚本以信任 PaaS 平台公共证书，详见上方「推荐链路」部分。

### `application entrypoint is missing`

优先检查 PaaS 是否把持久化卷挂载到了 `/opt/rw-node` 并覆盖了镜像内应用文件。

PaaS 镜像默认会从 `/opt/rw-node` 读取应用文件。不要把空卷挂载到这个路径，也不要把 `RW_NODE_DIR` 指向不包含 `dist/`、`node_modules/` 的目录。

### 端口是否需要公开

PaaS 场景通常只公开平台分配的 HTTP/HTTPS 入口端口。

`XTLS_API_PORT` 和 `INTERNAL_REST_PORT` 都是内部端口，不应通过 Docker、VPS 防火墙或 PaaS 入站公开。
