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
RW_NODE_ENTRYPOINT="/usr/local/bin/docker-entrypoint.sh"

FRP_ENABLED="${FRP_ENABLED:-true}"
NODE_PORT="${NODE_PORT:-2222}"
FRP_SERVER_PORT="${FRP_SERVER_PORT:-7000}"
FRP_LOCAL_IP="${FRP_LOCAL_IP:-127.0.0.1}"
FRP_LOCAL_PORT="${FRP_LOCAL_PORT:-${NODE_PORT}}"
FRP_PROXY_NAME_PREFIX="${FRP_PROXY_NAME_PREFIX:-rw-node}"
FRP_WAIT_FOR_NODE="${FRP_WAIT_FOR_NODE:-true}"
HTTP_FRONT_ENABLED="${HTTP_FRONT_ENABLED:-true}"
HTTP_FRONT_PORT="${HTTP_FRONT_PORT:-${PORT:-3000}}"
XHTTP_UPSTREAM_PORT="${XHTTP_UPSTREAM_PORT:-8080}"
WS_UPSTREAM_PORT="${WS_UPSTREAM_PORT:-8880}"

app_pid=""
frpc_pid=""
health_pid=""
haproxy_pid=""

is_port() {
    local value="$1"

    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    (( value >= 1 && value <= 65535 ))
}

toml_escape() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/}"
    value="${value//$'\r'/}"
    printf '%s' "$value"
}

require_env() {
    local name="$1"

    if [[ -z "${!name:-}" ]]; then
        echo "[PaaS FRP] ERROR: ${name} is required"
        exit 1
    fi
}

random_suffix() {
    local length="${1:-8}"
    local value

    set +o pipefail
    value=$(tr -dc 'a-z0-9' < /dev/urandom | head -c "${length}")
    set -o pipefail
    printf '%s' "${value}"
}

wait_for_rw_node() {
    local i

    for i in $(seq 1 30); do
        if timeout 2 bash -c "</dev/tcp/127.0.0.1/${NODE_PORT}" >/dev/null 2>&1; then
            return 0
        fi

        if [[ -n "${app_pid}" ]] && ! kill -0 "${app_pid}" 2>/dev/null; then
            return 1
        fi

        sleep 1
    done

    return 1
}

wait_for_port() {
    local port="$1"
    local pid="$2"
    local i

    for i in $(seq 1 10); do
        if timeout 2 bash -c "</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1; then
            return 0
        fi

        if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
            return 1
        fi

        sleep 1
    done

    return 1
}

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

start_haproxy_front() {
    local config_path="${HAPROXY_CONF_DIR}/haproxy.cfg"

    if ! is_port "${HTTP_FRONT_PORT}"; then
        echo "[PaaS FRP] ERROR: HTTP_FRONT_PORT must be a valid TCP port"
        exit 1
    fi

    if [[ "${HTTP_FRONT_PORT}" == "${NODE_PORT}" ]]; then
        echo "[PaaS FRP] ERROR: HTTP_FRONT_PORT must differ from NODE_PORT"
        exit 1
    fi

    if ! is_port "${XHTTP_UPSTREAM_PORT}"; then
        echo "[PaaS FRP] ERROR: XHTTP_UPSTREAM_PORT must be a valid TCP port"
        exit 1
    fi

    if ! is_port "${WS_UPSTREAM_PORT}"; then
        echo "[PaaS FRP] ERROR: WS_UPSTREAM_PORT must be a valid TCP port"
        exit 1
    fi

    if [[ ! -x "${HAPROXY_BIN}" ]]; then
        echo "[PaaS FRP] ERROR: haproxy binary not found"
        exit 1
    fi

    mkdir -p "${HAPROXY_CONF_DIR}"

    cat > "${config_path}" << EOF
global
    maxconn 1024
    nbthread 1
    log stdout format raw local0 warning

defaults
    mode http
    log global
    option dontlognull
    timeout connect 5s
    timeout client 1h
    timeout server 1h
    timeout tunnel 1h

frontend http_front
    bind *:${HTTP_FRONT_PORT}
    acl is_health path -i /health
    acl is_xh path_beg -i /xh-
    acl is_ws path_beg -i /ws-

    http-request return status 200 content-type text/plain string "ok\n" if is_health
    use_backend xhttp_backend if is_xh
    use_backend ws_backend if is_ws
    http-request return status 404

backend xhttp_backend
    server xhttp 127.0.0.1:${XHTTP_UPSTREAM_PORT} proto h2

backend ws_backend
    option http-server-close
    timeout tunnel 1h
    server ws 127.0.0.1:${WS_UPSTREAM_PORT}
EOF

    "${HAPROXY_BIN}" -c -f "${config_path}"

    echo "[PaaS FRP] Starting HAProxy HTTP front on port ${HTTP_FRONT_PORT}"
    "${HAPROXY_BIN}" -W -db -f "${config_path}" &
    haproxy_pid=$!

    if ! wait_for_port "${HTTP_FRONT_PORT}" "${haproxy_pid}"; then
        echo "[PaaS FRP] ERROR: HAProxy did not accept TCP connections on 127.0.0.1:${HTTP_FRONT_PORT}"
        terminate
        exit 1
    fi
}

generate_frpc_config() {
    local config_path="${FRP_CONF_DIR}/frpc.toml"

    require_env FRP_SERVER_ADDR
    require_env FRP_TOKEN
    require_env FRP_REMOTE_PORT

    if [[ -z "${FRP_PROXY_NAME:-}" ]]; then
        FRP_PROXY_NAME="${FRP_PROXY_NAME_PREFIX}-$(random_suffix 8)"
        export FRP_PROXY_NAME
        echo "[PaaS FRP] FRP_PROXY_NAME not set; generated ${FRP_PROXY_NAME}"
    fi

    if ! is_port "${FRP_SERVER_PORT}"; then
        echo "[PaaS FRP] ERROR: FRP_SERVER_PORT must be a valid TCP port"
        exit 1
    fi

    if ! is_port "${FRP_LOCAL_PORT}"; then
        echo "[PaaS FRP] ERROR: FRP_LOCAL_PORT must be a valid TCP port"
        exit 1
    fi

    if ! is_port "${FRP_REMOTE_PORT}"; then
        echo "[PaaS FRP] ERROR: FRP_REMOTE_PORT must be a valid TCP port"
        exit 1
    fi

    if [[ ! "${FRP_PROXY_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "[PaaS FRP] ERROR: FRP_PROXY_NAME may only contain letters, numbers, dots, underscores, and dashes"
        exit 1
    fi

    mkdir -p "${FRP_CONF_DIR}"

    cat > "${config_path}" << EOF
serverAddr = "$(toml_escape "${FRP_SERVER_ADDR}")"
serverPort = ${FRP_SERVER_PORT}
auth.token = "$(toml_escape "${FRP_TOKEN}")"

[[proxies]]
name = "$(toml_escape "${FRP_PROXY_NAME}")"
type = "tcp"
localIP = "$(toml_escape "${FRP_LOCAL_IP}")"
localPort = ${FRP_LOCAL_PORT}
remotePort = ${FRP_REMOTE_PORT}
EOF

    chmod 600 "${config_path}"
    "${FRPC_BIN}" verify -c "${config_path}"
    echo "[PaaS FRP] frpc config generated at ${config_path}"
}

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
