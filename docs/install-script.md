# 一键脚本安装

一键脚本适合没有 Docker 的 VPS、VM 或容器环境。脚本会安装 [x-dora/rw-node-go](https://github.com/x-dora/rw-node-go) Go 实现及所需组件（Caddy、Xray geodata），生成配置，并根据环境使用 systemd 服务或前台辅助命令管理进程。

## 系统要求

- Linux：Ubuntu、Debian、CentOS、RHEL、Fedora、Alpine
- x86_64 或 arm64 架构
- Root 权限
- bash 和 curl

安装器会自动补齐 jq、unzip 等依赖。

## 安装

交互安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh)
```

静默安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --secret-key YOUR_SECRET_KEY \
  --port 2222
```

指定 rw-node-go 版本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --go-version v0.5.0 \
  --secret-key YOUR_SECRET_KEY \
  --port 2222
```

安装 Cloudflare Tunnel：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --with-cloudflared \
  --cloudflared-token YOUR_TUNNEL_TOKEN
```

## 安装参数

| 参数 | 描述 | 默认值 |
|------|------|--------|
| `--go-version <版本>` | 指定 `rw-node-go` release 版本 | 最新 release |
| `--port, -p <端口>` | 节点主 API 监听端口 | `2222` |
| `--secret-key, -k <密钥>` | Remnawave Panel 中的节点密钥；非交互安装时必填 | - |
| `--internal-rest-port <端口>` | Internal REST 本机端口 | `61001` |
| `--node-tls-client-auth <mtls\|optional\|none>` | 主 API 的 TLS 客户端证书策略 | `mtls` |
| `--with-cloudflared` | 安装 Cloudflare Tunnel 二进制 | 关闭 |
| `--cloudflared-token <令牌>` | 写入 Cloudflare Tunnel token | - |

## 安装内容

安装脚本会在工作目录（默认 `/opt/rw-node`）中安装以下组件：

| 组件 | 路径 | 说明 |
|------|------|------|
| rw-node-go | `bin/rw-node-go` | Go 实现主程序 |
| Caddy (L4) | `bin/caddy` | 带 Layer 4 插件的 Caddy，支持 TLS/HTTP 复用 |
| geocheck | `bin/geocheck` | `stats/get-geocheck` 路由依赖的报告二进制（best-effort，失败仅告警） |
| Xray geodata | `share/xray/geoip.dat`, `geosite.dat` | Xray 路由规则数据 |
| 共享库 | `lib/` | core.sh, caddy.sh, provision.sh 等共享脚本 |
| 默认伪装页面 | `default-www/` | mikutap 静态页面（Caddy HTTP 前置使用） |
| cloudflared | `bin/cloudflared` | Cloudflare Tunnel（可选） |

geocheck 安装成功时，安装器会在 `.env` 中写入 `GEOCHECK_BINARY_PATH` 指向 `bin/geocheck`。

## 管理命令

有 systemd 的环境：

```bash
systemctl start rw-node
systemctl stop rw-node
systemctl restart rw-node
systemctl status rw-node
journalctl -u rw-node -f
```

容器或无 systemd 环境：

```bash
rw-node-start
rw-node-stop
rw-node-status
```

## 更新

重新运行安装脚本即可更新到最新版本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --secret-key YOUR_SECRET_KEY
```

指定版本更新：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --go-version v0.5.0 \
  --secret-key YOUR_SECRET_KEY
```

> 覆盖安装会重新生成 `.env`，请提前备份自定义配置。

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/uninstall.sh)
```

`uninstall.sh` 会删除安装目录、systemd 服务和本项目创建的 `/usr/local/bin` 符号链接，必须在交互终端中确认后才会执行。

## 工作目录

默认工作目录为 `/opt/rw-node`，可通过 `RW_NODE_DIR` 自定义：

```bash
RW_NODE_DIR=/data/rw-node bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh)
```

## HTTP 前置（可选）

一键安装也支持启用 Caddy HTTP 前置（与 Docker PaaS 镜像相同的能力），在 `.env` 中设置：

```bash
HTTP_FRONT_ENABLED=true
```

启用后，Caddy Layer 4 会在 `HTTP_FRONT_PORT`（默认 3000）上监听，复用 TLS 和 HTTP 流量：
- TLS 连接直通到 `NODE_PORT`
- `/xh-*` 路径转发到 `XHTTP_UPSTREAM_PORT`（默认 8080）
- `/ws-*` 路径转发到 `WS_UPSTREAM_PORT`（默认 8880）
- 其他路径返回静态伪装页面

## 常用环境变量

| 变量名 | 描述 | 默认值 |
|--------|------|--------|
| `NODE_PORT` | 节点主 API 监听端口 | `2222` |
| `SECRET_KEY` | Remnawave Panel 中的节点密钥 | - |
| `INTERNAL_REST_PORT` | 本机 Internal REST 端口，不要公开 | `61001` |
| `NODE_TLS_CLIENT_AUTH` | TLS 客户端证书策略 | `mtls` |
| `SNI_VERIFICATION` | Panel 派生 SNI 门控开关（详见 PaaS 文档「Panel SNI 验证」） | `false` |
| `GEOCHECK_BINARY_PATH` | geocheck 二进制路径覆盖（安装器自动写入） | - |
| `RW_NODE_DIR` | 工作目录 | `/opt/rw-node` |
| `XRAY_LOCATION_ASSET` | Xray 资源文件目录 | `${RW_NODE_DIR}/share/xray` |
| `HTTP_FRONT_ENABLED` | 是否启用 Caddy HTTP 前置 | `false` |

## 注意事项

- 安装脚本需要 root 权限运行。
- 所有核心运行文件默认放在 `/opt/rw-node`。
- `INTERNAL_REST_PORT` 是内部端口，不应公开到公网。
