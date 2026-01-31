#!/bin/bash

#######################################
# RW-Node 启动脚本
# 与 Docker entrypoint 保持一致的启动逻辑
#######################################

set -e

echo "[Entrypoint] Starting entrypoint script..."

# 生成随机凭据的函数
generate_random() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 64
}

# 生成运行时凭据
SUPERVISORD_USER=$(generate_random)
SUPERVISORD_PASSWORD=$(generate_random)
INTERNAL_REST_TOKEN=$(generate_random)

export SUPERVISORD_USER
export SUPERVISORD_PASSWORD
export INTERNAL_REST_TOKEN

echo "[Credentials] OK"

# 清理旧的 socket 文件
rm -f /run/supervisord.sock
rm -f /run/remnawave-internal.sock
rm -f /run/supervisord.pid

# 启动 supervisord（后台运行）
supervisord -c /etc/supervisord.conf &
echo "[Entrypoint] Supervisord started successfully"

# 等待 supervisord 就绪
sleep 1

# 获取 Xray 版本
echo "[Entrypoint] Getting Xray version..."
XRAY_CORE_VERSION=$(/usr/local/bin/rw-core version | head -n 1)
export XRAY_CORE_VERSION
echo "[Entrypoint] Xray version: $XRAY_CORE_VERSION"
echo "[Ports] XTLS_API_PORT: $XTLS_API_PORT"

# 启动 Node.js 应用
echo "[Entrypoint] Starting Node.js application..."
cd /opt/rw-node
exec node dist/src/main
