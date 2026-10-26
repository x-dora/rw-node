# RW-Node 轻量化部署

RW-Node 是 [remnawave/node](https://github.com/remnawave/node) 的轻量化部署方案，使用非官方 [x-dora/rw-node-go](https://github.com/x-dora/rw-node-go) Go 实现。

## 选择部署方式

| 场景 | 推荐方式 | 说明 |
|------|----------|------|
| PaaS / Docker / 更小体积 | `ghcr.io/x-dora/rw-node:latest` | Go 实现，内置前置分流，无 Node.js 运行时 |
| 没有 Docker 的 VPS / 容器 | `scripts/install.sh` | 自动安装 rw-node-go、rw-node-front、Xray geodata |

## 快速开始

### Docker PaaS HTTPS 直连

```bash
docker run -d \
  --name rw-node \
  -e SECRET_KEY=YOUR_SECRET_KEY \
  -e NODE_PORT=2222 \
  -e NODE_TLS_CLIENT_AUTH=none \
  -e XTLS_API_PORT=61000 \
  ghcr.io/x-dora/rw-node:latest
```

PaaS 场景通常使用平台分配的 HTTPS 域名作为 Remnawave Panel 中的节点地址，例如：

```text
https://rw-node.example-paas.app
```

Panel 端还需要配置 `NODE_OPTIONS` 预加载脚本以信任 PaaS 平台公共证书。详细配置见 [PaaS HTTPS 直连文档](docs/paas.md)。

### Docker Compose

```yaml
services:
  rw-node:
    image: ghcr.io/x-dora/rw-node:latest
    container_name: rw-node
    restart: unless-stopped
    environment:
      - SECRET_KEY=YOUR_SECRET_KEY
      - NODE_PORT=2222
      - NODE_TLS_CLIENT_AUTH=none
```

### 一键脚本安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --secret-key YOUR_SECRET_KEY \
  --port 2222
```

更多参数和管理命令见 [一键脚本安装文档](docs/install-script.md)。

## 镜像标签

| 标签 | 描述 |
|------|------|
| `ghcr.io/x-dora/rw-node:latest` | Go 实现 PaaS 版（= `latest-go-paas`） |
| `ghcr.io/x-dora/rw-node:latest-go-paas` | Go 实现 PaaS 版（别名） |

Release workflow 也会发布固定版本标签：

- `ghcr.io/x-dora/rw-node:<go-version>` — Go 实现版本号（如 `0.5.0`）
- `ghcr.io/x-dora/rw-node:<go-version>-go-paas` — 同上（别名）

## 常用环境变量

| 变量名 | 描述 | 默认值 |
|--------|------|--------|
| `NODE_PORT` | 节点主 API 监听端口 | `2222` |
| `SECRET_KEY` | Remnawave Panel 中的节点密钥 | - |
| `INTERNAL_REST_PORT` | Internal REST 内部端口，不要公开 | `61001` |
| `NODE_TLS_CLIENT_AUTH` | TLS 客户端证书策略，PaaS 常用 `none` | `mtls` |
| `RW_NODE_DIR` | 脚本安装时的工作目录 | `/opt/rw-node` |
| `HYSTERIA_LISTEN_PORT` | 覆盖面板下发的 hysteria 端口；未设置时若存在 `PORT` 则自动跟随 `HTTP_FRONT_PORT` | 面板值 |

PaaS 镜像还支持 `PORT`、`HTTP_FRONT_ENABLED`、`HTTP_FRONT_PORT`、`XHTTP_UPSTREAM_PORT`、`WS_UPSTREAM_PORT`、`CADDY_INDEX_PAGE`、`CADDY_DEFAULT_SITE_DIR`、`RW_NODE_APP_DIR` 等变量，见 [PaaS HTTPS 直连文档](docs/paas.md)。

### 单端口 PaaS 上跑 Hysteria

平台只映射一个端口时，`HTTP_FRONT_PORT` 已经占掉了它。Hysteria 走 QUIC（UDP），与前置分流器的同名 TCP 端口不冲突，所以直接复用同一个端口号即可：启动脚本检测到 `PORT` 就自动把 `HYSTERIA_LISTEN_PORT` 设成 `HTTP_FRONT_PORT`，无需手工配置。裸 VPS 上不存在 `PORT`，行为不变。

覆盖后：

- 面板里 inbound 的 `port` 不再生效，本节点实际监听的是 `HYSTERIA_LISTEN_PORT`；
- 面板里必须**单独建一条 Host**，`address:port` 写这个端口。共用原端口的那条 Host 会把客户端指向没映射的端口；
- 客户端 MTU 要压到 1400 以下——PaaS 网络常见 1500 字节以上整包丢弃，表现是能连上但打不开网页。

## 重要注意事项

- `SECRET_KEY` 必须和 Remnawave Panel 中配置的节点密钥一致。
- `INTERNAL_REST_PORT` 是内部端口，不应通过 Docker、VPS 防火墙或 PaaS 入站公开。
- PaaS HTTPS 直连推荐设置 `NODE_TLS_CLIENT_AUTH=none`，并在 Panel 端通过 `NODE_OPTIONS` 预加载脚本信任 PaaS 平台公共证书。
- 不要把 PaaS 持久化卷挂载到 `/opt/rw-node`，也不要把 `RW_NODE_DIR` 指向空目录，否则可能覆盖镜像内应用文件并导致 `application entrypoint is missing`。

## 详细文档

- [PaaS HTTPS 直连](docs/paas.md)
- [一键脚本安装](docs/install-script.md)
- [Panel 证书校验预加载脚本](config/panel/disable-tls-verify.cjs)

## 许可证

AGPL-3.0-only

## 相关链接

- [Remnawave Panel 文档](https://docs.rw/)
- [原始 Node 仓库](https://github.com/remnawave/node)
- [Go 实现](https://github.com/x-dora/rw-node-go)
