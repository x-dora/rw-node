#!/bin/bash

#######################################
# RW-Node 启动脚本
#######################################

set -e

INSTALL_DIR="/opt/rw-node"
LOG_DIR="/var/log/supervisor"

echo "[Entrypoint] Starting..."

# 生成随机凭据（使用 dd 避免 broken pipe 警告）
generate_random() {
    dd if=/dev/urandom bs=64 count=1 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 64
}

SUPERVISORD_USER=$(generate_random)
SUPERVISORD_PASSWORD=$(generate_random)
INTERNAL_REST_TOKEN=$(generate_random)
SOCKETS_RNDSTR=$(head -c 20 /dev/urandom | xxd -p 2>/dev/null | head -c 10 || dd if=/dev/urandom bs=10 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 10)

export SUPERVISORD_USER SUPERVISORD_PASSWORD INTERNAL_REST_TOKEN SOCKETS_RNDSTR

echo "[Credentials] OK"

# 清理旧的 socket 文件
rm -f /run/supervisord.sock /run/remnawave-internal.sock /run/supervisord.pid

# 确保日志目录存在
mkdir -p $LOG_DIR

# 动态生成 supervisord 配置
cat > /tmp/supervisord.conf << EOF
[supervisord]
nodaemon=true
user=root
logfile=${LOG_DIR}/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=${LOG_DIR}
logfile_maxbytes=5MB
logfile_backups=2
loglevel=info
silent=true
environment=INTERNAL_REST_TOKEN="${INTERNAL_REST_TOKEN}",SUPERVISORD_USER="${SUPERVISORD_USER}",SUPERVISORD_PASSWORD="${SUPERVISORD_PASSWORD}",SOCKETS_RNDSTR="${SOCKETS_RNDSTR}"

[unix_http_server]
file=/run/supervisord.sock
username=${SUPERVISORD_USER}
password=${SUPERVISORD_PASSWORD}

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[program:xray]
command=/usr/local/bin/rw-core -config http+unix:///run/remnawave-internal.sock/internal/get-config?token=${INTERNAL_REST_TOKEN} -format json
autostart=false
autorestart=false
stderr_logfile=${LOG_DIR}/xray.err.log
stdout_logfile=${LOG_DIR}/xray.out.log
stdout_logfile_maxbytes=5MB
stderr_logfile_maxbytes=5MB
stdout_logfile_backups=0
stderr_logfile_backups=0
EOF

echo "[Entrypoint] Config generated"

# 启动 supervisord
supervisord -c /tmp/supervisord.conf &
echo "[Entrypoint] Supervisord started"
sleep 1

# 获取 Xray 版本
XRAY_CORE_VERSION=$(/usr/local/bin/rw-core version 2>/dev/null | head -n 1 || echo "unknown")
export XRAY_CORE_VERSION
echo "[Entrypoint] Xray version: $XRAY_CORE_VERSION"

# 加载环境变量
if [[ -f ${INSTALL_DIR}/.env ]]; then
    set -a
    source ${INSTALL_DIR}/.env
    set +a
fi

echo "[Entrypoint] XTLS_API_PORT: ${XTLS_API_PORT:-61000}"

# 启动 Node.js 应用
echo "[Entrypoint] Starting Node.js..."
cd ${INSTALL_DIR}

if [[ -x "${INSTALL_DIR}/node/bin/node" ]]; then
    exec ${INSTALL_DIR}/node/bin/node dist/src/main
else
    exec node dist/src/main
fi
