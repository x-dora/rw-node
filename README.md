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
| `ghcr.io/x-dora/rw-node:latest` | 轻量版 (Go Supervisord, 无 Python) | ~180MB |
| `ghcr.io/x-dora/rw-node:latest-official` | 官方兼容版 (Python Supervisord) | ~250MB |

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

### 方式二：一键脚本安装

#### 系统要求

- Linux（Ubuntu/Debian/CentOS/RHEL/Fedora/Alpine）
- x86_64 或 arm64 架构
- Root 权限
- curl（大多数系统已预装）

> Node.js 和 Supervisord 会自动下载预编译二进制文件，**无需 Python**

#### 安装

```bash
# 一键安装
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh)

# 安装时启用 Cloudflare Tunnel
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) --with-cloudflared

# 指定版本
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) --version 2.5.2

# 静默安装（无交互）
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) \
  --secret-key YOUR_SECRET_KEY \
  --port 2222
```

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

## 与官方镜像的区别

| 特性 | 官方镜像 | 本项目镜像 |
|------|----------|-----------|
| Python | ✅ 需要 | ❌ 不需要 |
| Supervisord | Python 版 | Go 版 (ochinchina/supervisord) |
| 镜像大小 | ~300MB | ~200MB |
| 依赖 | Python, pip | 无额外依赖 |
| 容器环境检测 | ❌ | ✅ |
| 健康检查 | ❌ | ✅ |

## 目录结构

```
/opt/rw-node/
├── .env              # 环境变量配置
├── start.sh          # 启动脚本
├── dist/             # 编译后的代码
├── libs/             # 库文件
├── node_modules/     # 依赖
├── node/             # Node.js 二进制
└── package.json

/var/log/supervisor/
├── supervisord.log   # Supervisord 日志
├── xray.out.log      # Xray 输出日志
└── xray.err.log      # Xray 错误日志
```

## 许可证

AGPL-3.0-only

## 相关链接

- [Remnawave Panel 文档](https://docs.rw/)
- [原始 Node 仓库](https://github.com/remnawave/node)
- [Go Supervisord](https://github.com/ochinchina/supervisord)
