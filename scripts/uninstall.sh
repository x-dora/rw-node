#!/bin/bash

set -e

#######################################
# RW-Node 卸载脚本
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/rw-node"
LOG_DIR="/var/log/supervisor"

print_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}[ERROR]${NC} 需要 root 权限"; exit 1; }
}

confirm_uninstall() {
    echo -e "${YELLOW}"
    echo "=========================================="
    echo "  警告: 即将卸载 RW-Node"
    echo "=========================================="
    echo -e "${NC}"
    echo "将删除:"
    echo "  - 安装目录: $INSTALL_DIR"
    echo "  - 日志目录: $LOG_DIR"
    echo "  - Systemd 服务"
    echo "  - Xray-core, Supervisord"
    echo ""
    
    read -p "继续? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
}

stop_services() {
    print_info "停止服务..."
    systemctl stop rw-node 2>/dev/null || true
    systemctl stop cloudflared 2>/dev/null || true
    pkill -f supervisord 2>/dev/null || true
    pkill -f rw-core 2>/dev/null || true
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
    
    # 安装目录
    rm -rf "$INSTALL_DIR"
    print_success "安装目录已删除"
    
    # 日志目录
    rm -rf "$LOG_DIR"
    
    # 二进制文件
    rm -f /usr/local/bin/xray
    rm -f /usr/local/bin/rw-core
    rm -f /usr/local/bin/supervisord
    rm -f /usr/local/bin/cloudflared
    rm -f /usr/local/bin/xlogs
    rm -f /usr/local/bin/xerrors
    rm -f /usr/local/bin/rw-node-status
    
    # Node.js 符号链接
    [[ -L /usr/local/bin/node ]] && rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx
    
    # 运行时文件
    rm -f /run/supervisord.sock /run/supervisord.pid /run/remnawave-internal.sock /tmp/supervisord.conf
    
    print_success "文件已删除"
}

main() {
    echo -e "${CYAN}=========================================="
    echo "  RW-Node 卸载脚本"
    echo "==========================================${NC}"
    
    check_root
    confirm_uninstall
    stop_services
    remove_services
    remove_files
    
    echo ""
    echo -e "${GREEN}=========================================="
    echo "  卸载完成!"
    echo "==========================================${NC}"
}

main "$@"
