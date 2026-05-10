#!/bin/bash

set -euo pipefail

FRP_VERSION="${FRP_VERSION:-latest}"
BIND_PORT="${BIND_PORT:-7000}"
ALLOW_PORT_START="${ALLOW_PORT_START:-22000}"
ALLOW_PORT_END="${ALLOW_PORT_END:-22999}"
FRP_TOKEN="${FRP_TOKEN:-}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/frp}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/frps.toml}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/frps.service}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_step() {
    echo -e "${YELLOW}==>${NC} $*"
}

print_success() {
    echo -e "${GREEN}OK:${NC} $*"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $*" >&2
}

usage() {
    cat << EOF
Usage: $0 --token <token> [options]

Options:
  --token <token>              frps auth token (required)
  --version <version>          frp version, for example 0.68.1 (default: latest)
  --bind-port <port>           frps bind port for frpc clients (default: 7000)
  --allow-port-start <port>    first public node port (default: 22000)
  --allow-port-end <port>      last public node port (default: 22999)
  --install-dir <path>         directory for frps binary (default: /usr/local/bin)
  --config-dir <path>          frp config directory (default: /etc/frp)
  -h, --help                   show this help

Environment variables with the same names are also supported:
  FRP_TOKEN, FRP_VERSION, BIND_PORT, ALLOW_PORT_START, ALLOW_PORT_END

Notes:
  frpc can use FRP_TRANSPORT_PROTOCOL=websocket or wss against this same
  bind port. The frp websocket path is fixed to /~!frp. For CDN/WSS usage,
  expose frps directly on 443 or put Nginx/Caddy in front and proxy /~!frp
  to this bind port.
EOF
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

need_arg() {
    local option="$1"
    local value="${2:-}"

    if [[ -z "${value}" || "${value}" == --* ]]; then
        print_error "${option} requires a value"
        exit 1
    fi
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        print_error "Please run as root"
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            print_error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac
}

resolve_latest_version() {
    local tag

    tag=$(curl -fsSL https://api.github.com/repos/fatedier/frp/releases/latest | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
    if [[ -z "${tag}" ]]; then
        print_error "Failed to resolve latest frp version"
        exit 1
    fi

    echo "${tag}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token)
                need_arg "$1" "${2:-}"
                FRP_TOKEN="$2"
                shift 2
                ;;
            --version)
                need_arg "$1" "${2:-}"
                FRP_VERSION="$2"
                shift 2
                ;;
            --bind-port)
                need_arg "$1" "${2:-}"
                BIND_PORT="$2"
                shift 2
                ;;
            --allow-port-start)
                need_arg "$1" "${2:-}"
                ALLOW_PORT_START="$2"
                shift 2
                ;;
            --allow-port-end)
                need_arg "$1" "${2:-}"
                ALLOW_PORT_END="$2"
                shift 2
                ;;
            --install-dir)
                need_arg "$1" "${2:-}"
                INSTALL_DIR="$2"
                shift 2
                ;;
            --config-dir)
                need_arg "$1" "${2:-}"
                CONFIG_DIR="$2"
                CONFIG_FILE="${CONFIG_DIR}/frps.toml"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

validate_config() {
    if [[ -z "${FRP_TOKEN}" ]]; then
        print_error "--token or FRP_TOKEN is required"
        exit 1
    fi

    if ! is_port "${BIND_PORT}"; then
        print_error "Invalid bind port: ${BIND_PORT}"
        exit 1
    fi

    if ! is_port "${ALLOW_PORT_START}" || ! is_port "${ALLOW_PORT_END}"; then
        print_error "Invalid allow port range: ${ALLOW_PORT_START}-${ALLOW_PORT_END}"
        exit 1
    fi

    if (( ALLOW_PORT_START > ALLOW_PORT_END )); then
        print_error "ALLOW_PORT_START must be less than or equal to ALLOW_PORT_END"
        exit 1
    fi
}

install_frps() {
    local arch version url tmp_dir archive extracted

    arch=$(detect_arch)
    version="${FRP_VERSION}"
    if [[ "${version}" == "latest" ]]; then
        version=$(resolve_latest_version)
    fi
    version="${version#v}"

    url="https://github.com/fatedier/frp/releases/download/v${version}/frp_${version}_linux_${arch}.tar.gz"
    tmp_dir=$(mktemp -d)
    archive="${tmp_dir}/frp.tar.gz"
    extracted="${tmp_dir}/frp_${version}_linux_${arch}"

    print_step "Downloading frp v${version} for linux/${arch}"
    curl -fsSL -o "${archive}" "${url}"
    tar -xzf "${archive}" -C "${tmp_dir}"

    install -m 755 "${extracted}/frps" "${INSTALL_DIR}/frps"
    rm -rf "${tmp_dir}"

    print_success "Installed ${INSTALL_DIR}/frps"
}

write_config() {
    print_step "Writing ${CONFIG_FILE}"

    mkdir -p "${CONFIG_DIR}"
cat > "${CONFIG_FILE}" << EOF
bindPort = ${BIND_PORT}
auth.token = "$(toml_escape "${FRP_TOKEN}")"

allowPorts = [
  { start = ${ALLOW_PORT_START}, end = ${ALLOW_PORT_END} }
]
EOF
    chmod 600 "${CONFIG_FILE}"

    "${INSTALL_DIR}/frps" verify -c "${CONFIG_FILE}"
    print_success "frps config verified"
}

write_service() {
    print_step "Writing ${SERVICE_FILE}"

    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=frp server for RW-Node PaaS TCP tunnels
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/frps -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

StandardOutput=journal
StandardError=journal
SyslogIdentifier=frps

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now frps
    print_success "frps service started"
}

main() {
    parse_args "$@"
    require_root
    validate_config
    install_frps
    write_config
    write_service

    echo
    print_success "frps is ready"
    echo "Control port: ${BIND_PORT}/tcp"
    echo "Node port range: ${ALLOW_PORT_START}-${ALLOW_PORT_END}/tcp"
    echo "Open these ports in your VPS firewall/security group."
    echo "For WSS/CDN mode, proxy wss://<frps-domain>/~!frp to the control port."
}

main "$@"
