#!/bin/bash

set -e

#######################################
# RW-Node 卸载脚本
#######################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/rw-node"
LOG_DIR="/var/log/supervisor"

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
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
# 确认卸载
#######################################
confirm_uninstall() {
    echo -e "${YELLOW}"
    echo "=========================================="
    echo "  警告: 即将卸载 RW-Node"
    echo "=========================================="
    echo -e "${NC}"
    echo ""
    echo "将删除以下内容:"
    echo "  - RW-Node 服务"
    echo "  - 安装目录: $INSTALL_DIR"
    echo "  - 日志目录: $LOG_DIR"
    echo "  - Xray-core"
    echo "  - 辅助脚本"
    echo ""
    
    read -p "是否继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "卸载已取消"
        exit 0
    fi
}

#######################################
# 停止服务
#######################################
stop_services() {
    print_info "停止服务..."
    
    # 停止 RW-Node 服务
    if systemctl is-active --quiet rw-node 2>/dev/null; then
        systemctl stop rw-node
        print_success "RW-Node 服务已停止"
    fi
    
    # 停止 Cloudflared 服务
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        systemctl stop cloudflared
        print_success "Cloudflared 服务已停止"
    fi
    
    # 停止 supervisord 进程
    pkill -f supervisord 2>/dev/null || true
    pkill -f "rw-core" 2>/dev/null || true
}

#######################################
# 禁用并删除服务
#######################################
remove_services() {
    print_info "删除 Systemd 服务..."
    
    # RW-Node 服务
    if [[ -f /etc/systemd/system/rw-node.service ]]; then
        systemctl disable rw-node 2>/dev/null || true
        rm -f /etc/systemd/system/rw-node.service
        print_success "RW-Node 服务已删除"
    fi
    
    # Cloudflared 服务
    if [[ -f /etc/systemd/system/cloudflared.service ]]; then
        systemctl disable cloudflared 2>/dev/null || true
        rm -f /etc/systemd/system/cloudflared.service
        print_success "Cloudflared 服务已删除"
    fi
    
    systemctl daemon-reload
}

#######################################
# 删除安装文件
#######################################
remove_files() {
    print_info "删除安装文件..."
    
    # 安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        print_success "安装目录已删除: $INSTALL_DIR"
    fi
    
    # 日志目录
    if [[ -d "$LOG_DIR" ]]; then
        rm -rf "$LOG_DIR"
        print_success "日志目录已删除: $LOG_DIR"
    fi
    
    # Xray-core
    if [[ -f /usr/local/bin/xray ]]; then
        rm -f /usr/local/bin/xray
        rm -f /usr/local/bin/rw-core
        print_success "Xray-core 已删除"
    fi
    
    # Cloudflared
    if [[ -f /usr/local/bin/cloudflared ]]; then
        rm -f /usr/local/bin/cloudflared
        print_success "Cloudflared 已删除"
    fi
    
    # 辅助脚本
    rm -f /usr/local/bin/xlogs
    rm -f /usr/local/bin/xerrors
    rm -f /usr/local/bin/rw-node-status
    print_success "辅助脚本已删除"
    
    # Supervisord 配置
    if [[ -f /etc/supervisord.conf ]]; then
        rm -f /etc/supervisord.conf
        print_success "Supervisord 配置已删除"
    fi
    
    # 运行时文件
    rm -f /run/supervisord.sock
    rm -f /run/supervisord.pid
    rm -f /run/remnawave-internal.sock
}

#######################################
# 询问是否保留配置
#######################################
ask_keep_config() {
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        read -p "是否保留配置文件 (.env)? [Y/n]: " keep_config
        if [[ "$keep_config" =~ ^[Nn]$ ]]; then
            return 1
        fi
        
        # 备份配置
        cp "$INSTALL_DIR/.env" /tmp/rw-node-env.backup
        print_info "配置文件已备份到: /tmp/rw-node-env.backup"
        return 0
    fi
    return 1
}

#######################################
# 完成信息
#######################################
print_completion() {
    echo ""
    echo -e "${GREEN}"
    echo "=========================================="
    echo "  RW-Node 卸载完成!"
    echo "=========================================="
    echo -e "${NC}"
    echo ""
    
    if [[ -f /tmp/rw-node-env.backup ]]; then
        echo -e "${CYAN}配置文件备份:${NC} /tmp/rw-node-env.backup"
        echo ""
    fi
    
    echo "如需重新安装，请运行:"
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/x-dora/rw-node/main/scripts/install.sh)"
    echo ""
}

#######################################
# 主函数
#######################################
main() {
    echo -e "${CYAN}"
    echo "=========================================="
    echo "  RW-Node 卸载脚本"
    echo "=========================================="
    echo -e "${NC}"
    
    check_root
    confirm_uninstall
    ask_keep_config || true
    stop_services
    remove_services
    remove_files
    print_completion
}

main "$@"
