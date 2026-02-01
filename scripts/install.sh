#!/bin/bash

set -e

#######################################
# RW-Node 一键安装脚本
# 无需 Docker 的轻量化部署方案
# 仓库: https://github.com/x-dora/rw-node
#######################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置变量
INSTALL_DIR="/opt/rw-node"
LOG_DIR="/var/log/supervisor"
GITHUB_REPO="x-dora/rw-node"
GITHUB_RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main"
UPSTREAM_REPO="remnawave/node"
XRAY_INSTALL_SCRIPT="https://raw.githubusercontent.com/remnawave/scripts/main/scripts/install-xray.sh"
DEFAULT_XRAY_VERSION="v25.12.8"
DEFAULT_NODE_VERSION="22"

# 参数默认值
WITH_CLOUDFLARED=false
CLOUDFLARED_TOKEN=""
INSTALL_VERSION=""
NODE_PORT="2222"
SECRET_KEY=""
XTLS_API_PORT="61000"

# 环境检测
IS_CONTAINER=false
HAS_SYSTEMD=false

#######################################
# 打印函数
#######################################
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${PURPLE}[STEP]${NC} $1"; }

#######################################
# 检查 root 权限
#######################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

#######################################
# 检测容器环境
#######################################
detect_container() {
    print_step "检测运行环境..."
    
    # 检测是否在容器中
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
    elif systemd-detect-virt --container &>/dev/null; then
        IS_CONTAINER=true
        print_info "检测到容器环境 (systemd-detect-virt)"
    fi
    
    # 检测是否有 systemd
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        # 进一步检查 systemd 是否真正运行
        if [[ -d /run/systemd/system ]]; then
            HAS_SYSTEMD=true
            print_info "Systemd 可用"
        else
            print_info "Systemd 已安装但未运行"
        fi
    else
        print_info "Systemd 不可用"
    fi
    
    # 总结
    if [[ "$IS_CONTAINER" == "true" ]]; then
        print_warning "容器环境下将使用前台运行模式"
    elif [[ "$HAS_SYSTEMD" == "true" ]]; then
        print_info "将使用 Systemd 服务模式"
    else
        print_warning "无 Systemd，将使用前台运行模式"
    fi
}

#######################################
# 检测系统架构
#######################################
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) print_error "不支持的架构: $arch"; exit 1 ;;
    esac
}

#######################################
# 检测操作系统
#######################################
detect_os() {
    if [[ -f /etc/os-release ]]; then
        OS=$(. /etc/os-release && echo "$ID")
        OS_VERSION=$(. /etc/os-release && echo "$VERSION_ID")
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
    else
        OS="unknown"
    fi
    print_info "检测到操作系统: $OS ${OS_VERSION:-}"
}

#######################################
# 检查基础依赖（只需要 curl）
#######################################
check_dependencies() {
    print_step "检查依赖..."
    
    if ! command -v curl &> /dev/null; then
        print_info "安装 curl..."
        case $OS in
            ubuntu|debian)
                apt-get -o Acquire::Check-Valid-Until=false update -qq 2>/dev/null || true
                apt-get install -y -qq curl
                ;;
            centos|rhel|almalinux|rocky|fedora)
                yum install -y -q curl 2>/dev/null || dnf install -y -q curl
                ;;
            alpine)
                apk add --no-cache curl
                ;;
        esac
    fi
    
    print_success "依赖检查完成"
}

#######################################
# 获取最新版本
#######################################
get_latest_version() {
    local api_response=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null)
    local version=$(echo "$api_response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    
    if [[ -z "$version" ]]; then
        api_response=$(curl -fsSL "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" 2>/dev/null)
        version=$(echo "$api_response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
    echo "$version"
}

#######################################
# 安装 Node.js（直接下载二进制包）
#######################################
install_nodejs() {
    print_step "安装 Node.js..."
    
    # 检查是否已安装
    if [[ -x "$INSTALL_DIR/node/bin/node" ]]; then
        local ver=$("$INSTALL_DIR/node/bin/node" -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [[ $ver -ge 22 ]]; then
            print_info "Node.js 已安装"
            return 0
        fi
    fi
    
    local arch=$(detect_arch)
    local node_arch=$([[ "$arch" == "amd64" ]] && echo "x64" || echo "arm64")
    
    # 获取最新 Node.js 22.x 版本
    local node_ver=$(curl -fsSL "https://nodejs.org/dist/latest-v${DEFAULT_NODE_VERSION}.x/" | grep -oP 'node-v\K[0-9.]+' | head -1)
    local url="https://nodejs.org/dist/v${node_ver}/node-v${node_ver}-linux-${node_arch}.tar.xz"
    
    print_info "下载 Node.js v${node_ver}..."
    
    mkdir -p $INSTALL_DIR
    curl -fsSL "$url" | tar -xJ -C /tmp
    rm -rf $INSTALL_DIR/node
    mv "/tmp/node-v${node_ver}-linux-${node_arch}" $INSTALL_DIR/node
    
    # 创建符号链接
    ln -sf $INSTALL_DIR/node/bin/node /usr/local/bin/node 2>/dev/null || true
    ln -sf $INSTALL_DIR/node/bin/npm /usr/local/bin/npm 2>/dev/null || true
    
    print_success "Node.js v${node_ver} 安装完成"
}

#######################################
# 安装 Supervisord（Go 版本）
#######################################
install_supervisord() {
    print_step "安装 Supervisord..."
    
    if [[ -x /usr/local/bin/supervisord ]]; then
        print_info "Supervisord 已安装"
        return 0
    fi
    
    local arch=$(detect_arch)
    local version="0.7.3"
    
    # 文件名格式: supervisord_0.7.3_Linux_64-bit.tar.gz / supervisord_0.7.3_Linux_ARM64.tar.gz
    local arch_name=""
    if [[ "$arch" == "arm64" ]]; then
        arch_name="ARM64"
    else
        arch_name="64-bit"
    fi
    
    local url="https://github.com/ochinchina/supervisord/releases/download/v${version}/supervisord_${version}_Linux_${arch_name}.tar.gz"
    
    print_info "下载 Supervisord v${version}..."
    print_info "下载地址: $url"
    
    cd /tmp
    if curl -fsSL "$url" -o supervisord.tar.gz; then
        tar -xzf supervisord.tar.gz
        mv "supervisord_${version}_Linux_${arch_name}/supervisord" /usr/local/bin/supervisord 2>/dev/null || \
        find /tmp -name "supervisord" -type f -exec mv {} /usr/local/bin/supervisord \;
        chmod +x /usr/local/bin/supervisord
        rm -rf /tmp/supervisord* /tmp/supervisord_*
        print_success "Supervisord v${version} 安装完成"
    else
        print_error "Supervisord 下载失败"
        exit 1
    fi
    
    mkdir -p $LOG_DIR
}

#######################################
# 安装 Xray-core
#######################################
install_xray() {
    print_step "安装 Xray-core..."
    
    if [[ -x /usr/local/bin/xray ]]; then
        print_info "Xray-core 已安装"
    else
        curl -fsSL $XRAY_INSTALL_SCRIPT | bash -s -- ${XRAY_VERSION:-$DEFAULT_XRAY_VERSION} XTLS
    fi
    
    ln -sf /usr/local/bin/xray /usr/local/bin/rw-core 2>/dev/null || true
    
    print_success "Xray-core 安装完成"
}

#######################################
# 安装 RW-Node
#######################################
install_rw_node() {
    print_step "安装 RW-Node..."
    
    local arch=$(detect_arch)
    local version="${INSTALL_VERSION:-$(get_latest_version)}"
    
    if [[ -z "$version" ]]; then
        print_error "无法获取版本"
        exit 1
    fi
    
    print_info "安装版本: $version"
    
    mkdir -p $INSTALL_DIR
    local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/rw-node-${version}-linux-${arch}.tar.gz"
    
    print_info "下载: $url"
    
    if curl -fsSL "$url" | tar -xz -C $INSTALL_DIR; then
        print_success "RW-Node 安装完成"
    else
        print_warning "预编译包不存在，从源码构建..."
        build_from_source "$version"
    fi
}

#######################################
# 从源码构建
#######################################
build_from_source() {
    local version=$1
    
    print_step "从源码构建..."
    
    cd /tmp && rm -rf node-build
    git clone --depth 1 --branch "$version" "https://github.com/${UPSTREAM_REPO}.git" node-build 2>/dev/null || \
    git clone --depth 1 "https://github.com/${UPSTREAM_REPO}.git" node-build
    
    cd node-build
    $INSTALL_DIR/node/bin/npm ci --legacy-peer-deps
    $INSTALL_DIR/node/bin/npm run build
    
    mkdir -p $INSTALL_DIR
    cp -r dist libs package*.json $INSTALL_DIR/
    
    cd $INSTALL_DIR
    $INSTALL_DIR/node/bin/npm ci --omit=dev --legacy-peer-deps
    
    rm -rf /tmp/node-build
    print_success "构建完成"
}

#######################################
# 下载配置文件（从仓库获取）
#######################################
download_configs() {
    print_step "下载配置文件..."
    
    # 下载启动脚本
    curl -fsSL "${GITHUB_RAW_URL}/config/start.sh" -o $INSTALL_DIR/start.sh
    chmod +x $INSTALL_DIR/start.sh
    
    # 只有在有 systemd 的非容器环境下才安装服务
    if [[ "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        # 下载 systemd 服务文件
        curl -fsSL "${GITHUB_RAW_URL}/config/systemd/rw-node.service" -o /etc/systemd/system/rw-node.service
        
        # 如果启用 cloudflared，下载其服务文件
        if [[ "$WITH_CLOUDFLARED" == "true" ]]; then
            curl -fsSL "${GITHUB_RAW_URL}/config/systemd/cloudflared.service" -o /etc/systemd/system/cloudflared.service
            # 替换 token
            if [[ -n "$CLOUDFLARED_TOKEN" ]]; then
                sed -i "s/YOUR_TUNNEL_TOKEN/${CLOUDFLARED_TOKEN}/g" /etc/systemd/system/cloudflared.service
            fi
        fi
        
        systemctl daemon-reload
    fi
    
    print_success "配置文件下载完成"
}

#######################################
# 配置环境变量
#######################################
configure_env() {
    print_step "配置环境变量..."
    
    if [[ -z "$SECRET_KEY" ]]; then
        echo -e "${CYAN}"
        echo "=========================================="
        echo "  请输入配置信息"
        echo "=========================================="
        echo -e "${NC}"
        
        read -p "请输入面板 SECRET_KEY: " SECRET_KEY
        while [[ -z "$SECRET_KEY" ]]; do
            print_warning "SECRET_KEY 不能为空"
            read -p "请输入面板 SECRET_KEY: " SECRET_KEY
        done
        
        read -p "请输入节点端口 [默认: 2222]: " input_port
        NODE_PORT=${input_port:-2222}
        
        read -p "请输入 Xray API 端口 [默认: 61000]: " input_api_port
        XTLS_API_PORT=${input_api_port:-61000}
    fi
    
    cat > $INSTALL_DIR/.env << EOF
### VITALS ###
NODE_PORT=${NODE_PORT}
SECRET_KEY=${SECRET_KEY}

### Internal (local) ports
XTLS_API_PORT=${XTLS_API_PORT}
EOF
    
    chmod 600 $INSTALL_DIR/.env
    print_success "环境变量配置完成"
}

#######################################
# 安装 Cloudflared
#######################################
install_cloudflared() {
    if [[ "$WITH_CLOUDFLARED" != "true" ]]; then
        return 0
    fi
    
    print_step "安装 Cloudflare Tunnel..."
    
    local arch=$(detect_arch)
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    
    curl -fsSL -o /usr/local/bin/cloudflared "$url"
    chmod +x /usr/local/bin/cloudflared
    
    if [[ -n "$CLOUDFLARED_TOKEN" && "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        systemctl enable cloudflared
    fi
    
    print_success "Cloudflare Tunnel 安装完成"
}

#######################################
# 创建辅助脚本
#######################################
create_helper_scripts() {
    print_step "创建辅助脚本..."
    
    # xlogs
    echo '#!/bin/bash
tail -n +1 -f /var/log/supervisor/xray.out.log' > /usr/local/bin/xlogs
    chmod +x /usr/local/bin/xlogs
    
    # xerrors
    echo '#!/bin/bash
tail -n +1 -f /var/log/supervisor/xray.err.log' > /usr/local/bin/xerrors
    chmod +x /usr/local/bin/xerrors
    
    # rw-node-status (通用版本，显示详细信息)
    cat > /usr/local/bin/rw-node-status << 'STATUSEOF'
#!/bin/bash
INSTALL_DIR="/opt/rw-node"

echo "=========================================="
echo "          RW-Node 状态信息"
echo "=========================================="
echo ""

# 版本信息
if [[ -f "$INSTALL_DIR/package.json" ]]; then
    VERSION=$(grep '"version"' "$INSTALL_DIR/package.json" | head -1 | cut -d'"' -f4)
    echo "RW-Node 版本: $VERSION"
else
    echo "RW-Node 版本: 未知"
fi

XRAY_VER=$(/usr/local/bin/rw-core version 2>/dev/null | head -1 || echo "未安装")
echo "Xray 版本: $XRAY_VER"

NODE_VER=$("$INSTALL_DIR/node/bin/node" -v 2>/dev/null || node -v 2>/dev/null || echo "未知")
echo "Node.js 版本: $NODE_VER"
echo ""

# 服务状态
echo "=== 服务状态 ==="
if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
    if systemctl is-active --quiet rw-node 2>/dev/null; then
        echo "RW-Node 服务: ✅ 运行中"
    else
        echo "RW-Node 服务: ❌ 未运行"
    fi
else
    if pgrep -f "node dist/src/main" > /dev/null; then
        echo "RW-Node 进程: ✅ 运行中"
    else
        echo "RW-Node 进程: ❌ 未运行"
    fi
fi

if pgrep -f supervisord > /dev/null; then
    echo "Supervisord: ✅ 运行中"
else
    echo "Supervisord: ❌ 未运行"
fi

if pgrep -f rw-core > /dev/null || pgrep -f xray > /dev/null; then
    echo "Xray: ✅ 运行中"
else
    echo "Xray: ⏳ 待启动"
fi
echo ""

# 配置信息
if [[ -f "$INSTALL_DIR/.env" ]]; then
    echo "=== 配置信息 ==="
    NODE_PORT=$(grep -E "^NODE_PORT=" "$INSTALL_DIR/.env" | cut -d'=' -f2)
    XTLS_API_PORT=$(grep -E "^XTLS_API_PORT=" "$INSTALL_DIR/.env" | cut -d'=' -f2)
    echo "节点端口: ${NODE_PORT:-2222}"
    echo "API 端口: ${XTLS_API_PORT:-61000}"
fi
echo ""
echo "=========================================="
STATUSEOF
    chmod +x /usr/local/bin/rw-node-status
    chmod +x /usr/local/bin/rw-node-status
    
    # 容器/无systemd环境：创建启动/停止脚本
    if [[ "$HAS_SYSTEMD" != "true" || "$IS_CONTAINER" == "true" ]]; then
        # rw-node-start
        cat > /usr/local/bin/rw-node-start << EOF
#!/bin/bash
cd ${INSTALL_DIR}
exec ${INSTALL_DIR}/start.sh
EOF
        chmod +x /usr/local/bin/rw-node-start
        
        # rw-node-stop
        cat > /usr/local/bin/rw-node-stop << 'EOF'
#!/bin/bash
echo "停止 RW-Node..."
pkill -f "node dist/src/main" 2>/dev/null || true
pkill -f supervisord 2>/dev/null || true
pkill -f rw-core 2>/dev/null || true
rm -f /run/supervisord*.sock /run/remnawave-internal*.sock /var/run/supervisord*.pid /tmp/supervisord.conf
echo "已停止"
EOF
        chmod +x /usr/local/bin/rw-node-stop
    fi
    
    print_success "辅助脚本创建完成"
}

#######################################
# 启动服务
#######################################
start_service() {
    print_step "启动服务..."
    
    if [[ "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        # Systemd 环境
        systemctl enable rw-node
        systemctl start rw-node
        
        sleep 3
        
        if systemctl is-active --quiet rw-node; then
            print_success "服务启动成功"
        else
            print_error "服务启动失败，请查看日志: journalctl -u rw-node -f"
            exit 1
        fi
    else
        # 容器或无 systemd 环境
        print_warning "无 Systemd 或容器环境，不自动启动服务"
        print_info "请手动运行: rw-node-start 或 ${INSTALL_DIR}/start.sh"
    fi
}

#######################################
# 打印完成信息
#######################################
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
        echo -e "${YELLOW}提示: 容器/无systemd环境下请使用 screen/tmux 或进程管理器运行${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}日志查看:${NC}"
    echo "  xlogs / xerrors"
    echo ""
    echo -e "${CYAN}配置文件:${NC} $INSTALL_DIR/.env"
    echo ""
}

#######################################
# 解析参数
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --with-cloudflared) WITH_CLOUDFLARED=true; shift ;;
            --cloudflared-token) CLOUDFLARED_TOKEN="$2"; WITH_CLOUDFLARED=true; shift 2 ;;
            --version|-v) INSTALL_VERSION="$2"; shift 2 ;;
            --port|-p) NODE_PORT="$2"; shift 2 ;;
            --secret-key|-k) SECRET_KEY="$2"; shift 2 ;;
            --xray-version) XRAY_VERSION="$2"; shift 2 ;;
            --help|-h)
                echo "用法: $0 [选项]"
                echo "  --version, -v <版本>       指定版本"
                echo "  --port, -p <端口>          节点端口 (默认: 2222)"
                echo "  --secret-key, -k <密钥>    面板密钥"
                echo "  --with-cloudflared         安装 Cloudflare Tunnel"
                echo "  --cloudflared-token <令牌> Cloudflare Tunnel Token"
                exit 0 ;;
            *) print_error "未知参数: $1"; exit 1 ;;
        esac
    done
}

#######################################
# 主函数
#######################################
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
    download_configs
    configure_env
    install_cloudflared
    create_helper_scripts
    start_service
    print_completion
}

main "$@"
