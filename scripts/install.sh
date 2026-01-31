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
NC='\033[0m' # No Color

# 配置变量
INSTALL_DIR="/opt/rw-node"
LOG_DIR="/var/log/supervisor"
GITHUB_REPO="x-dora/rw-node"
UPSTREAM_REPO="remnawave/node"
XRAY_INSTALL_SCRIPT="https://raw.githubusercontent.com/remnawave/scripts/main/scripts/install-xray.sh"
DEFAULT_XRAY_VERSION="v25.12.8"
DEFAULT_NODE_VERSION="20"

# 参数默认值
WITH_CLOUDFLARED=false
CLOUDFLARED_TOKEN=""
INSTALL_VERSION=""
NODE_PORT="2222"
SECRET_KEY=""
XTLS_API_PORT="61000"

#######################################
# 打印带颜色的信息
#######################################
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
}

#######################################
# 检查是否为 root 用户
#######################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用 sudo bash $0 或切换到 root 用户"
        exit 1
    fi
}

#######################################
# 检测系统架构
#######################################
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            print_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

#######################################
# 检测操作系统
#######################################
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # 使用子 shell 避免污染当前环境变量
        OS=$(. /etc/os-release && echo "$ID")
        OS_VERSION=$(. /etc/os-release && echo "$VERSION_ID")
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
        OS_VERSION=""
    else
        print_error "无法检测操作系统"
        exit 1
    fi
    
    case $OS in
        ubuntu|debian|centos|rhel|fedora|almalinux|rocky)
            print_info "检测到操作系统: $OS $OS_VERSION"
            ;;
        *)
            print_warning "未经测试的操作系统: $OS，将尝试继续安装"
            ;;
    esac
}

#######################################
# 安装系统依赖
#######################################
install_dependencies() {
    print_step "安装系统依赖..."
    
    case $OS in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq curl wget unzip git python3 python3-pip python3-venv
            ;;
        centos|rhel|almalinux|rocky)
            if command -v dnf &> /dev/null; then
                dnf install -y -q curl wget unzip git python3 python3-pip
            else
                yum install -y -q curl wget unzip git python3 python3-pip
            fi
            ;;
        fedora)
            dnf install -y -q curl wget unzip git python3 python3-pip
            ;;
        *)
            print_warning "请手动安装: curl wget unzip git python3 python3-pip"
            ;;
    esac
    
    print_success "系统依赖安装完成"
}

#######################################
# 安装 Node.js
#######################################
install_nodejs() {
    print_step "检查 Node.js..."
    
    if command -v node &> /dev/null; then
        local node_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [[ $node_version -ge 20 ]]; then
            print_info "Node.js $(node -v) 已安装"
            return 0
        else
            print_warning "Node.js 版本过低，需要 v20+，当前版本: $(node -v)"
        fi
    fi
    
    print_info "安装 Node.js v${DEFAULT_NODE_VERSION}..."
    
    # 使用 NodeSource 安装
    case $OS in
        ubuntu|debian)
            curl -fsSL https://deb.nodesource.com/setup_${DEFAULT_NODE_VERSION}.x | bash -
            apt-get install -y -qq nodejs
            ;;
        centos|rhel|almalinux|rocky|fedora)
            curl -fsSL https://rpm.nodesource.com/setup_${DEFAULT_NODE_VERSION}.x | bash -
            if command -v dnf &> /dev/null; then
                dnf install -y -q nodejs
            else
                yum install -y -q nodejs
            fi
            ;;
        *)
            # 使用 n 版本管理器作为后备方案
            curl -fsSL https://raw.githubusercontent.com/tj/n/master/bin/n | bash -s lts
            ;;
    esac
    
    print_success "Node.js $(node -v) 安装完成"
}

#######################################
# 安装 Supervisord
#######################################
install_supervisord() {
    print_step "安装 Supervisord..."
    
    # 使用 pip 安装最新版 supervisord（与原项目保持一致）
    pip3 install --break-system-packages git+https://github.com/Supervisor/supervisor.git@4bf1e57cbf292ce988dc128e0d2c8917f18da9be 2>/dev/null || \
    pip3 install git+https://github.com/Supervisor/supervisor.git@4bf1e57cbf292ce988dc128e0d2c8917f18da9be
    
    # 创建日志目录
    mkdir -p $LOG_DIR
    
    print_success "Supervisord 安装完成"
}

#######################################
# 安装 Xray-core
#######################################
install_xray() {
    print_step "安装 Xray-core..."
    
    local xray_version=${XRAY_VERSION:-$DEFAULT_XRAY_VERSION}
    
    curl -L $XRAY_INSTALL_SCRIPT | bash -s -- $xray_version XTLS
    
    # 创建软链接
    if [[ -f /usr/local/bin/xray ]]; then
        ln -sf /usr/local/bin/xray /usr/local/bin/rw-core
        print_success "Xray-core 安装完成"
    else
        print_error "Xray-core 安装失败"
        exit 1
    fi
}

#######################################
# 获取最新版本
#######################################
get_latest_version() {
    local latest=""
    local api_response=""
    
    # 首先尝试从本仓库获取
    api_response=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null)
    if [[ -n "$api_response" ]]; then
        # 使用 sed 提取 tag_name 的值
        latest=$(echo "$api_response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
    
    # 如果本仓库没有发布，则获取上游版本
    if [[ -z "$latest" ]]; then
        api_response=$(curl -fsSL "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" 2>/dev/null)
        if [[ -n "$api_response" ]]; then
            latest=$(echo "$api_response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        fi
    fi
    
    echo "$latest"
}

#######################################
# 下载并安装 RW-Node
#######################################
install_rw_node() {
    print_step "安装 RW-Node..."
    
    local arch=$(detect_arch)
    local version="${INSTALL_VERSION}"
    
    if [[ -z "$version" ]]; then
        version=$(get_latest_version)
        if [[ -z "$version" ]]; then
            print_error "无法获取最新版本"
            exit 1
        fi
    fi
    
    print_info "安装版本: $version"
    
    # 创建安装目录
    mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR
    
    # 下载预编译包
    local download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/rw-node-${version}-linux-${arch}.tar.gz"
    
    print_info "下载地址: $download_url"
    
    if ! curl -fsSL -o rw-node.tar.gz "$download_url"; then
        print_warning "预编译包不存在，尝试从源码构建..."
        build_from_source "$version"
        return
    fi
    
    # 解压
    tar -xzf rw-node.tar.gz
    rm -f rw-node.tar.gz
    
    # 安装依赖
    npm ci --omit=dev --legacy-peer-deps
    
    print_success "RW-Node 安装完成"
}

#######################################
# 从源码构建
#######################################
build_from_source() {
    local version=$1
    
    print_step "从源码构建 RW-Node..."
    
    cd /tmp
    rm -rf node-build
    
    # 克隆源码
    git clone --depth 1 --branch "$version" "https://github.com/${UPSTREAM_REPO}.git" node-build || \
    git clone --depth 1 "https://github.com/${UPSTREAM_REPO}.git" node-build
    
    cd node-build
    
    # 安装依赖并构建
    npm ci --legacy-peer-deps
    npm run build
    
    # 复制文件到安装目录
    mkdir -p $INSTALL_DIR
    cp -r dist $INSTALL_DIR/
    cp -r libs $INSTALL_DIR/
    cp package*.json $INSTALL_DIR/
    
    # 安装生产依赖
    cd $INSTALL_DIR
    npm ci --omit=dev --legacy-peer-deps
    
    # 清理
    rm -rf /tmp/node-build
    
    print_success "源码构建完成"
}

#######################################
# 配置 Supervisord
#######################################
configure_supervisord() {
    print_step "配置 Supervisord..."
    
    cat > /etc/supervisord.conf << 'EOF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor
logfile_maxbytes=5MB
logfile_backups=2
loglevel=info
silent=true

[unix_http_server]
file = /run/supervisord.sock
username = %(ENV_SUPERVISORD_USER)s
password = %(ENV_SUPERVISORD_PASSWORD)s

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[program:xray]
command=/usr/local/bin/rw-core -config http+unix:///run/remnawave-internal.sock/internal/get-config?token=%(ENV_INTERNAL_REST_TOKEN)s -format json
autostart=false
autorestart=false
stderr_logfile=/var/log/supervisor/xray.err.log
stdout_logfile=/var/log/supervisor/xray.out.log
stdout_logfile_maxbytes=5MB
stderr_logfile_maxbytes=5MB
stdout_logfile_backups=0
stderr_logfile_backups=0
EOF
    
    print_success "Supervisord 配置完成"
}

#######################################
# 配置环境变量
#######################################
configure_env() {
    print_step "配置环境变量..."
    
    # 如果没有提供 SECRET_KEY，提示用户输入
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
# 创建启动脚本
#######################################
create_start_script() {
    print_step "创建启动脚本..."
    
    cat > $INSTALL_DIR/start.sh << 'STARTEOF'
#!/bin/bash

#######################################
# RW-Node 启动脚本
# 与 Docker entrypoint 保持一致的启动逻辑
#######################################

set -e

echo "[Entrypoint] Starting entrypoint script..."

# 生成随机凭据的函数
generate_random() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 64
}

# 生成运行时凭据
SUPERVISORD_USER=$(generate_random)
SUPERVISORD_PASSWORD=$(generate_random)
INTERNAL_REST_TOKEN=$(generate_random)

export SUPERVISORD_USER
export SUPERVISORD_PASSWORD
export INTERNAL_REST_TOKEN

echo "[Credentials] OK"

# 清理旧的 socket 文件
rm -f /run/supervisord.sock
rm -f /run/remnawave-internal.sock
rm -f /run/supervisord.pid

# 启动 supervisord（后台运行）
supervisord -c /etc/supervisord.conf &
echo "[Entrypoint] Supervisord started successfully"

# 等待 supervisord 就绪
sleep 1

# 获取 Xray 版本
echo "[Entrypoint] Getting Xray version..."
XRAY_CORE_VERSION=$(/usr/local/bin/rw-core version | head -n 1)
export XRAY_CORE_VERSION
echo "[Entrypoint] Xray version: $XRAY_CORE_VERSION"
echo "[Ports] XTLS_API_PORT: $XTLS_API_PORT"

# 加载环境变量
if [[ -f /opt/rw-node/.env ]]; then
    set -a
    source /opt/rw-node/.env
    set +a
fi

# 启动 Node.js 应用
echo "[Entrypoint] Starting Node.js application..."
cd /opt/rw-node
exec node dist/src/main
STARTEOF
    
    chmod +x $INSTALL_DIR/start.sh
    
    print_success "启动脚本创建完成"
}

#######################################
# 创建 Systemd 服务
#######################################
create_systemd_service() {
    print_step "创建 Systemd 服务..."
    
    cat > /etc/systemd/system/rw-node.service << EOF
[Unit]
Description=Remnawave Node Service
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-http-header-size=65536

# 使用启动脚本来正确设置环境变量和启动顺序
ExecStart=${INSTALL_DIR}/start.sh

Restart=on-failure
RestartSec=10
TimeoutStopSec=30

# 清理 socket 文件
ExecStopPost=/bin/bash -c 'rm -f /run/supervisord.sock /run/remnawave-internal.sock /run/supervisord.pid'

# 日志
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rw-node

[Install]
WantedBy=multi-user.target
EOF
    
    # 重新加载 systemd
    systemctl daemon-reload
    
    print_success "Systemd 服务创建完成"
}

#######################################
# 安装 Cloudflare Tunnel
#######################################
install_cloudflared() {
    if [[ "$WITH_CLOUDFLARED" != "true" ]]; then
        return 0
    fi
    
    print_step "安装 Cloudflare Tunnel..."
    
    local arch=$(detect_arch)
    local cloudflared_url=""
    
    case $arch in
        amd64)
            cloudflared_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        arm64)
            cloudflared_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
    esac
    
    curl -fsSL -o /usr/local/bin/cloudflared "$cloudflared_url"
    chmod +x /usr/local/bin/cloudflared
    
    # 创建 Cloudflare Tunnel 服务
    cat > /etc/systemd/system/cloudflared.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${CLOUDFLARED_TOKEN}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    
    if [[ -n "$CLOUDFLARED_TOKEN" ]]; then
        systemctl enable cloudflared
        print_success "Cloudflare Tunnel 安装完成并已启用"
    else
        print_warning "Cloudflare Tunnel 已安装，但未配置 Token"
        print_info "请编辑 /etc/systemd/system/cloudflared.service 添加 Token"
        print_info "或运行: cloudflared service install <TOKEN>"
    fi
}

#######################################
# 创建辅助脚本
#######################################
create_helper_scripts() {
    print_step "创建辅助脚本..."
    
    # xlogs - 查看 Xray 日志
    cat > /usr/local/bin/xlogs << 'EOF'
#!/bin/bash
tail -n +1 -f /var/log/supervisor/xray.out.log
EOF
    chmod +x /usr/local/bin/xlogs
    
    # xerrors - 查看 Xray 错误日志
    cat > /usr/local/bin/xerrors << 'EOF'
#!/bin/bash
tail -n +1 -f /var/log/supervisor/xray.err.log
EOF
    chmod +x /usr/local/bin/xerrors
    
    # rw-node-status - 查看状态
    cat > /usr/local/bin/rw-node-status << 'EOF'
#!/bin/bash
echo "=== RW-Node 状态 ==="
systemctl status rw-node --no-pager
echo ""
echo "=== Xray 版本 ==="
/usr/local/bin/rw-core version
echo ""
echo "=== 端口监听 ==="
ss -tlnp | grep -E "(node|xray)" || netstat -tlnp | grep -E "(node|xray)"
EOF
    chmod +x /usr/local/bin/rw-node-status
    
    print_success "辅助脚本创建完成"
}

#######################################
# 启动服务
#######################################
start_service() {
    print_step "启动服务..."
    
    systemctl enable rw-node
    systemctl start rw-node
    
    sleep 3
    
    if systemctl is-active --quiet rw-node; then
        print_success "RW-Node 服务启动成功"
    else
        print_error "RW-Node 服务启动失败"
        print_info "请查看日志: journalctl -u rw-node -f"
        exit 1
    fi
}

#######################################
# 打印安装完成信息
#######################################
print_completion() {
    echo ""
    echo -e "${GREEN}"
    echo "=========================================="
    echo "  RW-Node 安装完成!"
    echo "=========================================="
    echo -e "${NC}"
    echo ""
    echo -e "${CYAN}服务管理命令:${NC}"
    echo "  启动: systemctl start rw-node"
    echo "  停止: systemctl stop rw-node"
    echo "  重启: systemctl restart rw-node"
    echo "  状态: systemctl status rw-node"
    echo ""
    echo -e "${CYAN}日志查看:${NC}"
    echo "  服务日志: journalctl -u rw-node -f"
    echo "  Xray 日志: xlogs"
    echo "  Xray 错误: xerrors"
    echo "  综合状态: rw-node-status"
    echo ""
    echo -e "${CYAN}配置文件:${NC}"
    echo "  环境配置: $INSTALL_DIR/.env"
    echo "  Supervisord: /etc/supervisord.conf"
    echo ""
    
    if [[ "$WITH_CLOUDFLARED" == "true" ]]; then
        echo -e "${CYAN}Cloudflare Tunnel:${NC}"
        echo "  启动: systemctl start cloudflared"
        echo "  状态: systemctl status cloudflared"
        echo ""
    fi
    
    echo -e "${YELLOW}重要提示:${NC}"
    echo "  请确保防火墙已开放端口: $NODE_PORT"
    echo ""
}

#######################################
# 解析参数
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --with-cloudflared)
                WITH_CLOUDFLARED=true
                shift
                ;;
            --cloudflared-token)
                CLOUDFLARED_TOKEN="$2"
                WITH_CLOUDFLARED=true
                shift 2
                ;;
            --version|-v)
                INSTALL_VERSION="$2"
                shift 2
                ;;
            --port|-p)
                NODE_PORT="$2"
                shift 2
                ;;
            --secret-key|-k)
                SECRET_KEY="$2"
                shift 2
                ;;
            --xray-version)
                XRAY_VERSION="$2"
                shift 2
                ;;
            --help|-h)
                echo "RW-Node 一键安装脚本"
                echo ""
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --version, -v <版本>       指定安装版本 (例如: v2.5.2)"
                echo "  --port, -p <端口>          节点端口 (默认: 2222)"
                echo "  --secret-key, -k <密钥>    面板密钥"
                echo "  --xray-version <版本>      Xray-core 版本 (默认: $DEFAULT_XRAY_VERSION)"
                echo "  --with-cloudflared         安装 Cloudflare Tunnel"
                echo "  --cloudflared-token <令牌> Cloudflare Tunnel Token"
                echo "  --help, -h                 显示帮助信息"
                echo ""
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                exit 1
                ;;
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
    echo "  https://github.com/x-dora/rw-node"
    echo "=========================================="
    echo -e "${NC}"
    
    parse_args "$@"
    
    check_root
    detect_os
    install_dependencies
    install_nodejs
    install_supervisord
    install_xray
    install_rw_node
    configure_supervisord
    configure_env
    create_start_script
    create_systemd_service
    install_cloudflared
    create_helper_scripts
    start_service
    print_completion
}

main "$@"
