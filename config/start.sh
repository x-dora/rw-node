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

# 动态生成 supervisord 配置文件（将凭据直接写入配置）
cat > /tmp/supervisord.conf << EOF
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor
logfile_maxbytes=5MB
logfile_backups=2
loglevel=info
silent=true
environment=INTERNAL_REST_TOKEN="${INTERNAL_REST_TOKEN}",SUPERVISORD_USER="${SUPERVISORD_USER}",SUPERVISORD_PASSWORD="${SUPERVISORD_PASSWORD}"

[unix_http_server]
file = /run/supervisord.sock
username = ${SUPERVISORD_USER}
password = ${SUPERVISORD_PASSWORD}

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[program:xray]
command=/usr/local/bin/rw-core -config http+unix:///run/remnawave-internal.sock/internal/get-config?token=${INTERNAL_REST_TOKEN} -format json
autostart=false
autorestart=false
stderr_logfile=/var/log/supervisor/xray.err.log
stdout_logfile=/var/log/supervisor/xray.out.log
stdout_logfile_maxbytes=5MB
stderr_logfile_maxbytes=5MB
stdout_logfile_backups=0
stderr_logfile_backups=0
EOF

echo "[Entrypoint] Supervisord config generated"

# 启动 supervisord（后台运行，使用生成的配置）
supervisord -c /tmp/supervisord.conf &
echo "[Entrypoint] Supervisord started successfully"

# 等待 supervisord 就绪
sleep 1

# 获取 Xray 版本
echo "[Entrypoint] Getting Xray version..."
XRAY_CORE_VERSION=$(/usr/local/bin/rw-core version | head -n 1)
export XRAY_CORE_VERSION
echo "[Entrypoint] Xray version: $XRAY_CORE_VERSION"

# 加载环境变量
if [[ -f /opt/rw-node/.env ]]; then
    set -a
    source /opt/rw-node/.env
    set +a
fi

echo "[Ports] XTLS_API_PORT: $XTLS_API_PORT"

# 启动 Node.js 应用
echo "[Entrypoint] Starting Node.js application..."
cd /opt/rw-node
exec node dist/src/main
