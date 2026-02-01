#!/bin/sh

# 清理旧的 socket 文件
rm -f /run/remnawave-internal-*.sock 2>/dev/null
rm -f /run/supervisord-*.sock 2>/dev/null
rm -f /run/supervisord-*.pid 2>/dev/null

echo "[Entrypoint] Starting..."

# 生成随机凭据
generate_random() {
    local length="${1:-64}"
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
}

RNDSTR=$(generate_random 10)
SUPERVISORD_USER=$(generate_random 64)
SUPERVISORD_PASSWORD=$(generate_random 64)
INTERNAL_REST_TOKEN=$(generate_random 64)

# 设置完整路径（新格式）
INTERNAL_SOCKET_PATH=/run/remnawave-internal-${RNDSTR}.sock
SUPERVISORD_SOCKET_PATH=/run/supervisord-${RNDSTR}.sock
SUPERVISORD_PID_PATH=/run/supervisord-${RNDSTR}.pid

export SUPERVISORD_USER SUPERVISORD_PASSWORD INTERNAL_REST_TOKEN
export INTERNAL_SOCKET_PATH SUPERVISORD_SOCKET_PATH SUPERVISORD_PID_PATH

echo "[Credentials] OK"

# 动态生成 supervisord 配置
cat > /tmp/supervisord.conf << EOF
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=${SUPERVISORD_PID_PATH}
childlogdir=/var/log/supervisor
logfile_maxbytes=5MB
logfile_backups=2
loglevel=info
silent=true

[unix_http_server]
file=${SUPERVISORD_SOCKET_PATH}
username=${SUPERVISORD_USER}
password=${SUPERVISORD_PASSWORD}

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[program:xray]
command=/usr/local/bin/rw-core -config http+unix://${INTERNAL_SOCKET_PATH}/internal/get-config?token=${INTERNAL_REST_TOKEN} -format json
autostart=false
autorestart=false
stderr_logfile=/var/log/supervisor/xray.err.log
stdout_logfile=/var/log/supervisor/xray.out.log
stdout_logfile_maxbytes=5MB
stderr_logfile_maxbytes=5MB
stdout_logfile_backups=0
stderr_logfile_backups=0
EOF

# 启动 supervisord
supervisord -c /tmp/supervisord.conf &
echo "[Entrypoint] Supervisord started"
sleep 1

# 获取 Xray 版本
XRAY_CORE_VERSION=$(/usr/local/bin/rw-core version 2>/dev/null | head -n 1 || echo "unknown")
export XRAY_CORE_VERSION
echo "[Entrypoint] Xray version: $XRAY_CORE_VERSION"
echo "[Entrypoint] XTLS_API_PORT: $XTLS_API_PORT"

# 执行传入的命令
echo "[Entrypoint] Executing: $@"
exec "$@"
