#!/bin/bash

set -euo pipefail

#######################################
# RW-Node 更新脚本
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="${RW_NODE_DIR:-/opt/rw-node}"
GITHUB_REPO="x-dora/rw-node"
UPSTREAM_REPO="remnawave/node"

TARGET_VERSION=""
FORCE=false
ASSUME_YES=false

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
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "需要 root 权限"
        exit 1
    fi
}

check_installation() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        print_error "RW-Node 未安装"
        exit 1
    fi
}

detect_container() {
    if [[ -f /.dockerenv ]] || [[ -f /run/.containerenv ]] || grep -qE '(docker|lxc|kubepods|containerd)' /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER=true
    fi

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        HAS_SYSTEMD=true
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

    if ! command -v curl >/dev/null 2>&1; then
        missing+=("curl")
    fi
    if ! command -v git >/dev/null 2>&1; then
        missing+=("git")
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

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_step "安装依赖: ${missing[*]}"
        install_packages "${missing[@]}"
    fi
}

get_current_version() {
    if [[ -f "${INSTALL_DIR}/package.json" ]]; then
        jq -r '.version // "unknown"' "${INSTALL_DIR}/package.json" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
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

backup_config() {
    print_step "备份配置..."
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        cp "${INSTALL_DIR}/.env" /tmp/rw-node-env.backup
    fi
    print_success "配置已备份"
}

restore_config() {
    if [[ -f /tmp/rw-node-env.backup ]]; then
        cp /tmp/rw-node-env.backup "${INSTALL_DIR}/.env"
        rm -f /tmp/rw-node-env.backup
        print_success "配置已恢复"
    fi
}

stop_service() {
    print_step "停止服务..."

    if [[ "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        systemctl stop rw-node 2>/dev/null || true
        systemctl stop cloudflared 2>/dev/null || true
    else
        kill_pid_file "${INSTALL_DIR}/run/rw-node.pid" "${INSTALL_DIR}/node/bin/node"

        while read -r pid_file; do
            kill_pid_file "$pid_file" "${INSTALL_DIR}/bin/supervisord"
        done < <(find "${INSTALL_DIR}/run" -maxdepth 1 -name 'supervisord-*.pid' -print 2>/dev/null || true)

        kill_processes_by_prefix "${INSTALL_DIR}/node/bin/node dist/src/main"
        kill_processes_by_prefix "${INSTALL_DIR}/bin/supervisord"
        kill_processes_by_prefix "${INSTALL_DIR}/bin/rw-core"
        kill_processes_by_prefix "${INSTALL_DIR}/bin/xray"
        kill_processes_by_prefix "${INSTALL_DIR}/bin/cloudflared"
    fi

    sleep 2
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

start_service() {
    print_step "启动服务..."

    if [[ "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        systemctl start rw-node
        if [[ -f /etc/systemd/system/cloudflared.service ]] && ! grep -q 'YOUR_TUNNEL_TOKEN' /etc/systemd/system/cloudflared.service; then
            systemctl enable cloudflared
            systemctl restart cloudflared
        fi
        sleep 3
        if systemctl is-active --quiet rw-node; then
            print_success "服务启动成功"
        else
            print_error "服务启动失败"
        fi
    else
        print_warning "容器/无 systemd 环境，请手动启动: rw-node-start"
    fi
}

deploy_staged_artifacts() {
    local stage_dir="$1"
    local backup_dir="$2"
    local artifacts=("dist" "libs" "node_modules" "package.json" "package-lock.json")
    local deployed=()
    local item
    local rollback_item

    for item in "${artifacts[@]}"; do
        if [[ ! -e "${stage_dir}/${item}" ]]; then
            print_error "更新包缺少必要文件: ${item}"
            return 1
        fi
    done

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"

    for item in "${artifacts[@]}"; do
        if [[ -e "${INSTALL_DIR}/${item}" ]]; then
            mv "${INSTALL_DIR}/${item}" "${backup_dir}/${item}"
        fi
    done

    for item in "${artifacts[@]}"; do
        if mv "${stage_dir}/${item}" "${INSTALL_DIR}/${item}"; then
            deployed+=("$item")
        else
            print_error "部署文件失败，开始回滚: ${item}"

            for rollback_item in "${deployed[@]}"; do
                rm -rf "${INSTALL_DIR:?}/${rollback_item}"
            done

            for rollback_item in "${artifacts[@]}"; do
                if [[ -e "${backup_dir}/${rollback_item}" ]]; then
                    mv "${backup_dir}/${rollback_item}" "${INSTALL_DIR}/${rollback_item}"
                fi
            done
            return 1
        fi
    done

    rm -rf "$backup_dir"
    return 0
}

build_from_source() {
    local version="$1"
    local tmp_dir="/tmp/rw-node-update-build"
    local repo_dir="${tmp_dir}/repo"
    local stage_dir="${tmp_dir}/stage"
    local backup_dir="${INSTALL_DIR}/.rw-node-update-backup.$$"

    print_step "从源码构建..."

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    if ! git clone --depth 1 --branch "$version" "https://github.com/${UPSTREAM_REPO}.git" "$repo_dir"; then
        print_error "上游仓库中不存在版本/分支: $version"
        exit 1
    fi

    (
        cd "$repo_dir"
        "${INSTALL_DIR}/node/bin/npm" ci --legacy-peer-deps
        "${INSTALL_DIR}/node/bin/npm" run build
        "${INSTALL_DIR}/node/bin/npm" ci --omit=dev --legacy-peer-deps
    )

    mkdir -p "$stage_dir"
    cp -r "${repo_dir}/dist" "${stage_dir}/"
    cp -r "${repo_dir}/libs" "${stage_dir}/"
    cp -r "${repo_dir}/node_modules" "${stage_dir}/"
    cp "${repo_dir}"/package*.json "${stage_dir}/"

    if ! deploy_staged_artifacts "$stage_dir" "$backup_dir"; then
        print_error "源码构建产物部署失败，已回滚"
        exit 1
    fi

    rm -rf "$tmp_dir"
    print_success "源码构建完成"
}

update_rw_node() {
    local version="$1"
    local arch url tmp_dir archive stage_dir backup_dir

    print_step "下载版本: $version"

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) print_error "不支持的架构: $arch"; exit 1 ;;
    esac

    url="https://github.com/${GITHUB_REPO}/releases/download/${version}/rw-node-${version}-linux-${arch}.tar.gz"
    tmp_dir="/tmp/rw-node-update"
    archive="${tmp_dir}/rw-node-${version}-linux-${arch}.tar.gz"
    stage_dir="${tmp_dir}/stage"
    backup_dir="${INSTALL_DIR}/.rw-node-update-backup.$$"

    mkdir -p "$tmp_dir"
    rm -rf "${tmp_dir:?}/"*

    if curl -fsSL "$url" -o "$archive"; then
        mkdir -p "$stage_dir"
        tar -xzf "$archive" -C "$stage_dir"
        if ! deploy_staged_artifacts "$stage_dir" "$backup_dir"; then
            print_error "更新部署失败，已回滚"
            exit 1
        fi
        rm -f "$archive"
        print_success "更新完成"
    else
        print_warning "预编译包不存在，从源码构建..."
        build_from_source "$version"
    fi
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

extract_cloudflared_token() {
    if [[ -f /etc/systemd/system/cloudflared.service ]]; then
        sed -n 's/.*--token \([^[:space:]]*\).*/\1/p' /etc/systemd/system/cloudflared.service | head -1
    fi
}

update_scripts() {
    local version="$1"
    local cloudflared_token=""

    print_step "更新脚本..."

    download_repo_file "$version" "config/start.sh" "${INSTALL_DIR}/start.sh"
    chmod +x "${INSTALL_DIR}/start.sh"

    if [[ "$HAS_SYSTEMD" == "true" && "$IS_CONTAINER" != "true" ]]; then
        download_repo_file "$version" "config/systemd/rw-node.service" "/etc/systemd/system/rw-node.service"
        sed -i "s|__INSTALL_DIR__|${INSTALL_DIR}|g" /etc/systemd/system/rw-node.service

        if [[ -f /etc/systemd/system/cloudflared.service || -x "${INSTALL_DIR}/bin/cloudflared" ]]; then
            cloudflared_token=$(extract_cloudflared_token || true)
            download_repo_file "$version" "config/systemd/cloudflared.service" "/etc/systemd/system/cloudflared.service"
            sed -i "s|__INSTALL_DIR__|${INSTALL_DIR}|g" /etc/systemd/system/cloudflared.service
            if [[ -n "$cloudflared_token" ]]; then
                sed -i "s|YOUR_TUNNEL_TOKEN|${cloudflared_token}|g" /etc/systemd/system/cloudflared.service
            fi
        fi

        systemctl daemon-reload
    fi

    print_success "脚本更新完成"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version|-v)
                TARGET_VERSION="${2:-}"
                [[ -n "$TARGET_VERSION" ]] || { print_error "--version 需要一个值"; exit 1; }
                shift 2
                ;;
            --force|-f)
                FORCE=true
                shift
                ;;
            --yes|-y)
                ASSUME_YES=true
                shift
                ;;
            --help|-h)
                echo "用法: $0 [选项]"
                echo "  --version, -v <版本>  指定版本"
                echo "  --force, -f           强制更新"
                echo "  --yes, -y             跳过确认"
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                exit 1
                ;;
        esac
    done
}

confirm_update() {
    if [[ "$ASSUME_YES" == "true" ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        print_error "非交互环境请使用 --yes 跳过确认"
        exit 1
    fi

    read -r -p "继续更新? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        exit 0
    fi
}

main() {
    echo -e "${CYAN}=========================================="
    echo -e "  RW-Node 更新脚本"
    echo -e "==========================================${NC}"

    parse_args "$@"
    check_root
    check_installation
    detect_container
    detect_os
    check_dependencies

    local current target
    current=$(get_current_version)
    target="${TARGET_VERSION:-$(get_latest_version)}"

    print_info "当前版本: $current"
    print_info "目标版本: $target"

    if [[ -z "$target" ]]; then
        print_error "无法获取目标版本"
        exit 1
    fi

    if [[ "$current" == "$target" && "$FORCE" != "true" ]]; then
        print_success "已是最新版本"
        exit 0
    fi

    confirm_update
    stop_service
    backup_config
    update_rw_node "$target"
    restore_config
    update_scripts "$target"
    start_service

    echo -e ""
    print_success "更新完成！"
}

main "$@"
