#!/bin/bash

set -euo pipefail

APP_DIR="${RW_NODE_APP_DIR:-/opt/rw-node}"
WORK_DIR="${RW_NODE_DIR:-${APP_DIR}}"

if [[ ! -f "${WORK_DIR}/dist/src/main" && ! -f "${WORK_DIR}/dist/src/main.js" && -f "${APP_DIR}/dist/src/main.js" ]]; then
    echo "[PaaS FRP] RW_NODE_DIR=${WORK_DIR} does not contain application files; using RW_NODE_APP_DIR=${APP_DIR}"
    WORK_DIR="${APP_DIR}"
    export RW_NODE_DIR="${WORK_DIR}"
fi

CONF_DIR="${WORK_DIR}/conf"
FRP_CONF_DIR="${CONF_DIR}/frp"
HAPROXY_CONF_DIR="${CONF_DIR}/haproxy"
FRPC_BIN="/usr/local/bin/frpc"
HAPROXY_BIN="${HAPROXY_BIN:-$(command -v haproxy 2>/dev/null || true)}"
HAPROXY_FRONT_LIB="/usr/local/bin/paas-haproxy-front.sh"
FRP_CLIENT_LIB="/usr/local/bin/paas-frp-client.sh"
HAPROXY_LOG_PREFIX="[PaaS FRP]"
FRP_LOG_PREFIX="[PaaS FRP]"
RW_NODE_ENTRYPOINT="/usr/local/bin/docker-entrypoint.sh"

NODE_PORT="${NODE_PORT:-2222}"
FRP_DEFAULT_PROXY_NAME_PREFIX="rw-node"
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
        echo "[PaaS FRP] ERROR: PORT must be a valid TCP port"
        exit 1
    fi

    if [[ "${PORT}" == "${NODE_PORT}" ]]; then
        echo "[PaaS FRP] PORT equals NODE_PORT; skipping auxiliary HTTP health server"
        return 0
    fi

    echo "[PaaS FRP] Starting auxiliary HTTP health server on port ${PORT}"
    node -e '
const http = require("http");
const port = Number(process.env.PORT);
http.createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/plain" });
  res.end("ok\n");
}).listen(port, "0.0.0.0");
' &
    health_pid=$!
}

source "${HAPROXY_FRONT_LIB}"

trap terminate INT TERM

if ! is_port "${NODE_PORT}"; then
    echo "[PaaS FRP] ERROR: NODE_PORT must be a valid TCP port"
    exit 1
fi

if [[ "${HTTP_FRONT_ENABLED}" == "true" ]]; then
    start_haproxy_front
elif [[ "${HTTP_FRONT_ENABLED}" == "false" ]]; then
    start_health_server
else
    echo "[PaaS FRP] ERROR: HTTP_FRONT_ENABLED must be true or false"
    exit 1
fi

"${RW_NODE_ENTRYPOINT}" "$@" &
app_pid=$!

if [[ "${FRP_ENABLED}" == "true" ]]; then
    if [[ ! -x "${FRPC_BIN}" ]]; then
        echo "[PaaS FRP] ERROR: frpc binary not found"
        terminate
        exit 1
    fi

    generate_frpc_config

    if [[ "${FRP_WAIT_FOR_NODE}" == "true" ]]; then
        if ! wait_for_rw_node; then
            echo "[PaaS FRP] ERROR: rw-node did not accept TCP connections on 127.0.0.1:${NODE_PORT}"
            terminate
            exit 1
        fi
    elif [[ "${FRP_WAIT_FOR_NODE}" == "false" ]]; then
        echo "[PaaS FRP] Skipping rw-node TCP readiness check"
    else
        echo "[PaaS FRP] ERROR: FRP_WAIT_FOR_NODE must be true or false"
        terminate
        exit 1
    fi

    "${FRPC_BIN}" -c "${FRP_CONF_DIR}/frpc.toml" &
    frpc_pid=$!
    echo "[PaaS FRP] frpc started"
elif [[ "${FRP_ENABLED}" == "false" ]]; then
    echo "[PaaS FRP] FRP is disabled"
else
    echo "[PaaS FRP] ERROR: FRP_ENABLED must be true or false"
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
