#!/bin/bash

set -euo pipefail

#######################################
# RW-Node 卸载脚本
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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
    echo -e "  - 相关符号链接"
    echo -e ""

    if [[ ! -t 0 ]]; then
        print_error "非交互环境请显式确认后再执行卸载"
        exit 1
    fi

    read -r -p "继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "已取消"
        exit 0
    fi
}

systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

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

stop_services() {
    print_info "停止服务..."

    if systemd_available; then
        systemctl stop rw-node 2>/dev/null || true
        systemctl stop cloudflared 2>/dev/null || true
    fi

    kill_pid_file "${INSTALL_DIR}/run/rw-node.pid" "${INSTALL_DIR}/node/bin/node"

    while read -r pid_file; do
        kill_pid_file "$pid_file" "${INSTALL_DIR}/bin/supervisord"
    done < <(find "${INSTALL_DIR}/run" -maxdepth 1 -name 'supervisord-*.pid' -print 2>/dev/null || true)

    kill_processes_by_prefix "${INSTALL_DIR}/node/bin/node dist/src/main"
    kill_processes_by_prefix "${INSTALL_DIR}/bin/supervisord"
    kill_processes_by_prefix "${INSTALL_DIR}/bin/rw-core"
    kill_processes_by_prefix "${INSTALL_DIR}/bin/xray"
    kill_processes_by_prefix "${INSTALL_DIR}/bin/cloudflared"
}

remove_services() {
    if ! systemd_available; then
        return 0
    fi

    print_info "删除服务..."

    systemctl disable rw-node 2>/dev/null || true
    rm -f /etc/systemd/system/rw-node.service

    systemctl disable cloudflared 2>/dev/null || true
    rm -f /etc/systemd/system/cloudflared.service

    systemctl daemon-reload
    print_success "服务已删除"
}

remove_symlink_if_owned() {
    local path="$1"
    local target

    if [[ -L "$path" ]]; then
        target=$(readlink "$path" 2>/dev/null || true)
        if [[ -n "$target" && "$target" == "${INSTALL_DIR}"* ]]; then
            rm -f "$path"
        fi
    fi
}

remove_files() {
    print_info "删除文件..."

    rm -rf "$INSTALL_DIR"
    print_success "安装目录已删除"

    remove_symlink_if_owned /usr/local/bin/xlogs
    remove_symlink_if_owned /usr/local/bin/xerrors
    remove_symlink_if_owned /usr/local/bin/rw-node-status
    remove_symlink_if_owned /usr/local/bin/rw-node-start
    remove_symlink_if_owned /usr/local/bin/rw-node-stop
    remove_symlink_if_owned /usr/local/bin/node
    remove_symlink_if_owned /usr/local/bin/npm
    remove_symlink_if_owned /usr/local/bin/npx
    remove_symlink_if_owned /usr/local/bin/xray
    remove_symlink_if_owned /usr/local/bin/rw-core
    remove_symlink_if_owned /usr/local/bin/supervisord
    remove_symlink_if_owned /usr/local/bin/cloudflared

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
