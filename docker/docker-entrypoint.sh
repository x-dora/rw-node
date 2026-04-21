#!/bin/bash

set -euo pipefail

WORK_DIR="${RW_NODE_DIR:-/opt/rw-node}"
LOG_DIR="${WORK_DIR}/logs"
RUN_DIR="${WORK_DIR}/run"
CONF_DIR="${WORK_DIR}/conf"
NODE_PID_PATH="${RUN_DIR}/rw-node.pid"

mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${CONF_DIR}"

rm -f "${RUN_DIR}"/remnawave-internal-*.sock 2>/dev/null || true
rm -f "${RUN_DIR}"/supervisord-*.sock 2>/dev/null || true
rm -f "${RUN_DIR}"/supervisord-*.pid 2>/dev/null || true
rm -f "${NODE_PID_PATH}" 2>/dev/null || true

generate_random() {
    local length="${1:-64}"
    local value

    set +o pipefail
    value=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length")
    set -o pipefail
    printf '%s' "$value"
}

wait_for_socket() {
    local socket_path="$1"
    local pid="$2"
    local i

    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -S "$socket_path" ]]; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done

    return 1
}

if [[ -z "${SECRET_KEY:-}" ]]; then
    echo "[Entrypoint] ERROR: SECRET_KEY is required"
    exit 1
fi

if [[ ! -f "${WORK_DIR}/dist/src/main" ]]; then
    echo "[Entrypoint] ERROR: application files are missing in ${WORK_DIR}"
    exit 1
fi

SUPERVISORD_USER="${SUPERVISORD_USER:-$(generate_random 64)}"
SUPERVISORD_PASSWORD="${SUPERVISORD_PASSWORD:-$(generate_random 64)}"
INTERNAL_REST_TOKEN="${INTERNAL_REST_TOKEN:-$(generate_random 64)}"
RNDSTR="$(generate_random 10)"

INTERNAL_SOCKET_PATH="${RUN_DIR}/remnawave-internal-${RNDSTR}.sock"
SUPERVISORD_SOCKET_PATH="${RUN_DIR}/supervisord-${RNDSTR}.sock"
SUPERVISORD_PID_PATH="${RUN_DIR}/supervisord-${RNDSTR}.pid"

export SUPERVISORD_USER SUPERVISORD_PASSWORD INTERNAL_REST_TOKEN
export INTERNAL_SOCKET_PATH SUPERVISORD_SOCKET_PATH SUPERVISORD_PID_PATH

SUPERVISORD_BIN="/usr/local/bin/supervisord"
XRAY_BIN="/usr/local/bin/rw-core"

export NODE_PORT="${NODE_PORT:-2222}"
export XTLS_API_PORT="${XTLS_API_PORT:-61000}"

echo "[Entrypoint] Starting..."
echo "[Entrypoint] Work directory: ${WORK_DIR}"

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

"${SUPERVISORD_BIN}" -c "${CONF_DIR}/supervisord.conf" &
SUPERVISORD_PID=$!

if ! wait_for_socket "${SUPERVISORD_SOCKET_PATH}" "${SUPERVISORD_PID}"; then
    echo "[Entrypoint] ERROR: Supervisord failed to start"
    exit 1
fi

XRAY_CORE_VERSION=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || echo "unknown")
export XRAY_CORE_VERSION

echo "[Entrypoint] Supervisord started"
echo "[Entrypoint] Xray version: ${XRAY_CORE_VERSION}"
echo "[Entrypoint] XTLS_API_PORT: ${XTLS_API_PORT}"

cd "${WORK_DIR}"
echo "$$" > "${NODE_PID_PATH}"

if [[ $# -eq 0 ]]; then
    set -- node dist/src/main
fi

echo "[Entrypoint] Executing: $*"
exec "$@"
