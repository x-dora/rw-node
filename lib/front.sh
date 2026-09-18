#!/usr/bin/env bash
# shellcheck shell=bash
#
# frontproxy 的启动。它取代了原先的 Caddy + inbound watcher：
# 在一个对外端口上按连接首字节分流 SSH / TLS / 明文 HTTP，并在连接内部
# 轮询 rw-node-go 的 /internal/get-config 自行维护路由表。
[[ -n "${_RW_NODE_FRONT_LOADED:-}" ]] && return 0
_RW_NODE_FRONT_LOADED=1

_FRONT_LIB_DIR="${_FRONT_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
# shellcheck source=core.sh
[[ -n "${_RW_NODE_CORE_LOADED:-}" ]] || source "${_FRONT_LIB_DIR}/core.sh"
# shellcheck source=site.sh
[[ -n "${_RW_NODE_SITE_LOADED:-}" ]] || source "${_FRONT_LIB_DIR}/site.sh"

resolve_front_bin() {
    if [[ -n "${FRONT_BIN:-}" ]]; then
        printf '%s' "${FRONT_BIN}"
        return 0
    fi
    command -v rw-node-front 2>/dev/null || true
}

# frontproxy 是独立进程，只能看到 export 过的变量。这里显式列出它需要的，
# 而不是 export 全部——避免把无关的敏感值（比如 ARGO_TOKEN）扩散出去。
export_front_env() {
    export HTTP_FRONT_PORT HTTP_FRONT_HOST NODE_PORT INTERNAL_REST_PORT
    export XHTTP_UPSTREAM_PORT WS_UPSTREAM_PORT
    export SSH_ENABLED SSH_PORT
    export FRONT_SITE_DIR SITE_BUILD_DIR
    export INBOUND_WATCHER_ENABLED INBOUND_WATCHER_INTERVAL
    export SECRET_KEY
}

start_front_proxy() {
    validate_ports

    local front_bin
    front_bin="$(resolve_front_bin)"
    if [[ -z "${front_bin}" || ! -x "${front_bin}" ]]; then
        fail "front proxy binary not found: ${FRONT_BIN:-<not set>}"
    fi

    setup_static_site || fail "static camouflage page setup failed"

    export_front_env

    log "Starting front proxy on port ${HTTP_FRONT_PORT} (SSH/TLS/HTTP multiplexing)"
    "${front_bin}" &
    front_pid=$!

    if [[ -z "${FRONT_SKIP_PORT_WAIT:-}" ]]; then
        if ! wait_for_health "${HTTP_FRONT_PORT}" "${front_pid}"; then
            log "ERROR: front proxy health endpoint not responding on 127.0.0.1:${HTTP_FRONT_PORT}/health"
            return 1
        fi
    fi
}
