#!/bin/bash

set -euo pipefail

APP_BIN="/usr/local/bin/rw-node-go"
WORK_DIR="${RW_NODE_DIR:-/opt/rw-node-go}"
CONF_DIR="${WORK_DIR}/conf"
FRP_CONF_DIR="${CONF_DIR}/frp"
HAPROXY_CONF_DIR="${CONF_DIR}/haproxy"
FRPC_BIN="/usr/local/bin/frpc"
HAPROXY_BIN="${HAPROXY_BIN:-$(command -v haproxy 2>/dev/null || true)}"
HAPROXY_FRONT_LIB="/usr/local/bin/paas-haproxy-front.sh"
FRP_CLIENT_LIB="/usr/local/bin/paas-frp-client.sh"
HAPROXY_LOG_PREFIX="[Go PaaS FRP]"
FRP_LOG_PREFIX="[Go PaaS FRP]"

NODE_PORT="${NODE_PORT:-2222}"
FRP_DEFAULT_PROXY_NAME_PREFIX="rw-node-go"
HTTP_FRONT_ENABLED="${HTTP_FRONT_ENABLED:-true}"
HTTP_FRONT_PORT="${HTTP_FRONT_PORT:-${PORT:-3000}}"
XHTTP_UPSTREAM_PORT="${XHTTP_UPSTREAM_PORT:-8080}"
WS_UPSTREAM_PORT="${WS_UPSTREAM_PORT:-8880}"

source "${FRP_CLIENT_LIB}"

app_pid=""
frpc_pid=""
health_pid=""
haproxy_pid=""

terminate() {
    trap - INT TERM

    if [[ -n "${frpc_pid}" ]] && kill -0 "${frpc_pid}" 2>/dev/null; then
        kill "${frpc_pid}" 2>/dev/null || true
    fi

    if [[ -n "${app_pid}" ]] && kill -0 "${app_pid}" 2>/dev/null; then
        kill "${app_pid}" 2>/dev/null || true
    fi

    if [[ -n "${health_pid}" ]] && kill -0 "${health_pid}" 2>/dev/null; then
        kill "${health_pid}" 2>/dev/null || true
    fi

    if [[ -n "${haproxy_pid}" ]] && kill -0 "${haproxy_pid}" 2>/dev/null; then
        kill "${haproxy_pid}" 2>/dev/null || true
    fi

    wait 2>/dev/null || true
}

start_health_server() {
    if [[ -z "${PORT:-}" ]]; then
        return 0
    fi

    if ! is_port "${PORT}"; then
        echo "[Go PaaS FRP] ERROR: PORT must be a valid TCP port"
        exit 1
    fi

    if [[ "${PORT}" == "${NODE_PORT}" ]]; then
        echo "[Go PaaS FRP] PORT equals NODE_PORT; skipping auxiliary HTTP health server"
        return 0
    fi

    echo "[Go PaaS FRP] Starting auxiliary HTTP health server on port ${PORT}"
    printf 'ok\n' > /tmp/index.html
    busybox httpd -f -p "0.0.0.0:${PORT}" -h /tmp &
    health_pid=$!
}

source "${HAPROXY_FRONT_LIB}"

trap terminate INT TERM

if ! is_port "${NODE_PORT}"; then
    echo "[Go PaaS FRP] ERROR: NODE_PORT must be a valid TCP port"
    exit 1
fi

if [[ ! -x "${APP_BIN}" ]]; then
    echo "[Go PaaS FRP] ERROR: rw-node-go binary not found"
    exit 1
fi

mkdir -p "${WORK_DIR}"
if [[ "${HTTP_FRONT_ENABLED}" == "true" ]]; then
    start_haproxy_front
elif [[ "${HTTP_FRONT_ENABLED}" == "false" ]]; then
    start_health_server
else
    echo "[Go PaaS FRP] ERROR: HTTP_FRONT_ENABLED must be true or false"
    exit 1
fi

cd "${WORK_DIR}"
"${APP_BIN}" &
app_pid=$!

if [[ "${FRP_ENABLED}" == "true" ]]; then
    if [[ ! -x "${FRPC_BIN}" ]]; then
        echo "[Go PaaS FRP] ERROR: frpc binary not found"
        terminate
        exit 1
    fi

    generate_frpc_config

    if [[ "${FRP_WAIT_FOR_NODE}" == "true" ]]; then
        if ! wait_for_rw_node; then
            echo "[Go PaaS FRP] ERROR: rw-node-go did not accept TCP connections on 127.0.0.1:${NODE_PORT}"
            terminate
            exit 1
        fi
    elif [[ "${FRP_WAIT_FOR_NODE}" == "false" ]]; then
        echo "[Go PaaS FRP] Skipping rw-node-go TCP readiness check"
    else
        echo "[Go PaaS FRP] ERROR: FRP_WAIT_FOR_NODE must be true or false"
        terminate
        exit 1
    fi

    "${FRPC_BIN}" -c "${FRP_CONF_DIR}/frpc.toml" &
    frpc_pid=$!
    echo "[Go PaaS FRP] frpc started"
elif [[ "${FRP_ENABLED}" == "false" ]]; then
    echo "[Go PaaS FRP] FRP is disabled"
else
    echo "[Go PaaS FRP] ERROR: FRP_ENABLED must be true or false"
    terminate
    exit 1
fi

if [[ -n "${frpc_pid}" && -n "${haproxy_pid}" ]]; then
    set +e
    wait -n "${app_pid}" "${frpc_pid}" "${haproxy_pid}"
    status=$?
    set -e
elif [[ -n "${frpc_pid}" ]]; then
    set +e
    wait -n "${app_pid}" "${frpc_pid}"
    status=$?
    set -e
elif [[ -n "${haproxy_pid}" ]]; then
    set +e
    wait -n "${app_pid}" "${haproxy_pid}"
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
