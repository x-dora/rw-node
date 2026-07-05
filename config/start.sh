#!/bin/bash

set -euo pipefail

#######################################
# RW-Node 启动脚本 (Go-only bare-metal)
#######################################

WORK_DIR="${RW_NODE_DIR:-/opt/rw-node}"
APP_BIN="${WORK_DIR}/bin/rw-node-go"
CADDY_BIN="${CADDY_BIN:-${WORK_DIR}/bin/caddy}"
CADDY_CONF_DIR="${WORK_DIR}/conf/caddy"
CADDY_SITE_DIR="${CADDY_SITE_DIR:-${WORK_DIR}/www}"
CADDY_DEFAULT_SITE_DIR="${CADDY_DEFAULT_SITE_DIR:-${WORK_DIR}/default-www}"
RW_NODE_LIB_DIR="${RW_NODE_LIB_DIR:-${WORK_DIR}/lib}"
XRAY_LOCATION_ASSET="${XRAY_LOCATION_ASSET:-${WORK_DIR}/share/xray}"
LOG_PREFIX="[rw-node]"

# shellcheck source=../lib/core.sh
source "${RW_NODE_LIB_DIR}/core.sh"
# shellcheck source=../lib/caddy.sh
source "${RW_NODE_LIB_DIR}/caddy.sh"

# ── 目录初始化 ─────────────────────────────────────────────
mkdir -p "${WORK_DIR}/bin" "${WORK_DIR}/logs" "${WORK_DIR}/run" \
         "${WORK_DIR}/conf" "${WORK_DIR}/share/xray" "${CADDY_CONF_DIR}"

# ── 清理上一次运行遗留的运行时文件 ──────────────────────────
rm -f "${WORK_DIR}/run"/*.sock "${WORK_DIR}/run"/*.pid \
      /tmp/caddy-admin.sock

# ── 加载环境变量 ───────────────────────────────────────────
load_env_file "${WORK_DIR}/.env"

# ── 设置默认值 ─────────────────────────────────────────────
# 裸金属环境默认不启用 Caddy HTTP 前置（与 Docker 默认 true 不同）
HTTP_FRONT_ENABLED="${HTTP_FRONT_ENABLED:-false}"
RW_NODE_DIR="${WORK_DIR}"
set_default_env

# ── 参数校验 ───────────────────────────────────────────────
if [[ -z "${SECRET_KEY:-}" ]]; then
    fail "SECRET_KEY is required"
fi

if [[ ! -x "${APP_BIN}" ]]; then
    fail "rw-node-go binary not found: ${APP_BIN}"
fi

if ! is_port "${NODE_PORT}"; then
    fail "NODE_PORT must be a valid TCP port"
fi

if [[ ! -f "${XRAY_LOCATION_ASSET}/geoip.dat" || ! -f "${XRAY_LOCATION_ASSET}/geosite.dat" ]]; then
    log "WARNING: geoip.dat/geosite.dat missing in ${XRAY_LOCATION_ASSET}"
    log "Xray routing rules referencing geoip:*/geosite:* will fail to load."
    log "Re-run install.sh or place the files manually."
fi

# ── 进程管理 ───────────────────────────────────────────────
app_pid=""
caddy_pid=""
watcher_pid=""

terminate() {
    trap - INT TERM
    local _pid
    for _pid in watcher_pid app_pid caddy_pid; do
        kill_if_running "${_pid}"
    done
    wait 2>/dev/null || true
    rm -f "${WORK_DIR}/run/rw-node.pid"
}

trap terminate INT TERM

# ── 启动信息 ───────────────────────────────────────────────
log "Starting rw-node-go..."
log "Work directory: ${WORK_DIR}"
log "NODE_PORT: ${NODE_PORT}"
log "NODE_TLS_CLIENT_AUTH: ${NODE_TLS_CLIENT_AUTH}"
log "INTERNAL_REST_PORT: ${INTERNAL_REST_PORT}"
log "XRAY_LOCATION_ASSET: ${XRAY_LOCATION_ASSET}"
log "HTTP_FRONT_ENABLED: ${HTTP_FRONT_ENABLED}"

# ── 写入 PID 文件 ─────────────────────────────────────────
echo "$$" > "${WORK_DIR}/run/rw-node.pid"

# ── 启动 Caddy HTTP 前置（可选）─────────────────────────────
if [[ "${HTTP_FRONT_ENABLED}" == "true" ]]; then
    start_caddy_front
elif [[ "${HTTP_FRONT_ENABLED}" != "false" ]]; then
    fail "HTTP_FRONT_ENABLED must be true or false"
fi

# ── 启动 rw-node-go ───────────────────────────────────────
cd "${WORK_DIR}"
"${APP_BIN}" &
app_pid=$!

# ── 启动 Inbound 动态分流 watcher（可选）─────────────────────
if [[ "${HTTP_FRONT_ENABLED}" == "true" && "${INBOUND_WATCHER_ENABLED}" == "true" ]]; then
    start_inbound_watcher "${CADDY_CONF_DIR}/Caddyfile" &
    watcher_pid=$!
fi

# ── 等待子进程 ─────────────────────────────────────────────
if [[ -n "${caddy_pid}" ]]; then
    set +e
    wait -n "${app_pid}" "${caddy_pid}"
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
