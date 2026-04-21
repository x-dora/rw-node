#!/bin/bash

set -euo pipefail

#######################################
# RW-Node 一键安装脚本
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
UPSTREAM_REPO="remnawave/node"
DEFAULT_XRAY_VERSION="v25.12.8"
DEFAULT_NODE_VERSION="22"

WITH_CLOUDFLARED=false
CLOUDFLARED_TOKEN=""
INSTALL_VERSION=""
RESOLVED_VERSION=""
NODE_PORT="2222"
SECRET_KEY=""
XTLS_API_PORT="61000"

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

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) print_error "不支持的架构: $arch"; exit 1 ;;
    esac
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
    if ! command -v git >/dev/null 2>&1; then
        missing+=("git")
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        missing+=("unzip")
    fi
    if ! command -v jq >/dev/null 2>&1; then
        missing+=("jq")
    fi
    if ! command -v pgrep >/dev/null 2>&1; then
        case "$PKG_MANAGER" in
            apt) missing+=("procps") ;;
            yum|dnf) missing+=("procps-ng") ;;
            apk) missing+=("procps") ;;
        esac
    fi
    if ! xz --version >/dev/null 2>&1; then
        case "$PKG_MANAGER" in
            apt) missing+=("xz-utils") ;;
            yum|dnf) missing+=("xz") ;;
            apk) missing+=("xz") ;;
        esac
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_info "安装依赖: ${missing[*]}"
        install_packages "${missing[@]}"
    fi

    print_success "依赖检查完成"
}

get_latest_release_tag() {
    local repo="$1"
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty'
}

get_latest_version() {
    local version
    version=$(get_latest_release_tag "${GITHUB_REPO}" || true)

    if [[ -z "$version" ]]; then
        version=$(get_latest_release_tag "${UPSTREAM_REPO}" || true)
    fi

    echo "$version"
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

clean_rw_node_artifacts() {
    rm -rf \
        "${INSTALL_DIR}/dist" \
        "${INSTALL_DIR}/libs" \
        "${INSTALL_DIR}/node_modules" \
        "${INSTALL_DIR}/package.json" \
        "${INSTALL_DIR}/package-lock.json"
}

install_nodejs() {
    local arch node_arch node_ver url tmp_dir tarball current_major

    print_step "安装 Node.js..."

    if [[ -x "${INSTALL_DIR}/node/bin/node" ]]; then
        current_major=$("${INSTALL_DIR}/node/bin/node" -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [[ "${current_major}" =~ ^[0-9]+$ && "${current_major}" -ge 22 ]]; then
            print_info "Node.js 已安装"
            return 0
        fi
    fi

    arch=$(detect_arch)
    node_arch=$([[ "$arch" == "amd64" ]] && echo "x64" || echo "arm64")
    node_ver=$(curl -fsSL "https://nodejs.org/dist/index.json" | jq -r --arg major "v${DEFAULT_NODE_VERSION}." '[.[] | select(.version | startswith($major))][0].version | ltrimstr("v")')

    if [[ -z "$node_ver" || "$node_ver" == "null" ]]; then
        print_error "无法获取 Node.js ${DEFAULT_NODE_VERSION}.x 最新版本"
        exit 1
    fi

    url="https://nodejs.org/dist/v${node_ver}/node-v${node_ver}-linux-${node_arch}.tar.xz"
    tmp_dir="/tmp/rw-node-install-node"
    tarball="${tmp_dir}/node-v${node_ver}-linux-${node_arch}.tar.xz"

    print_info "下载 Node.js v${node_ver}..."

    mkdir -p "${INSTALL_DIR}" "${tmp_dir}"
    rm -rf "${tmp_dir:?}/"*
    curl -fsSL "$url" -o "$tarball"
    tar -xJf "$tarball" -C "$tmp_dir"

    rm -rf "${INSTALL_DIR}/node"
    mv "${tmp_dir}/node-v${node_ver}-linux-${node_arch}" "${INSTALL_DIR}/node"

    print_success "Node.js v${node_ver} 安装完成"
}

install_supervisord() {
    local arch version arch_name url tmp_dir archive extracted_dir

    print_step "安装 Supervisord..."

    mkdir -p "${INSTALL_DIR}/bin"

    if [[ -x "${INSTALL_DIR}/bin/supervisord" ]]; then
        print_info "Supervisord 已安装"
        return 0
    fi

    arch=$(detect_arch)
    version="0.7.3"
    arch_name=$([[ "$arch" == "arm64" ]] && echo "ARM64" || echo "64-bit")
    url="https://github.com/ochinchina/supervisord/releases/download/v${version}/supervisord_${version}_Linux_${arch_name}.tar.gz"
    tmp_dir="/tmp/rw-node-install-supervisord"
    archive="${tmp_dir}/supervisord.tar.gz"
    extracted_dir="${tmp_dir}/supervisord_${version}_Linux_${arch_name}"

    print_info "下载 Supervisord v${version}..."

    mkdir -p "${tmp_dir}"
    rm -rf "${tmp_dir:?}/"*
    curl -fsSL "$url" -o "$archive"
    tar -xzf "$archive" -C "$tmp_dir"
    mv "${extracted_dir}/supervisord" "${INSTALL_DIR}/bin/supervisord"
    chmod +x "${INSTALL_DIR}/bin/supervisord"
    mkdir -p "${INSTALL_DIR}/logs" "${INSTALL_DIR}/run" "${INSTALL_DIR}/conf"

    print_success "Supervisord v${version} 安装完成"
}

install_xray() {
    local arch version xray_arch url tmp_dir archive asset_dir

    print_step "安装 Xray-core..."

    mkdir -p "${INSTALL_DIR}/bin"
    asset_dir="${INSTALL_DIR}/share/xray"
    mkdir -p "${asset_dir}"

    if [[ -x "${INSTALL_DIR}/bin/xray" ]] \
        && [[ -f "${asset_dir}/geoip.dat" ]] \
        && [[ -f "${asset_dir}/geosite.dat" ]]; then
        print_info "Xray-core 已安装"
        ln -sf "${INSTALL_DIR}/bin/xray" "${INSTALL_DIR}/bin/rw-core"
        return 0
    fi

    arch=$(detect_arch)
    version="${XRAY_VERSION:-$DEFAULT_XRAY_VERSION}"
    xray_arch=$([[ "$arch" == "arm64" ]] && echo "arm64-v8a" || echo "64")
    url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${xray_arch}.zip"
    tmp_dir="/tmp/rw-node-install-xray"
    archive="${tmp_dir}/xray.zip"

    print_info "下载 Xray-core ${version}..."

    mkdir -p "${tmp_dir}"
    rm -rf "${tmp_dir:?}/"*
    curl -fsSL "$url" -o "$archive"
    unzip -q "$archive" -d "$tmp_dir/xray"

    install -m 755 "$tmp_dir/xray/xray" "${INSTALL_DIR}/bin/xray"

    if [[ ! -f "$tmp_dir/xray/geoip.dat" || ! -f "$tmp_dir/xray/geosite.dat" ]]; then
        print_error "Xray 压缩包缺少 geoip.dat / geosite.dat"
        exit 1
    fi
    install -m 644 "$tmp_dir/xray/geoip.dat"   "${asset_dir}/geoip.dat"
    install -m 644 "$tmp_dir/xray/geosite.dat" "${asset_dir}/geosite.dat"

    ln -sf "${INSTALL_DIR}/bin/xray" "${INSTALL_DIR}/bin/rw-core"

    print_success "Xray-core ${version} 安装完成 (assets: ${asset_dir})"
}

build_from_source() {
    local version="$1"
    local tmp_dir="/tmp/rw-node-build"

    print_step "从源码构建..."

    rm -rf "$tmp_dir"
    if ! git clone --depth 1 --branch "$version" "https://github.com/${UPSTREAM_REPO}.git" "$tmp_dir"; then
        print_error "上游仓库中不存在版本/分支: $version"
        exit 1
    fi

    (
        cd "$tmp_dir"
        "${INSTALL_DIR}/node/bin/npm" ci --legacy-peer-deps
        "${INSTALL_DIR}/node/bin/npm" run build
    )

    mkdir -p "${INSTALL_DIR}"
    clean_rw_node_artifacts
    cp -r "${tmp_dir}/dist" "${INSTALL_DIR}/"
    cp -r "${tmp_dir}/libs" "${INSTALL_DIR}/"
    cp "${tmp_dir}"/package*.json "${INSTALL_DIR}/"

    (
        cd "${INSTALL_DIR}"
        "${INSTALL_DIR}/node/bin/npm" ci --omit=dev --legacy-peer-deps
    )

    rm -rf "$tmp_dir"
    print_success "构建完成"
}

install_rw_node() {
    local arch version url tmp_dir archive

    print_step "安装 RW-Node..."

    arch=$(detect_arch)
    version="${INSTALL_VERSION:-$(get_latest_version)}"

    if [[ -z "$version" ]]; then
        print_error "无法获取版本"
        exit 1
    fi

    RESOLVED_VERSION="$version"
    url="https://github.com/${GITHUB_REPO}/releases/download/${version}/rw-node-${version}-linux-${arch}.tar.gz"
    tmp_dir="/tmp/rw-node-install-release"
    archive="${tmp_dir}/rw-node-${version}-linux-${arch}.tar.gz"

    print_info "安装版本: $version"
    print_info "下载: $url"

    mkdir -p "${INSTALL_DIR}" "${tmp_dir}"
    rm -rf "${tmp_dir:?}/"*

    if curl -fsSL "$url" -o "$archive"; then
        clean_rw_node_artifacts
        tar -xzf "$archive" -C "${INSTALL_DIR}"
        print_success "RW-Node 安装完成"
    else
        print_warning "预编译包不存在，从源码构建..."
        build_from_source "$version"
    fi
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

        read -r -p "请输入 Xray API 端口 [默认: 61000]: " input_api_port
        XTLS_API_PORT="${input_api_port:-61000}"
    fi

    cat > "${INSTALL_DIR}/.env" << EOF
### VITALS ###
NODE_PORT=${NODE_PORT}
SECRET_KEY=${SECRET_KEY}

### Internal (local) ports ###
XTLS_API_PORT=${XTLS_API_PORT}
EOF

    chmod 600 "${INSTALL_DIR}/.env"
    print_success "环境变量配置完成"
}

install_cloudflared() {
    local arch url

    if [[ "$WITH_CLOUDFLARED" != "true" ]]; then
        return 0
    fi

    print_step "安装 Cloudflare Tunnel..."

    mkdir -p "${INSTALL_DIR}/bin"
    arch=$(detect_arch)
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"

    curl -fsSL -o "${INSTALL_DIR}/bin/cloudflared" "$url"
    chmod +x "${INSTALL_DIR}/bin/cloudflared"

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
WORK_DIR="${RW_NODE_DIR:-/opt/rw-node}"
tail -n +1 -f "${WORK_DIR}/logs/xray.out.log"
EOF
    chmod +x "${bin_dir}/xlogs"

    cat > "${bin_dir}/xerrors" << 'EOF'
#!/bin/bash
set -euo pipefail
WORK_DIR="${RW_NODE_DIR:-/opt/rw-node}"
tail -n +1 -f "${WORK_DIR}/logs/xray.err.log"
EOF
    chmod +x "${bin_dir}/xerrors"

    cat > "${bin_dir}/rw-node-status" << 'EOF'
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

if [[ -f "${INSTALL_DIR}/package.json" ]]; then
    VERSION=$(jq -r '.version // "未知"' "${INSTALL_DIR}/package.json" 2>/dev/null || echo "未知")
    echo "RW-Node 版本: ${VERSION}"
else
    echo "RW-Node 版本: 未知"
fi

XRAY_BIN="${INSTALL_DIR}/bin/rw-core"
XRAY_VER=$("${XRAY_BIN}" version 2>/dev/null | head -1 || echo "未安装")
echo "Xray 版本: ${XRAY_VER}"

NODE_BIN="${INSTALL_DIR}/node/bin/node"
NODE_VER=$("${NODE_BIN}" -v 2>/dev/null || echo "未知")
echo "Node.js 版本: ${NODE_VER}"
echo ""

echo "=== 服务状态 ==="
NODE_PID=$(read_pid_file "${RUN_DIR}/rw-node.pid" || true)
if [[ -n "${NODE_PID:-}" ]] && pid_matches_exe "${NODE_PID}" "${INSTALL_DIR}/node/bin/node"; then
    echo "RW-Node 进程: ✅ 运行中"
else
    FALLBACK_NODE_PID=$(find_process_by_prefix "${INSTALL_DIR}/node/bin/node dist/src/main" || true)
    if [[ -n "${FALLBACK_NODE_PID:-}" ]]; then
        echo "RW-Node 进程: ✅ 运行中"
    else
        echo "RW-Node 进程: ❌ 未运行"
    fi
fi

SUPERVISORD_PID_FILE=$(find "${RUN_DIR}" -maxdepth 1 -name 'supervisord-*.pid' | head -1 || true)
SUPERVISORD_PID=$(read_pid_file "${SUPERVISORD_PID_FILE:-/dev/null}" || true)
if [[ -n "${SUPERVISORD_PID:-}" ]] && pid_matches_exe "${SUPERVISORD_PID}" "${INSTALL_DIR}/bin/supervisord"; then
    echo "Supervisord: ✅ 运行中"
else
    FALLBACK_SUPERVISORD_PID=$(find_process_by_prefix "${INSTALL_DIR}/bin/supervisord" || true)
    if [[ -n "${FALLBACK_SUPERVISORD_PID:-}" ]]; then
        echo "Supervisord: ✅ 运行中"
    else
        echo "Supervisord: ❌ 未运行"
    fi
fi

XRAY_PID=$(find_process_by_prefix "${INSTALL_DIR}/bin/rw-core" || true)
if [[ -n "${XRAY_PID:-}" ]]; then
    echo "Xray: ✅ 运行中"
else
    echo "Xray: ⏳ 待启动"
fi
echo ""

if [[ -f "${INSTALL_DIR}/.env" ]]; then
    echo "=== 配置信息 ==="
    NODE_PORT=$(grep -E "^NODE_PORT=" "${INSTALL_DIR}/.env" | cut -d'=' -f2)
    XTLS_API_PORT=$(grep -E "^XTLS_API_PORT=" "${INSTALL_DIR}/.env" | cut -d'=' -f2)
    echo "节点端口: ${NODE_PORT:-2222}"
    echo "API 端口: ${XTLS_API_PORT:-61000}"
fi
echo ""
echo "=========================================="
EOF
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

        cat > "${bin_dir}/rw-node-stop" << 'EOF'
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

kill_pid_file "${RUN_DIR}/rw-node.pid" "${WORK_DIR}/node/bin/node"

while read -r pid_file; do
    kill_pid_file "$pid_file" "${WORK_DIR}/bin/supervisord"
done < <(find "${RUN_DIR}" -maxdepth 1 -name 'supervisord-*.pid' -print)

kill_processes_by_prefix "${WORK_DIR}/node/bin/node dist/src/main"
kill_processes_by_prefix "${WORK_DIR}/bin/supervisord"
kill_processes_by_prefix "${WORK_DIR}/bin/rw-core"
kill_processes_by_prefix "${WORK_DIR}/bin/xray"
kill_processes_by_prefix "${WORK_DIR}/bin/cloudflared"

rm -f "${WORK_DIR}/run"/*.sock "${WORK_DIR}/run"/*.pid "${WORK_DIR}/conf/supervisord.conf" 2>/dev/null || true
echo "已停止"
EOF
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
    echo "  xlogs / xerrors"
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
            --version|-v)
                require_value "$1" "${2:-}"
                INSTALL_VERSION="$2"
                shift 2
                ;;
            --port|-p)
                require_value "$1" "${2:-}"
                NODE_PORT="$2"
                shift 2
                ;;
            --xtls-api-port)
                require_value "$1" "${2:-}"
                XTLS_API_PORT="$2"
                shift 2
                ;;
            --secret-key|-k)
                require_value "$1" "${2:-}"
                SECRET_KEY="$2"
                shift 2
                ;;
            --xray-version)
                require_value "$1" "${2:-}"
                XRAY_VERSION="$2"
                shift 2
                ;;
            --help|-h)
                echo "用法: $0 [选项]"
                echo "  --version, -v <版本>         指定版本"
                echo "  --port, -p <端口>            节点端口 (默认: 2222)"
                echo "  --xtls-api-port <端口>       Xray API 端口 (默认: 61000)"
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
    echo "  RW-Node 一键安装脚本"
    echo "  https://github.com/${GITHUB_REPO}"
    echo "=========================================="
    echo -e "${NC}"

    parse_args "$@"
    check_root
    detect_container
    detect_os
    check_dependencies
    install_nodejs
    install_supervisord
    install_xray
    install_rw_node
    download_configs "${RESOLVED_VERSION}"
    configure_env
    install_cloudflared
    create_helper_scripts
    start_service
    print_completion
}

main "$@"
