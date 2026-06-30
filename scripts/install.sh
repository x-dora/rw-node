#!/bin/bash

set -euo pipefail

#######################################
# RW-Node 一键安装脚本 (Go 实现)
# 无需 Docker 的轻量化部署方案
# 仓库: https://github.com/x-dora/rw-node
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="${RW_NODE_DIR:-/opt/rw-node}"
GITHUB_REPO="x-dora/rw-node"

WITH_CLOUDFLARED=false
CLOUDFLARED_TOKEN=""
GO_VERSION=""
NODE_PORT="2222"
SECRET_KEY=""
INTERNAL_REST_PORT="61001"
NODE_TLS_CLIENT_AUTH="${NODE_TLS_CLIENT_AUTH:-mtls}"

IS_CONTAINER=false
HAS_SYSTEMD=false
OS="unknown"
OS_VERSION=""
PKG_MANAGER=""
APT_UPDATED=false

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${PURPLE}[STEP]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

detect_container() {
    print_step "检测运行环境..."

    if [[ -f /.dockerenv ]]; then
        IS_CONTAINER=true
        print_info "检测到 Docker 容器环境"
    elif [[ -f /run/.containerenv ]]; then
        IS_CONTAINER=true
        print_info "检测到 Podman 容器环境"
    elif grep -qE '(docker|lxc|kubepods|containerd)' /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER=true
        print_info "检测到容器环境 (cgroup)"
    elif [[ -n "${container:-}" ]]; then
        IS_CONTAINER=true
        print_info "检测到容器环境 (环境变量)"
    elif command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container >/dev/null 2>&1; then
        IS_CONTAINER=true
        print_info "检测到容器环境 (systemd-detect-virt)"
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        if [[ -d /run/systemd/system ]]; then
            HAS_SYSTEMD=true
            print_info "Systemd 可用"
        else
            print_info "Systemd 已安装但未运行"
        fi
    else
        print_info "Systemd 不可用"
    fi

    if [[ "$IS_CONTAINER" == "true" ]]; then
        print_warning "容器环境下将使用前台运行模式"
    elif [[ "$HAS_SYSTEMD" == "true" ]]; then
        print_info "将使用 Systemd 服务模式"
    else
        print_warning "无 Systemd，将使用前台运行模式"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        OS=$(. /etc/os-release && echo "$ID")
        OS_VERSION=$(. /etc/os-release && echo "$VERSION_ID")
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
    fi

    case "$OS" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|almalinux|rocky)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        fedora)
            PKG_MANAGER="dnf"
            ;;
        alpine)
            PKG_MANAGER="apk"
            ;;
        *)
            PKG_MANAGER=""
            ;;
    esac

    print_info "检测到操作系统: $OS ${OS_VERSION:-}"
}

update_package_index() {
    if [[ "$PKG_MANAGER" == "apt" && "$APT_UPDATED" != "true" ]]; then
        apt-get -o Acquire::Check-Valid-Until=false update -qq
        APT_UPDATED=true
    fi
}

install_packages() {
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            update_package_index
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
            ;;
        yum)
            yum install -y -q "${packages[@]}"
            ;;
        dnf)
            dnf install -y -q "${packages[@]}"
            ;;
        apk)
            apk add --no-cache "${packages[@]}"
            ;;
        *)
            print_error "不支持自动安装依赖，请手动安装: ${packages[*]}"
            exit 1
            ;;
    esac
}

check_dependencies() {
    local missing=()

    print_step "检查依赖..."

    if ! command -v bash >/dev/null 2>&1; then
        case "$PKG_MANAGER" in
            apt) missing+=("bash") ;;
            yum|dnf) missing+=("bash") ;;
            apk) missing+=("bash") ;;
        esac
    fi
    if ! command -v curl >/dev/null 2>&1; then
        missing+=("curl")
    fi
    if ! command -v jq >/dev/null 2>&1; then
        missing+=("jq")
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        missing+=("unzip")
    fi
    if ! command -v pgrep >/dev/null 2>&1; then
        case "$PKG_MANAGER" in
            apt) missing+=("procps") ;;
            yum|dnf) missing+=("procps-ng") ;;
            apk) missing+=("procps") ;;
        esac
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_info "安装依赖: ${missing[*]}"
        install_packages "${missing[@]}"
    fi

    print_success "依赖检查完成"
}

repo_raw_url() {
    local ref="$1"
    echo "https://raw.githubusercontent.com/${GITHUB_REPO}/${ref}"
}

download_repo_file() {
    local ref="$1"
    local source_path="$2"
    local destination="$3"
    local primary_url fallback_url

    primary_url="$(repo_raw_url "$ref")/${source_path}"
    if curl -fsSL "$primary_url" -o "$destination"; then
        return 0
    fi

    if [[ "$ref" != "main" ]]; then
        fallback_url="$(repo_raw_url "main")/${source_path}"
        print_warning "未找到 ${ref}/${source_path}，回退到 main"
        curl -fsSL "$fallback_url" -o "$destination"
        return 0
    fi

    print_error "下载失败: ${source_path}"
    return 1
}

download_lib_scripts() {
    local ref="$1"

    print_step "下载共享库脚本..."
    mkdir -p "${INSTALL_DIR}/lib"

    local lib_files=(core.sh caddy.sh provision.sh cloudflared.sh reality-watcher.js reality-watcher.py Caddyfile.template)
    for f in "${lib_files[@]}"; do
        download_repo_file "$ref" "lib/${f}" "${INSTALL_DIR}/lib/${f}"
    done

    print_success "共享库下载完成"
}

setup_provision_vars() {
    BIN_DIR="${INSTALL_DIR}/bin"
    APP_BIN="${BIN_DIR}/rw-node-go"
    ASSET_DIR="${INSTALL_DIR}/share/xray"
    VERSION_FILE="${INSTALL_DIR}/.rw-node-go-version"
    CADDY_BIN_DEFAULT="${BIN_DIR}/caddy"
    CLOUDFLARED_BIN_DEFAULT="${BIN_DIR}/cloudflared"
    CLOUDFLARED_VERSION_FILE="${INSTALL_DIR}/.cloudflared-version"
    mkdir -p "${BIN_DIR}" "${ASSET_DIR}" "${INSTALL_DIR}/logs" "${INSTALL_DIR}/run" "${INSTALL_DIR}/conf"
}

install_default_www() {
    local site_dir="${INSTALL_DIR}/default-www"
    mkdir -p "${site_dir}"

    if [[ -f "${site_dir}/index.html" ]]; then
        print_info "伪装页面已存在"
        return 0
    fi

    print_step "下载默认伪装页面..."

    local tmp_dir="/tmp/rw-node-install-www"
    mkdir -p "${tmp_dir}"
    rm -rf "${tmp_dir:?}/"*

    if curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
            "https://github.com/AYJCSGM/mikutap/archive/master.zip" \
            -o "${tmp_dir}/default-www.zip" \
        && unzip -q "${tmp_dir}/default-www.zip" -d "${tmp_dir}/extract" \
        && index_file="$(find "${tmp_dir}/extract" -mindepth 1 -maxdepth 4 -type f -iname index.html | sort | head -n 1)" \
        && [[ -n "${index_file}" ]]; then
        cp -a "$(dirname "${index_file}")/." "${site_dir}/"
        print_success "伪装页面下载完成"
    else
        printf '%s\n' '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head><body><main><h1>Welcome</h1><p>The service is running.</p></main></body></html>' > "${site_dir}/index.html"
        print_warning "使用默认 fallback 页面"
    fi

    rm -rf "${tmp_dir}"
}

extract_cloudflared_token() {
    if [[ -f /etc/systemd/system/cloudflared.service ]]; then
        sed -n 's/.*--token \([^[:space:]]*\).*/\1/p' /etc/systemd/system/cloudflared.service | head -1
    fi
}

download_configs() {
    local version="$1"
    local cloudflared_token="${CLOUDFLARED_TOKEN:-}"

    print_step "下载配置文件..."

    download_repo_file "$version" "config/start.sh" "${INSTALL_DIR}/start.sh"
    chmod +x "${INSTALL_DIR}/start.sh"

    if [[ "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        download_repo_file "$version" "config/systemd/rw-node.service" "/etc/systemd/system/rw-node.service"
        sed -i "s|__INSTALL_DIR__|${INSTALL_DIR}|g" /etc/systemd/system/rw-node.service

        if [[ "$WITH_CLOUDFLARED" == "true" || -f /etc/systemd/system/cloudflared.service || -x "${INSTALL_DIR}/bin/cloudflared" ]]; then
            if [[ -z "$cloudflared_token" ]]; then
                cloudflared_token=$(extract_cloudflared_token || true)
            fi

            download_repo_file "$version" "config/systemd/cloudflared.service" "/etc/systemd/system/cloudflared.service"
            sed -i "s|__INSTALL_DIR__|${INSTALL_DIR}|g" /etc/systemd/system/cloudflared.service

            if [[ -n "$cloudflared_token" ]]; then
                sed -i "s|YOUR_TUNNEL_TOKEN|${cloudflared_token}|g" /etc/systemd/system/cloudflared.service
            else
                print_warning "Cloudflare Tunnel Token 未设置，cloudflared 服务不会自动启用"
            fi
        fi

        systemctl daemon-reload
    fi

    print_success "配置文件下载完成"
}

configure_env() {
    print_step "配置环境变量..."

    case "${NODE_TLS_CLIENT_AUTH}" in
        mtls|optional|none) ;;
        *)
            print_error "NODE_TLS_CLIENT_AUTH 仅支持 mtls、optional 或 none"
            exit 1
            ;;
    esac

    if [[ -z "$SECRET_KEY" ]]; then
        if [[ ! -t 0 ]]; then
            print_error "SECRET_KEY 不能为空，请通过 --secret-key 提供"
            exit 1
        fi

        echo -e "${CYAN}"
        echo "=========================================="
        echo "  请输入配置信息"
        echo "=========================================="
        echo -e "${NC}"

        read -r -p "请输入面板 SECRET_KEY: " SECRET_KEY
        while [[ -z "$SECRET_KEY" ]]; do
            print_warning "SECRET_KEY 不能为空"
            read -r -p "请输入面板 SECRET_KEY: " SECRET_KEY
        done

        read -r -p "请输入节点端口 [默认: 2222]: " input_port
        NODE_PORT="${input_port:-2222}"

        read -r -p "请输入 Internal REST 端口 [默认: 61001]: " input_internal_port
        INTERNAL_REST_PORT="${input_internal_port:-61001}"
    fi

    cat > "${INSTALL_DIR}/.env" << EOF
### VITALS ###
NODE_PORT=${NODE_PORT}
SECRET_KEY=${SECRET_KEY}
NODE_TLS_CLIENT_AUTH=${NODE_TLS_CLIENT_AUTH}

### Internal (local) ports ###
INTERNAL_REST_PORT=${INTERNAL_REST_PORT}

### Runtime ###
REQUIRE_SECRET_KEY=true
XRAY_LOCATION_ASSET=${INSTALL_DIR}/share/xray

### HTTP Front (Caddy) ###
# HTTP_FRONT_ENABLED=true
# HTTP_FRONT_PORT=3000
# XHTTP_UPSTREAM_PORT=8080
# WS_UPSTREAM_PORT=8880
# CADDY_INDEX_PAGE=mikutap
# CADDY_DEFAULT_SITE_DIR=${INSTALL_DIR}/default-www

### REALITY TLS dynamic split ###
# REALITY_SPLIT_ENABLED=true
# REALITY_SPLIT_INTERVAL=15
EOF

    chmod 600 "${INSTALL_DIR}/.env"
    print_success "环境变量配置完成"
}

install_cloudflared() {
    if [[ "$WITH_CLOUDFLARED" != "true" ]]; then
        return 0
    fi

    print_step "安装 Cloudflare Tunnel..."

    # ensure_cloudflared() handles the binary download
    ensure_cloudflared

    if [[ -n "$CLOUDFLARED_TOKEN" && "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        systemctl enable cloudflared
    elif [[ "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        print_warning "未提供 Cloudflare Tunnel Token，仅安装二进制文件"
    fi

    print_success "Cloudflare Tunnel 安装完成"
}

create_helper_scripts() {
    local bin_dir="${INSTALL_DIR}/bin"

    print_step "创建辅助脚本..."

    mkdir -p "${bin_dir}"

    cat > "${bin_dir}/xlogs" << 'EOF'
#!/bin/bash
set -euo pipefail
echo "Go 实现使用内嵌 xray-core，不写入 xray.out.log；请查看: journalctl -u rw-node -f"
exit 0
EOF
    chmod +x "${bin_dir}/xlogs"

    cat > "${bin_dir}/xerrors" << 'EOF'
#!/bin/bash
set -euo pipefail
echo "Go 实现使用内嵌 xray-core，不写入 xray.err.log；请查看: journalctl -u rw-node -f"
exit 0
EOF
    chmod +x "${bin_dir}/xerrors"

    cat > "${bin_dir}/rw-node-status" << 'STATUSEOF'
#!/bin/bash
set -euo pipefail

INSTALL_DIR="${RW_NODE_DIR:-/opt/rw-node}"
RUN_DIR="${INSTALL_DIR}/run"

read_pid_file() {
    local file="$1"
    local pid

    [[ -f "$file" ]] || return 1
    pid=$(tr -d '[:space:]' < "$file" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -d "/proc/${pid}" ]] || return 1
    echo "$pid"
}

pid_matches_exe() {
    local pid="$1"
    local expected="$2"
    local exe

    exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
    [[ "$exe" == "$expected" ]]
}

find_process_by_prefix() {
    local prefix="$1"

    while read -r pid cmd; do
        [[ -n "$pid" && "$cmd" == "$prefix"* ]] || continue
        echo "$pid"
        return 0
    done < <(ps -eo pid=,args=)

    return 1
}

echo "=========================================="
echo "          RW-Node 状态信息"
echo "=========================================="
echo ""

echo "实现模式: go"

GO_VERSION=$(cat "${INSTALL_DIR}/.rw-node-go-version" 2>/dev/null || echo "未知")
echo "RW-Node Go 版本: ${GO_VERSION}"
echo "运行时: Go 单进程内嵌 xray-core"
echo ""

echo "=== 服务状态 ==="
NODE_PID=$(read_pid_file "${RUN_DIR}/rw-node.pid" || true)
if [[ -n "${NODE_PID:-}" ]] && pid_matches_exe "${NODE_PID}" "${INSTALL_DIR}/bin/rw-node-go"; then
    echo "RW-Node Go 进程: ✅ 运行中"
else
    FALLBACK_GO_PID=$(find_process_by_prefix "${INSTALL_DIR}/bin/rw-node-go" || true)
    if [[ -n "${FALLBACK_GO_PID:-}" ]]; then
        echo "RW-Node Go 进程: ✅ 运行中"
    else
        echo "RW-Node Go 进程: ❌ 未运行"
    fi
fi

CADDY_PID=$(find_process_by_prefix "${INSTALL_DIR}/bin/caddy" || true)
if [[ -n "${CADDY_PID:-}" ]]; then
    echo "Caddy: ✅ 运行中"
else
    echo "Caddy: ⏳ 待启动"
fi

CLOUDFLARED_PID=$(find_process_by_prefix "${INSTALL_DIR}/bin/cloudflared" || true)
if [[ -n "${CLOUDFLARED_PID:-}" ]]; then
    echo "Cloudflared: ✅ 运行中"
elif [[ -x "${INSTALL_DIR}/bin/cloudflared" ]]; then
    echo "Cloudflared: ❌ 未运行"
fi
echo ""

if [[ -f "${INSTALL_DIR}/.env" ]]; then
    echo "=== 配置信息 ==="
    NODE_PORT=$(grep -E "^NODE_PORT=" "${INSTALL_DIR}/.env" | cut -d'=' -f2)
    echo "节点端口: ${NODE_PORT:-2222}"
    INTERNAL_REST_PORT=$(grep -E "^INTERNAL_REST_PORT=" "${INSTALL_DIR}/.env" | cut -d'=' -f2)
    echo "Internal REST 端口: ${INTERNAL_REST_PORT:-61001}"
fi
echo ""
echo "=========================================="
STATUSEOF
    chmod +x "${bin_dir}/rw-node-status"

    if [[ "$HAS_SYSTEMD" != "true" || "$IS_CONTAINER" == "true" ]]; then
        cat > "${bin_dir}/rw-node-start" << 'EOF'
#!/bin/bash
set -euo pipefail
WORK_DIR="${RW_NODE_DIR:-/opt/rw-node}"
cd "${WORK_DIR}"
exec "${WORK_DIR}/start.sh"
EOF
        chmod +x "${bin_dir}/rw-node-start"

        cat > "${bin_dir}/rw-node-stop" << 'STOPEOF'
#!/bin/bash
set -euo pipefail

WORK_DIR="${RW_NODE_DIR:-/opt/rw-node}"
RUN_DIR="${WORK_DIR}/run"

read_pid_file() {
    local file="$1"
    local pid

    [[ -f "$file" ]] || return 1
    pid=$(tr -d '[:space:]' < "$file" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -d "/proc/${pid}" ]] || return 1
    echo "$pid"
}

pid_matches_exe() {
    local pid="$1"
    local expected="$2"
    local exe

    exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
    [[ "$exe" == "$expected" ]]
}

kill_pid_file() {
    local file="$1"
    local expected="$2"
    local pid

    pid=$(read_pid_file "$file" || true)
    [[ -n "$pid" ]] || return 0

    if pid_matches_exe "$pid" "$expected"; then
        kill "$pid" 2>/dev/null || true
    fi

    rm -f "$file"
}

kill_processes_by_prefix() {
    local prefix="$1"

    while read -r pid cmd; do
        [[ -n "$pid" && "$cmd" == "$prefix"* ]] || continue
        kill "$pid" 2>/dev/null || true
    done < <(ps -eo pid=,args=)
}

echo "停止 RW-Node..."

kill_pid_file "${RUN_DIR}/rw-node.pid" "${WORK_DIR}/bin/rw-node-go"

kill_processes_by_prefix "${WORK_DIR}/bin/rw-node-go"
kill_processes_by_prefix "${WORK_DIR}/bin/caddy"
kill_processes_by_prefix "${WORK_DIR}/bin/cloudflared"

rm -f "${WORK_DIR}/run"/*.sock "${WORK_DIR}/run"/*.pid 2>/dev/null || true
echo "已停止"
STOPEOF
        chmod +x "${bin_dir}/rw-node-stop"
    fi

    for script in xlogs xerrors rw-node-status rw-node-start rw-node-stop; do
        if [[ -x "${bin_dir}/${script}" ]]; then
            ln -sf "${bin_dir}/${script}" "/usr/local/bin/${script}" 2>/dev/null || true
        fi
    done

    print_success "辅助脚本创建完成"
}

start_service() {
    print_step "启动服务..."

    if [[ "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        systemctl enable rw-node
        systemctl start rw-node

        if [[ "$WITH_CLOUDFLARED" == "true" && -n "$CLOUDFLARED_TOKEN" && -f /etc/systemd/system/cloudflared.service ]]; then
            systemctl enable cloudflared
            systemctl restart cloudflared
        fi

        sleep 3

        if systemctl is-active --quiet rw-node; then
            print_success "服务启动成功"
        else
            print_error "服务启动失败，请查看日志: journalctl -u rw-node -f"
            exit 1
        fi
    else
        print_warning "无 Systemd 或容器环境，不自动启动服务"
        print_info "请手动运行: rw-node-start 或 ${INSTALL_DIR}/start.sh"
    fi
}

print_completion() {
    echo ""
    echo -e "${GREEN}"
    echo "=========================================="
    echo "  RW-Node 安装完成!"
    echo "=========================================="
    echo -e "${NC}"
    echo ""

    if [[ "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        echo -e "${CYAN}服务管理:${NC}"
        echo "  systemctl {start|stop|restart|status} rw-node"
        echo ""
        echo -e "${CYAN}日志查看:${NC}"
        echo "  journalctl -u rw-node -f"
    else
        echo -e "${CYAN}服务管理:${NC}"
        echo "  启动: rw-node-start"
        echo "  停止: rw-node-stop"
        echo "  状态: rw-node-status"
        echo ""
        echo -e "${CYAN}前台运行:${NC}"
        echo "  ${INSTALL_DIR}/start.sh"
        echo ""
        echo -e "${YELLOW}提示: 容器/无 systemd 环境下请使用 screen/tmux 或进程管理器运行${NC}"
    fi

    echo ""
    echo -e "${CYAN}日志查看:${NC}"
    echo "  journalctl -u rw-node -f"
    echo ""
    echo -e "${CYAN}配置文件:${NC} ${INSTALL_DIR}/.env"
    echo ""
}

require_value() {
    local option="$1"

    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        print_error "${option} 需要一个值"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-cloudflared)
                WITH_CLOUDFLARED=true
                shift
                ;;
            --cloudflared-token)
                require_value "$1" "${2:-}"
                CLOUDFLARED_TOKEN="$2"
                WITH_CLOUDFLARED=true
                shift 2
                ;;
            --go-version)
                require_value "$1" "${2:-}"
                GO_VERSION="$2"
                shift 2
                ;;
            --port|-p)
                require_value "$1" "${2:-}"
                NODE_PORT="$2"
                shift 2
                ;;
            --internal-rest-port)
                require_value "$1" "${2:-}"
                INTERNAL_REST_PORT="$2"
                shift 2
                ;;
            --node-tls-client-auth)
                require_value "$1" "${2:-}"
                case "$2" in
                    mtls|optional|none) NODE_TLS_CLIENT_AUTH="$2" ;;
                    *) print_error "--node-tls-client-auth 仅支持 mtls、optional 或 none"; exit 1 ;;
                esac
                shift 2
                ;;
            --secret-key|-k)
                require_value "$1" "${2:-}"
                SECRET_KEY="$2"
                shift 2
                ;;
            --help|-h)
                echo "用法: $0 [选项]"
                echo "  --go-version <版本>          指定 rw-node-go 版本 (默认: 最新 release)"
                echo "  --port, -p <端口>            节点端口 (默认: 2222)"
                echo "  --internal-rest-port <端口>  Internal REST 端口 (默认: 61001)"
                echo "  --node-tls-client-auth <模式> TLS 客户端证书策略: mtls|optional|none (默认: mtls)"
                echo "  --secret-key, -k <密钥>      面板密钥"
                echo "  --with-cloudflared           安装 Cloudflare Tunnel"
                echo "  --cloudflared-token <令牌>   Cloudflare Tunnel Token"
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                exit 1
                ;;
        esac
    done
}

main() {
    echo -e "${CYAN}"
    echo "=========================================="
    echo "  RW-Node 一键安装脚本 (Go 实现)"
    echo "  https://github.com/${GITHUB_REPO}"
    echo "=========================================="
    echo -e "${NC}"

    parse_args "$@"
    check_root
    detect_container
    detect_os
    check_dependencies

    # Download and source shared lib scripts
    download_lib_scripts "main"
    source "${INSTALL_DIR}/lib/core.sh"
    source "${INSTALL_DIR}/lib/provision.sh"
    setup_provision_vars

    # If user specified --go-version, set RW_NODE_GO_VERSION for provision.sh
    if [[ -n "$GO_VERSION" ]]; then
        export RW_NODE_GO_VERSION="$GO_VERSION"
    fi

    # Install rw-node-go binary + geodata
    print_step "安装 RW-Node Go 实现..."
    ensure_rw_node_go
    printf 'go\n' > "${INSTALL_DIR}/.rw-node-impl"
    print_success "RW-Node Go 实现安装完成"

    # Install Caddy with layer4 plugin
    print_step "安装 Caddy L4..."
    ensure_caddy
    print_success "Caddy L4 安装完成"

    # Install default camouflage page
    install_default_www

    # Download config files (start.sh, systemd services)
    download_configs "main"

    configure_env
    install_cloudflared
    create_helper_scripts
    start_service
    print_completion
}

main "$@"
