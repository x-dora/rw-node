#!/bin/bash

#######################################
# RW-Node 启动脚本
#######################################

set -e

# 可配置的工作目录（默认 /opt/rw-node）
WORK_DIR="${RW_NODE_DIR:-/opt/rw-node}"

# 目录结构
BIN_DIR="${WORK_DIR}/bin"
LOG_DIR="${WORK_DIR}/logs"
RUN_DIR="${WORK_DIR}/run"
CONF_DIR="${WORK_DIR}/conf"

# 创建必要目录
mkdir -p "${BIN_DIR}" "${LOG_DIR}" "${RUN_DIR}" "${CONF_DIR}"

# 清理旧的 socket 文件
rm -f "${RUN_DIR}"/remnawave-internal-*.sock 2>/dev/null
rm -f "${RUN_DIR}"/supervisord-*.sock 2>/dev/null
rm -f "${RUN_DIR}"/supervisord-*.pid 2>/dev/null

echo "[Entrypoint] Starting..."
echo "[Entrypoint] Work directory: ${WORK_DIR}"

# 生成随机凭据
generate_random() {
    local length="${1:-64}"
    dd if=/dev/urandom bs=256 count=1 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

RNDSTR=$(generate_random 10)
SUPERVISORD_USER=$(generate_random 64)
SUPERVISORD_PASSWORD=$(generate_random 64)
INTERNAL_REST_TOKEN=$(generate_random 64)

# 设置完整路径（使用工作目录）
INTERNAL_SOCKET_PATH="${RUN_DIR}/remnawave-internal-${RNDSTR}.sock"
SUPERVISORD_SOCKET_PATH="${RUN_DIR}/supervisord-${RNDSTR}.sock"
SUPERVISORD_PID_PATH="${RUN_DIR}/supervisord-${RNDSTR}.pid"

export SUPERVISORD_USER SUPERVISORD_PASSWORD INTERNAL_REST_TOKEN
export INTERNAL_SOCKET_PATH SUPERVISORD_SOCKET_PATH SUPERVISORD_PID_PATH

echo "[Credentials] OK"

# 查找二进制文件路径（优先使用工作目录）
find_binary() {
    local name=$1
    if [[ -x "${BIN_DIR}/${name}" ]]; then
        echo "${BIN_DIR}/${name}"
    elif [[ -x "/usr/local/bin/${name}" ]]; then
        echo "/usr/local/bin/${name}"
    else
        echo "${name}"
    fi
}

SUPERVISORD_BIN=$(find_binary supervisord)
XRAY_BIN=$(find_binary rw-core)

# 动态生成 supervisord 配置
cat > "${CONF_DIR}/supervisord.conf" << EOF
[supervisord]
nodaemon=true
user=root
logfile=${LOG_DIR}/supervisord.log
pidfile=${SUPERVISORD_PID_PATH}
childlogdir=${LOG_DIR}
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
command=${XRAY_BIN} -config http+unix://${INTERNAL_SOCKET_PATH}/internal/get-config?token=${INTERNAL_REST_TOKEN} -format json
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
"${SUPERVISORD_BIN}" -c "${CONF_DIR}/supervisord.conf" &
echo "[Entrypoint] Supervisord started"
sleep 1

# 获取 Xray 版本
XRAY_CORE_VERSION=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || echo "unknown")
export XRAY_CORE_VERSION
echo "[Entrypoint] Xray version: $XRAY_CORE_VERSION"

# 加载环境变量
if [[ -f "${WORK_DIR}/.env" ]]; then
    set -a
    source "${WORK_DIR}/.env"
    set +a
fi

echo "[Entrypoint] XTLS_API_PORT: ${XTLS_API_PORT:-61000}"

# 启动 Node.js 应用
echo "[Entrypoint] Starting Node.js..."
cd "${WORK_DIR}"

if [[ -x "${WORK_DIR}/node/bin/node" ]]; then
    exec "${WORK_DIR}/node/bin/node" dist/src/main
else
    exec node dist/src/main
fi
