# RW-Node 轻量化部署

无需 Docker 的 Remnawave Node 一键部署方案。

## 功能特性

- 🚀 一键安装/卸载/更新
- 🔧 无需 Docker，轻量化部署
- 🌐 内置 Cloudflare Tunnel 支持（可选）
- 🔄 自动同步上游版本构建

## 系统要求

- Linux 系统（Ubuntu/Debian/CentOS/RHEL/Fedora）
- x86_64 或 arm64 架构
- Root 权限
- Node.js 22+（脚本会自动安装，需要支持 zstd 压缩）

## 快速安装

### 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh)
```

### 安装时启用 Cloudflare Tunnel

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) --with-cloudflared
```

### 指定版本安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh) --version v2.5.2
```

## 管理命令

### 服务管理

```bash
# 启动服务
systemctl start rw-node

# 停止服务
systemctl stop rw-node

# 重启服务
systemctl restart rw-node

# 查看服务状态
systemctl status rw-node

# 查看日志
journalctl -u rw-node -f
```

### Cloudflare Tunnel 管理（如已安装）

```bash
# 启动 Cloudflare Tunnel
systemctl start cloudflared

# 停止 Cloudflare Tunnel
systemctl stop cloudflared

# 查看状态
systemctl status cloudflared
```

### 更新

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/update.sh)
```

### 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/uninstall.sh)
```

## 配置文件

- 主配置文件: `/opt/rw-node/.env`
- Supervisord 配置: `/etc/supervisord.conf`
- Systemd 服务: `/etc/systemd/system/rw-node.service`

## 环境变量

| 变量名 | 描述 | 默认值 |
|--------|------|--------|
| `NODE_PORT` | 节点端口 | `2222` |
| `SECRET_KEY` | 面板密钥 | - |
| `XTLS_API_PORT` | Xray API 端口 | `61000` |

## 目录结构

```
/opt/rw-node/
├── dist/                 # 编译后的代码
├── libs/                 # 依赖库
├── node_modules/         # Node.js 依赖
├── .env                  # 环境配置
└── package.json          # 包信息

/usr/local/bin/
├── xray                  # Xray 核心
└── rw-core               # Xray 软链接

/var/log/supervisor/
├── xray.out.log          # Xray 输出日志
├── xray.err.log          # Xray 错误日志
└── supervisord.log       # Supervisord 日志
```

## 许可证

AGPL-3.0-only

## 相关链接

- [Remnawave Panel 文档](https://docs.rw/)
- [原始 Node 仓库](https://github.com/remnawave/node)
