#!/usr/bin/env bash
# shellcheck shell=bash
#
# sshd-lite 的启动与降级。
#
# SSH 入口复用 frontproxy 的对外端口：frontproxy 按首字节 "SSH-" 把连接转发
# 到这里的 sshd-lite。本文件只负责把 sshd-lite 拉起来，以及在条件不满足时
# 干净地把 SSH_ENABLED 关掉。
[[ -n "${_RW_NODE_SSH_LOADED:-}" ]] && return 0
_RW_NODE_SSH_LOADED=1

_SSH_LIB_DIR="${_SSH_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
# shellcheck source=core.sh
[[ -n "${_RW_NODE_CORE_LOADED:-}" ]] || source "${_SSH_LIB_DIR}/core.sh"

# SSH 入口要求同时具备公钥（否则无人能登录），任一缺失都退回关闭状态，
# 避免在对外端口上留一条永远连不通的 SSH 路由。
ssh_entry_enabled() {
    [[ "${SSH_ENABLED:-false}" == "true" ]] || return 1
    [[ -n "${SSH_AUTHORIZED_KEYS:-}" ]] || return 1
    return 0
}

disable_ssh_entry() {
    log "WARN: $1; SSH entry stays disabled"
    SSH_ENABLED=false
    export SSH_ENABLED
}

resolve_sshd_lite_bin() {
    if [[ -n "${SSHD_LITE_BIN:-}" ]]; then
        printf '%s' "${SSHD_LITE_BIN}"
        return 0
    fi
    command -v sshd-lite 2>/dev/null || true
}

start_ssh_service() {
    if [[ "${SSH_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    # 以下每条降级路径都同时关闭 SSH_ENABLED：frontproxy 会继承这个变量，
    # 从而不会在对外端口上留下连不通的 SSH 路由。
    if [[ -z "${SSH_AUTHORIZED_KEYS:-}" ]]; then
        disable_ssh_entry "SSH_ENABLED is true but SSH_AUTHORIZED_KEYS is empty"
        return 0
    fi

    local sshd_bin
    sshd_bin="$(resolve_sshd_lite_bin)"
    if [[ -z "${sshd_bin}" || ! -x "${sshd_bin}" ]]; then
        disable_ssh_entry "sshd-lite not found"
        return 0
    fi

    local ssh_dir host_key
    ssh_dir="${SSH_DIR:-${WORK_DIR:-.}/ssh}"
    host_key="${ssh_dir}/host_key"
    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"

    # 容器无持久卷时 host key 每次重建都会变，客户端会报 host key 已更改；
    # SSH_HOST_KEY 给出私钥内容即可固定下来。
    if [[ ! -s "${host_key}" && -n "${SSH_HOST_KEY:-}" ]]; then
        printf '%s\n' "${SSH_HOST_KEY}" > "${host_key}"
        chmod 600 "${host_key}"
    fi

    log "Starting SSH service on 127.0.0.1:${SSH_PORT}"
    SSH_LISTEN="127.0.0.1:${SSH_PORT}" \
    SSH_AUTHORIZED_KEYS="${SSH_AUTHORIZED_KEYS}" \
    SSH_HOST_KEY_FILE="${host_key}" \
        "${sshd_bin}" &
    ssh_service_pid=$!

    sleep 0.3
    if ! kill -0 "${ssh_service_pid}" 2>/dev/null; then
        ssh_service_pid=""
        disable_ssh_entry "SSH service failed to start on 127.0.0.1:${SSH_PORT}"
        return 0
    fi

    log "SSH entry ready: port ${HTTP_FRONT_PORT} serves SSH, HTTP and TLS"
    log "SSH login: ssh -p ${HTTP_FRONT_PORT} <any-user>@<host> (sshd-lite ignores the username)"
}
