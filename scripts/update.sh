#!/bin/bash

set -e

#######################################
# RW-Node 更新脚本
#######################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/rw-node"
GITHUB_REPO="x-dora/rw-node"
UPSTREAM_REPO="remnawave/node"

# 参数
TARGET_VERSION=""
FORCE=false

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
    echo -e "${CYAN}[STEP]${NC} $1"
}

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
# 检查安装
#######################################
check_installation() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        print_error "RW-Node 未安装"
        print_info "请先运行安装脚本:"
        print_info "  bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh)"
        exit 1
    fi
}

#######################################
# 获取当前版本
#######################################
get_current_version() {
    if [[ -f "$INSTALL_DIR/package.json" ]]; then
        grep '"version"' "$INSTALL_DIR/package.json" | head -1 | cut -d'"' -f4
    else
        echo "unknown"
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
# 备份配置
#######################################
backup_config() {
    print_step "备份配置..."
    
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        cp "$INSTALL_DIR/.env" /tmp/rw-node-env.backup
        print_success "配置已备份"
    fi
}

#######################################
# 恢复配置
#######################################
restore_config() {
    if [[ -f /tmp/rw-node-env.backup ]]; then
        cp /tmp/rw-node-env.backup "$INSTALL_DIR/.env"
        rm -f /tmp/rw-node-env.backup
        print_success "配置已恢复"
    fi
}

#######################################
# 更新 RW-Node
#######################################
update_rw_node() {
    local version=$1
    local arch=$(detect_arch)
    
    print_step "下载新版本: $version"
    
    cd $INSTALL_DIR
    
    # 下载预编译包
    local download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/rw-node-${version}-linux-${arch}.tar.gz"
    
    if curl -fsSL -o /tmp/rw-node-update.tar.gz "$download_url"; then
        # 备份旧文件
        rm -rf /tmp/rw-node-old
        mkdir -p /tmp/rw-node-old
        mv dist /tmp/rw-node-old/ 2>/dev/null || true
        mv libs /tmp/rw-node-old/ 2>/dev/null || true
        
        # 解压新文件
        tar -xzf /tmp/rw-node-update.tar.gz
        rm -f /tmp/rw-node-update.tar.gz
        
        # 更新依赖
        npm ci --omit=dev --legacy-peer-deps
        
        # 清理
        rm -rf /tmp/rw-node-old
        
        print_success "更新完成"
    else
        print_warning "预编译包不存在，尝试从源码构建..."
        build_from_source "$version"
    fi
}

#######################################
# 从源码构建
#######################################
build_from_source() {
    local version=$1
    
    print_step "从源码构建..."
    
    cd /tmp
    rm -rf node-build
    
    git clone --depth 1 --branch "$version" "https://github.com/${UPSTREAM_REPO}.git" node-build || \
    git clone --depth 1 "https://github.com/${UPSTREAM_REPO}.git" node-build
    
    cd node-build
    npm ci --legacy-peer-deps
    npm run build
    
    # 备份旧文件
    rm -rf /tmp/rw-node-old
    mkdir -p /tmp/rw-node-old
    mv $INSTALL_DIR/dist /tmp/rw-node-old/ 2>/dev/null || true
    mv $INSTALL_DIR/libs /tmp/rw-node-old/ 2>/dev/null || true
    
    # 复制新文件
    cp -r dist $INSTALL_DIR/
    cp -r libs $INSTALL_DIR/
    cp package*.json $INSTALL_DIR/
    
    # 更新依赖
    cd $INSTALL_DIR
    npm ci --omit=dev --legacy-peer-deps
    
    # 清理
    rm -rf /tmp/node-build
    rm -rf /tmp/rw-node-old
    
    print_success "源码构建完成"
}

#######################################
# 更新启动脚本
#######################################
update_start_script() {
    print_step "更新启动脚本..."
    
    # 下载最新的启动脚本
    local script_url="https://raw.githubusercontent.com/${GITHUB_REPO}/main/config/start.sh"
    
    if curl -fsSL -o /tmp/start.sh "$script_url"; then
        cp /tmp/start.sh $INSTALL_DIR/start.sh
        chmod +x $INSTALL_DIR/start.sh
        rm -f /tmp/start.sh
        print_success "启动脚本更新完成"
    else
        print_warning "无法下载最新启动脚本，保留现有版本"
    fi
}

#######################################
# 更新 Xray-core (可选)
#######################################
update_xray() {
    read -p "是否更新 Xray-core? [y/N]: " update_xray
    if [[ "$update_xray" =~ ^[Yy]$ ]]; then
        print_step "更新 Xray-core..."
        
        local xray_install_script="https://raw.githubusercontent.com/remnawave/scripts/main/scripts/install-xray.sh"
        curl -L $xray_install_script | bash -s -- "" XTLS
        
        print_success "Xray-core 更新完成"
    fi
}

#######################################
# 重启服务
#######################################
restart_service() {
    print_step "重启服务..."
    
    systemctl restart rw-node
    
    sleep 3
    
    if systemctl is-active --quiet rw-node; then
        print_success "服务重启成功"
    else
        print_error "服务重启失败"
        print_info "查看日志: journalctl -u rw-node -f"
        exit 1
    fi
}

#######################################
# 解析参数
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version|-v)
                TARGET_VERSION="$2"
                shift 2
                ;;
            --force|-f)
                FORCE=true
                shift
                ;;
            --help|-h)
                echo "RW-Node 更新脚本"
                echo ""
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --version, -v <版本>  指定更新到的版本"
                echo "  --force, -f           强制更新（即使版本相同）"
                echo "  --help, -h            显示帮助"
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
    echo "  RW-Node 更新脚本"
    echo "=========================================="
    echo -e "${NC}"
    
    parse_args "$@"
    
    check_root
    check_installation
    
    local current_version=$(get_current_version)
    local target_version="${TARGET_VERSION:-$(get_latest_version)}"
    
    print_info "当前版本: $current_version"
    print_info "目标版本: $target_version"
    
    # 版本比较
    if [[ "$current_version" == "$target_version" ]] && [[ "$FORCE" != "true" ]]; then
        print_success "已是最新版本，无需更新"
        exit 0
    fi
    
    echo ""
    read -p "是否继续更新? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "更新已取消"
        exit 0
    fi
    
    # 停止服务
    print_step "停止服务..."
    systemctl stop rw-node
    
    backup_config
    update_rw_node "$target_version"
    restore_config
    update_start_script
    update_xray
    restart_service
    
    echo ""
    echo -e "${GREEN}"
    echo "=========================================="
    echo "  更新完成!"
    echo "=========================================="
    echo -e "${NC}"
    echo ""
    echo "新版本: $target_version"
    echo ""
}

main "$@"
