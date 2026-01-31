#!/bin/bash

set -e

#######################################
# RW-Node 更新脚本
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/rw-node"
GITHUB_REPO="x-dora/rw-node"
GITHUB_RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main"
UPSTREAM_REPO="remnawave/node"

TARGET_VERSION=""
FORCE=false

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && { print_error "需要 root 权限"; exit 1; }
}

check_installation() {
    [[ ! -d "$INSTALL_DIR" ]] && { print_error "RW-Node 未安装"; exit 1; }
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) print_error "不支持的架构: $arch"; exit 1 ;;
    esac
}

get_current_version() {
    [[ -f "$INSTALL_DIR/package.json" ]] && grep '"version"' "$INSTALL_DIR/package.json" | head -1 | cut -d'"' -f4 || echo "unknown"
}

get_latest_version() {
    local version=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [[ -z "$version" ]] && version=$(curl -fsSL "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    echo "$version"
}

backup_config() {
    print_step "备份配置..."
    [[ -f "$INSTALL_DIR/.env" ]] && cp "$INSTALL_DIR/.env" /tmp/rw-node-env.backup
    print_success "配置已备份"
}

restore_config() {
    [[ -f /tmp/rw-node-env.backup ]] && {
        cp /tmp/rw-node-env.backup "$INSTALL_DIR/.env"
        rm -f /tmp/rw-node-env.backup
        print_success "配置已恢复"
    }
}

update_rw_node() {
    local version=$1
    local arch=$(detect_arch)
    
    print_step "下载版本: $version"
    
    local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/rw-node-${version}-linux-${arch}.tar.gz"
    
    if curl -fsSL "$url" -o /tmp/rw-node-update.tar.gz; then
        # 备份旧文件
        rm -rf /tmp/rw-node-old
        mkdir -p /tmp/rw-node-old
        mv $INSTALL_DIR/dist /tmp/rw-node-old/ 2>/dev/null || true
        mv $INSTALL_DIR/libs /tmp/rw-node-old/ 2>/dev/null || true
        mv $INSTALL_DIR/node_modules /tmp/rw-node-old/ 2>/dev/null || true
        
        # 解压新文件
        tar -xzf /tmp/rw-node-update.tar.gz -C $INSTALL_DIR
        rm -f /tmp/rw-node-update.tar.gz
        rm -rf /tmp/rw-node-old
        
        print_success "更新完成"
    else
        print_error "下载失败"
        exit 1
    fi
}

update_scripts() {
    print_step "更新脚本..."
    
    curl -fsSL "${GITHUB_RAW_URL}/config/start.sh" -o $INSTALL_DIR/start.sh
    chmod +x $INSTALL_DIR/start.sh
    
    curl -fsSL "${GITHUB_RAW_URL}/config/systemd/rw-node.service" -o /etc/systemd/system/rw-node.service
    systemctl daemon-reload
    
    print_success "脚本更新完成"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version|-v) TARGET_VERSION="$2"; shift 2 ;;
            --force|-f) FORCE=true; shift ;;
            --help|-h)
                echo "用法: $0 [选项]"
                echo "  --version, -v <版本>  指定版本"
                echo "  --force, -f           强制更新"
                exit 0 ;;
            *) print_error "未知参数: $1"; exit 1 ;;
        esac
    done
}

main() {
    echo -e "${CYAN}=========================================="
    echo "  RW-Node 更新脚本"
    echo "==========================================${NC}"
    
    parse_args "$@"
    check_root
    check_installation
    
    local current=$(get_current_version)
    local target="${TARGET_VERSION:-$(get_latest_version)}"
    
    print_info "当前版本: $current"
    print_info "目标版本: $target"
    
    if [[ "$current" == "$target" ]] && [[ "$FORCE" != "true" ]]; then
        print_success "已是最新版本"
        exit 0
    fi
    
    read -p "继续更新? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && exit 0
    
    print_step "停止服务..."
    systemctl stop rw-node
    
    backup_config
    update_rw_node "$target"
    restore_config
    update_scripts
    
    print_step "重启服务..."
    systemctl start rw-node
    
    sleep 3
    systemctl is-active --quiet rw-node && print_success "更新完成！" || print_error "服务启动失败"
}

main "$@"
