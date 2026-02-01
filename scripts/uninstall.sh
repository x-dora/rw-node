#!/bin/bash

#######################################
# RW-Node 卸载脚本
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 支持自定义工作目录
INSTALL_DIR="${RW_NODE_DIR:-/opt/rw-node}"

print_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "需要 root 权限"
        exit 1
    fi
}

confirm_uninstall() {
    echo -e "${YELLOW}"
    echo -e "=========================================="
    echo -e "  警告: 即将卸载 RW-Node"
    echo -e "=========================================="
    echo -e "${NC}"
    echo -e "将删除:"
    echo -e "  - 安装目录: $INSTALL_DIR"
    echo -e "  - Systemd 服务"
    echo -e "  - 符号链接"
    echo -e ""
    
    read -p "继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "已取消"
        exit 0
    fi
}

stop_services() {
    print_info "停止服务..."
    systemctl stop rw-node 2>/dev/null || true
    systemctl stop cloudflared 2>/dev/null || true
    pkill -f supervisord 2>/dev/null || true
    pkill -f rw-core 2>/dev/null || true
    pkill -f "node dist/src/main" 2>/dev/null || true
}

remove_services() {
    print_info "删除服务..."
    
    systemctl disable rw-node 2>/dev/null || true
    rm -f /etc/systemd/system/rw-node.service
    
    systemctl disable cloudflared 2>/dev/null || true
    rm -f /etc/systemd/system/cloudflared.service
    
    systemctl daemon-reload
    print_success "服务已删除"
}

remove_files() {
    print_info "删除文件..."
    
    # 删除安装目录（包含所有二进制、配置、日志）
    rm -rf "$INSTALL_DIR"
    print_success "安装目录已删除"
    
    # 删除符号链接
    rm -f /usr/local/bin/xlogs
    rm -f /usr/local/bin/xerrors
    rm -f /usr/local/bin/rw-node-status
    rm -f /usr/local/bin/rw-node-start
    rm -f /usr/local/bin/rw-node-stop
    rm -f /usr/local/bin/node
    rm -f /usr/local/bin/npm
    rm -f /usr/local/bin/npx
    
    # 兼容旧版：清理可能存在的系统目录
    rm -f /usr/local/bin/xray /usr/local/bin/rw-core /usr/local/bin/supervisord /usr/local/bin/cloudflared 2>/dev/null || true
    rm -f /run/supervisord*.sock /run/remnawave-internal*.sock /var/run/supervisord*.pid /tmp/supervisord.conf 2>/dev/null || true
    rm -rf /var/log/supervisor 2>/dev/null || true
    
    print_success "文件已删除"
}

main() {
    echo -e "${CYAN}=========================================="
    echo -e "  RW-Node 卸载脚本"
    echo -e "==========================================${NC}"
    
    check_root
    confirm_uninstall
    stop_services
    remove_services
    remove_files
    
    echo -e ""
    echo -e "${GREEN}=========================================="
    echo -e "  卸载完成!"
    echo -e "==========================================${NC}"
}

main "$@"
