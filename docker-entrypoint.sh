#!/bin/bash

set -euo pipefail

APP_BIN="/usr/local/bin/rw-node-go"
FRONT_BIN="${FRONT_BIN:-$(command -v rw-node-front 2>/dev/null || true)}"
WORK_DIR="${RW_NODE_DIR:-/opt/rw-node}"
CONF_DIR="${WORK_DIR}/conf"
# 兼容改造前的 CADDY_SITE_DIR：老部署的环境变量里写的是旧名字。
FRONT_SITE_DIR="${FRONT_SITE_DIR:-${CADDY_SITE_DIR:-${WORK_DIR}/www}}"
FRONT_DEFAULT_SITE_DIR="${FRONT_DEFAULT_SITE_DIR:-${CADDY_DEFAULT_SITE_DIR:-/opt/rw-node/default-www}}"
SITE_BUILD_DIR="${SITE_BUILD_DIR:-${CONF_DIR}/site}"
SSH_DIR="${SSH_DIR:-${WORK_DIR}/ssh}"
LOG_PREFIX="[Go PaaS]"

RW_NODE_LIB_DIR="${RW_NODE_LIB_DIR:-/usr/local/lib/rw-node}"
# shellcheck source=lib/core.sh
source "${RW_NODE_LIB_DIR}/core.sh"
# shellcheck source=lib/front.sh
source "${RW_NODE_LIB_DIR}/front.sh"
# shellcheck source=lib/ssh.sh
source "${RW_NODE_LIB_DIR}/ssh.sh"

set_default_env

app_pid=""
health_pid=""
front_pid=""
ssh_service_pid=""

terminate() {
    trap - INT TERM
    local _pid
    for _pid in app_pid health_pid ssh_service_pid front_pid; do
        kill_if_running "${_pid}"
    done
    wait 2>/dev/null || true
}

start_health_server() {
    if [[ -z "${PORT:-}" ]]; then
        return 0
    fi

    if ! is_port "${PORT}"; then
        fail "PORT must be a valid TCP port"
    fi

    if [[ "${PORT}" == "${NODE_PORT}" ]]; then
        log "PORT equals NODE_PORT; skipping auxiliary HTTP health server"
        return 0
    fi

    log "Starting auxiliary HTTP health server on port ${PORT}"
    printf 'ok\n' > /tmp/index.html
    busybox httpd -f -p "0.0.0.0:${PORT}" -h /tmp &
    health_pid=$!
}

trap terminate INT TERM

if ! is_port "${NODE_PORT}"; then
    fail "NODE_PORT must be a valid TCP port"
fi

if [[ ! -x "${APP_BIN}" ]]; then
    fail "rw-node-go binary not found"
fi

mkdir -p "${WORK_DIR}"
if [[ "${HTTP_FRONT_ENABLED}" == "true" ]]; then
    start_ssh_service
    start_front_proxy
elif [[ "${HTTP_FRONT_ENABLED}" == "false" ]]; then
    start_health_server
else
    fail "HTTP_FRONT_ENABLED must be true or false"
fi

cd "${WORK_DIR}"
"${APP_BIN}" &
app_pid=$!

if [[ -n "${front_pid}" ]]; then
    set +e
    wait -n "${app_pid}" "${front_pid}"
    status=$?
    set -e
elif [[ -n "${health_pid}" ]]; then
    set +e
    wait -n "${app_pid}" "${health_pid}"
    status=$?
    set -e
else
    set +e
    wait "${app_pid}"
    status=$?
    set -e
fi

terminate
exit "${status}"
