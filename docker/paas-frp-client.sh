paas_log() {
    local log_prefix="${FRP_LOG_PREFIX:-[PaaS FRP]}"

    echo "${log_prefix} $*"
}

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
        paas_log "ERROR: ${name} is required"
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

        if [[ -n "${app_pid:-}" ]] && ! kill -0 "${app_pid}" 2>/dev/null; then
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

FRP_ENABLED="${FRP_ENABLED:-true}"
FRP_SERVER_PORT="${FRP_SERVER_PORT:-7000}"
FRP_TRANSPORT_PROTOCOL="${FRP_TRANSPORT_PROTOCOL:-tcp}"
FRP_LOCAL_IP="${FRP_LOCAL_IP:-127.0.0.1}"
FRP_LOCAL_PORT="${FRP_LOCAL_PORT:-${NODE_PORT}}"
FRP_PROXY_NAME_PREFIX="${FRP_PROXY_NAME_PREFIX:-${FRP_DEFAULT_PROXY_NAME_PREFIX:-rw-node}}"
FRP_WAIT_FOR_NODE="${FRP_WAIT_FOR_NODE:-true}"

validate_frp_transport() {
    case "${FRP_TRANSPORT_PROTOCOL}" in
        tcp|websocket|wss)
            ;;
        *)
            paas_log "ERROR: FRP_TRANSPORT_PROTOCOL must be tcp, websocket, or wss"
            exit 1
            ;;
    esac
}

write_optional_frpc_tls_config() {
    local tls_server_name="${FRP_TLS_SERVER_NAME:-}"

    if [[ -z "${tls_server_name}" && "${FRP_TRANSPORT_PROTOCOL}" == "wss" ]]; then
        tls_server_name="${FRP_SERVER_ADDR}"
    fi

    if [[ -n "${tls_server_name}" ]]; then
        printf 'transport.tls.serverName = "%s"\n' "$(toml_escape "${tls_server_name}")"
    fi

    if [[ -n "${FRP_TLS_TRUSTED_CA_FILE:-}" ]]; then
        printf 'transport.tls.trustedCaFile = "%s"\n' "$(toml_escape "${FRP_TLS_TRUSTED_CA_FILE}")"
    fi
}

generate_frpc_config() {
    local config_path="${FRP_CONF_DIR}/frpc.toml"

    require_env FRP_SERVER_ADDR
    require_env FRP_TOKEN
    require_env FRP_REMOTE_PORT
    validate_frp_transport

    if [[ -z "${FRP_PROXY_NAME:-}" ]]; then
        FRP_PROXY_NAME="${FRP_PROXY_NAME_PREFIX}-$(random_suffix 8)"
        export FRP_PROXY_NAME
        paas_log "FRP_PROXY_NAME not set; generated ${FRP_PROXY_NAME}"
    fi

    if ! is_port "${FRP_SERVER_PORT}"; then
        paas_log "ERROR: FRP_SERVER_PORT must be a valid TCP port"
        exit 1
    fi

    if ! is_port "${FRP_LOCAL_PORT}"; then
        paas_log "ERROR: FRP_LOCAL_PORT must be a valid TCP port"
        exit 1
    fi

    if ! is_port "${FRP_REMOTE_PORT}"; then
        paas_log "ERROR: FRP_REMOTE_PORT must be a valid TCP port"
        exit 1
    fi

    if [[ ! "${FRP_PROXY_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        paas_log "ERROR: FRP_PROXY_NAME may only contain letters, numbers, dots, underscores, and dashes"
        exit 1
    fi

    mkdir -p "${FRP_CONF_DIR}"

    {
        cat << EOF
serverAddr = "$(toml_escape "${FRP_SERVER_ADDR}")"
serverPort = ${FRP_SERVER_PORT}
auth.token = "$(toml_escape "${FRP_TOKEN}")"
transport.protocol = "$(toml_escape "${FRP_TRANSPORT_PROTOCOL}")"
EOF
        write_optional_frpc_tls_config
        cat << EOF

[[proxies]]
name = "$(toml_escape "${FRP_PROXY_NAME}")"
type = "tcp"
localIP = "$(toml_escape "${FRP_LOCAL_IP}")"
localPort = ${FRP_LOCAL_PORT}
remotePort = ${FRP_REMOTE_PORT}
EOF
    } > "${config_path}"

    chmod 600 "${config_path}"
    "${FRPC_BIN}" verify -c "${config_path}"
    paas_log "frpc config generated at ${config_path}"
}
