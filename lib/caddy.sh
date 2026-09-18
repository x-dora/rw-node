#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n "${_RW_NODE_CADDY_LOADED:-}" ]] && return 0
_RW_NODE_CADDY_LOADED=1

_CADDY_LIB_DIR="${_CADDY_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
# shellcheck source=core.sh
[[ -n "${_RW_NODE_CORE_LOADED:-}" ]] || source "${_CADDY_LIB_DIR}/core.sh"

DEFAULT_CADDY_INDEX_PAGE="mikutap"
DEFAULT_CADDY_INDEX_PAGE_URL="https://github.com/AYJCSGM/mikutap/archive/master.zip"
CADDY_SITE_MARKER=".rw-node-caddy-site-dir"
CADDY_ADMIN_SOCK="${CADDY_ADMIN_SOCK:-/tmp/caddy-admin.sock}"

resolve_caddy_index_page() {
    local resource="$1"
    local key="${resource,,}"

    case "${key}" in
        ""|"mikutap")
            if [[ -f "${CADDY_DEFAULT_SITE_DIR:-}/index.html" ]]; then
                echo "${CADDY_DEFAULT_SITE_DIR}"
            else
                echo "${DEFAULT_CADDY_INDEX_PAGE_URL}"
            fi
            ;;
        "mikutap-remote"|"mikutap-url")
            echo "${DEFAULT_CADDY_INDEX_PAGE_URL}"
            ;;
        "caddy"|"caddy-welcome"|"welcome")
            echo "https://raw.githubusercontent.com/caddyserver/dist/master/welcome/index.html"
            ;;
        "3dcelist"|"3dce")
            echo "https://github.com/wulabing/3DCEList/archive/master.zip"
            ;;
        "spotify"|"spotify-landing-page")
            echo "https://github.com/WebDevSimplified/Spotify-Landing-Page-Redesign/archive/master.zip"
            ;;
        "dev-landing-page")
            echo "https://github.com/flexdinesh/dev-landing-page/archive/master.zip"
            ;;
        "free-for-dev")
            echo "https://github.com/ripienaar/free-for-dev/archive/master.zip"
            ;;
        "tailwind-landing-page"|"tailwindtoolbox-landing-page")
            echo "https://github.com/tailwindtoolbox/Landing-Page/archive/master.zip"
            ;;
        "simple-landing-page")
            echo "https://github.com/sandhikagalih/simple-landing-page/archive/master.zip"
            ;;
        "startbootstrap-new-age"|"new-age")
            echo "https://github.com/StartBootstrap/startbootstrap-new-age/archive/master.zip"
            ;;
        "webgl-fluid-simulation"|"fluid-simulation")
            echo "https://github.com/PavelDoGreat/WebGL-Fluid-Simulation/archive/master.zip"
            ;;
        "loruki"|"loruki-website")
            echo "https://github.com/bradtraversy/loruki-website/archive/master.zip"
            ;;
        "bongo-cat")
            echo "https://github.com/Externalizable/bongo.cat/archive/master.zip"
            ;;
        *)
            echo "${resource}"
            ;;
    esac
}

reset_directory() {
    local target_dir="$1"
    local target_real
    local work_real=""
    local conf_real=""

    case "${target_dir}" in
        ""|"/"|"/bin"|"/etc"|"/lib"|"/opt"|"/root"|"/sbin"|"/tmp"|"/usr"|"/usr/bin"|"/usr/local"|"/usr/local/bin"|"/var"|"/var/lib")
            log "ERROR: refusing to reset unsafe directory: ${target_dir}"
            return 1
            ;;
    esac

    mkdir -p "${target_dir}"
    target_real="$(cd "${target_dir}" && pwd -P)"
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        work_real="$(cd "${WORK_DIR}" && pwd -P)"
    fi
    if [[ -n "${CADDY_CONF_DIR:-}" && -d "${CADDY_CONF_DIR}" ]]; then
        conf_real="$(cd "${CADDY_CONF_DIR}" && pwd -P)"
    fi

    case "${target_real}" in
        ""|"/"|"/bin"|"/etc"|"/lib"|"/opt"|"/root"|"/sbin"|"/tmp"|"/usr"|"/usr/bin"|"/usr/local"|"/usr/local/bin"|"/var"|"/var/lib")
            log "ERROR: refusing to reset unsafe directory: ${target_real}"
            return 1
            ;;
    esac

    if [[ "${target_real}" == "${work_real}" || "${target_real}" == "${conf_real}" ]]; then
        log "ERROR: refusing to reset unsafe directory: ${target_dir}"
        return 1
    fi

    find "${target_real}" -mindepth 1 -maxdepth 1 -exec rm -rf {} \;
}

reject_resource_inside_site_dir() {
    local resource="$1"
    local site_dir="$2"
    local local_resource="${resource}"
    local resource_real
    local site_real

    case "${local_resource}" in
        builtin:*|http://*|https://*)
            return 0
            ;;
        file://*)
            local_resource="${local_resource#file://}"
            ;;
    esac

    if [[ ! -e "${local_resource}" ]]; then
        return 0
    fi

    mkdir -p "${site_dir}"
    resource_real="$(canonical_path "${local_resource}")"
    site_real="$(canonical_path "${site_dir}")"

    if path_is_same_or_under "${resource_real}" "${site_real}" || path_is_same_or_under "${site_real}" "${resource_real}"; then
        log "ERROR: CADDY_INDEX_PAGE source and CADDY_SITE_DIR must be separate directories: ${local_resource}"
        return 1
    fi
}

site_dir_can_be_reset() {
    local site_dir="$1"
    local site_real
    local default_site_real=""

    mkdir -p "${site_dir}"
    site_real="$(canonical_path "${site_dir}")"

    if [[ -n "${WORK_DIR:-}" ]]; then
        mkdir -p "${WORK_DIR}/www"
        default_site_real="$(canonical_path "${WORK_DIR}/www")"
    fi

    if [[ -f "${site_real}/${CADDY_SITE_MARKER}" || "${site_real}" == "${default_site_real}" ]]; then
        return 0
    fi

    if directory_has_entries "${site_real}"; then
        log "ERROR: custom CADDY_SITE_DIR must be empty or contain ${CADDY_SITE_MARKER}: ${site_dir}"
        return 1
    fi
}

publish_static_site() {
    local staging_dir="$1"
    local final_site_dir="$2"

    site_dir_can_be_reset "${final_site_dir}" || return 1
    reset_directory "${final_site_dir}" || return 1
    cp -a "${staging_dir}/." "${final_site_dir}/"
    touch "${final_site_dir}/${CADDY_SITE_MARKER}"
}

create_fallback_static_site() {
    local site_dir="${1:-${CADDY_SITE_DIR}}"

    cat > "${site_dir}/index.html" << 'FALLBACK_EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Welcome</title>
  <style>
    :root { color-scheme: light dark; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #f6f7f9;
      color: #20242a;
    }
    main { width: min(32rem, calc(100vw - 2rem)); }
    h1 { margin: 0 0 .75rem; font-size: clamp(2rem, 5vw, 3rem); line-height: 1.05; }
    p { margin: 0; color: #5d6673; line-height: 1.6; }
    @media (prefers-color-scheme: dark) {
      body { background: #111318; color: #f5f7fa; }
      p { color: #a8b0bc; }
    }
  </style>
</head>
<body>
  <main>
    <h1>Welcome</h1>
    <p>The service is running.</p>
  </main>
</body>
</html>
FALLBACK_EOF
}

copy_extracted_static_site() {
    local extract_dir="$1"
    local site_dir="$2"
    local source_dir="${extract_dir}"
    local index_file

    index_file="$(find "${extract_dir}" -mindepth 1 -maxdepth 4 -type f -iname 'index.html' | sort | head -n 1 || true)"
    if [[ -n "${index_file}" ]]; then
        source_dir="$(dirname "${index_file}")"
    fi

    cp -a "${source_dir}/." "${site_dir}/"
}

install_caddy_index_file() {
    local file_path="$1"
    local site_dir="$2"
    local extract_dir="${CADDY_CONF_DIR}/site-extract"

    reset_directory "${extract_dir}" || return 1

    if unzip -tq "${file_path}" >/dev/null 2>&1; then
        unzip -q "${file_path}" -d "${extract_dir}"
        copy_extracted_static_site "${extract_dir}" "${site_dir}"
        return 0
    fi

    if tar -tzf "${file_path}" >/dev/null 2>&1; then
        tar -xzf "${file_path}" -C "${extract_dir}"
        copy_extracted_static_site "${extract_dir}" "${site_dir}"
        return 0
    fi

    cp "${file_path}" "${site_dir}/index.html"
}

install_caddy_index_resource() {
    local resource="$1"
    local site_dir="$2"
    local download_path="${CADDY_CONF_DIR}/index-page.asset"
    local local_path

    case "${resource}" in
        builtin:fallback)
            return 1
            ;;
        http://*|https://*)
            log "Downloading static camouflage page: ${resource}"
            rm -f "${download_path}"
            if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "${resource}" -o "${download_path}"; then
                rm -f "${download_path}"
                return 1
            fi
            install_caddy_index_file "${download_path}" "${site_dir}"
            ;;
        file://*)
            local_path="${resource#file://}"
            install_caddy_index_resource "${local_path}" "${site_dir}"
            ;;
        *)
            if [[ -d "${resource}" ]]; then
                cp -a "${resource}/." "${site_dir}/"
            elif [[ -f "${resource}" ]]; then
                install_caddy_index_file "${resource}" "${site_dir}"
            else
                log "ERROR: static camouflage page resource not found: ${resource}"
                return 1
            fi
            ;;
    esac
}

setup_caddy_static_site() {
    local requested_resource="${CADDY_INDEX_PAGE:-${DEFAULT_CADDY_INDEX_PAGE}}"
    local resolved_resource
    local final_site_dir="${CADDY_SITE_DIR}"
    local staging_dir="${CADDY_CONF_DIR}/site-build"
    local staging_real
    local final_real

    resolved_resource="$(resolve_caddy_index_page "${requested_resource}")"
    mkdir -p "${CADDY_CONF_DIR}"
    reject_resource_inside_site_dir "${resolved_resource}" "${final_site_dir}" || return 1
    reset_directory "${staging_dir}" || return 1

    if ! install_caddy_index_resource "${resolved_resource}" "${staging_dir}"; then
        log "WARN: using fallback static camouflage page"
        create_fallback_static_site "${staging_dir}"
    fi

    if [[ ! -f "${staging_dir}/index.html" ]]; then
        log "WARN: static camouflage page has no index.html; using fallback"
        reset_directory "${staging_dir}" || return 1
        create_fallback_static_site "${staging_dir}"
    fi

    mkdir -p "${final_site_dir}"
    staging_real="$(canonical_path "${staging_dir}")"
    final_real="$(canonical_path "${final_site_dir}")"
    if path_is_same_or_under "${staging_real}" "${final_real}" || path_is_same_or_under "${final_real}" "${staging_real}"; then
        log "ERROR: CADDY_SITE_DIR and Caddy staging directory must not contain each other: ${final_site_dir}"
        return 1
    fi

    publish_static_site "${staging_dir}" "${final_site_dir}"
}

# SSH 入口要求同时具备公钥（否则无人能登录）和支持 ssh matcher 的 Caddy，
# 任一缺失都退回关闭状态，避免在单端口上生成一条永远连不通的 L4 路由。
ssh_entry_enabled() {
    [[ "${SSH_ENABLED:-false}" == "true" ]] || return 1
    [[ -n "${SSH_AUTHORIZED_KEYS:-}" ]] || return 1
    return 0
}

disable_ssh_entry() {
    log "WARN: $1; SSH entry stays disabled"
    SSH_ENABLED=false
    export SSH_ENABLED
}

resolve_sshd_lite_bin() {
    if [[ -n "${SSHD_LITE_BIN:-}" ]]; then
        printf '%s' "${SSHD_LITE_BIN}"
        return 0
    fi
    command -v sshd-lite 2>/dev/null || true
}

start_ssh_service() {
    if [[ "${SSH_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    # 以下每条降级路径都同时关闭 SSH_ENABLED：write_caddy_config 和 watcher
    # 会继承这个变量，从而不会在 HTTP_FRONT_PORT 上留下连不通的 SSH 路由。
    if [[ -z "${SSH_AUTHORIZED_KEYS:-}" ]]; then
        disable_ssh_entry "SSH_ENABLED is true but SSH_AUTHORIZED_KEYS is empty"
        return 0
    fi

    # Caddy 由 ensure_caddy 从官方 download API 固定拉取，必然带 layer4 的 ssh
    # matcher，因此这里不做运行时探测，只在 sshd-lite 缺失或起不来时降级。
    local sshd_bin
    sshd_bin="$(resolve_sshd_lite_bin)"
    if [[ -z "${sshd_bin}" || ! -x "${sshd_bin}" ]]; then
        disable_ssh_entry "sshd-lite not found"
        return 0
    fi

    local ssh_dir host_key
    ssh_dir="${SSH_DIR:-${WORK_DIR:-.}/ssh}"
    host_key="${ssh_dir}/host_key"
    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"

    # 容器无持久卷时 host key 每次重建都会变，客户端会报 host key 已更改；
    # SSH_HOST_KEY 给出私钥内容即可固定下来。
    if [[ ! -s "${host_key}" && -n "${SSH_HOST_KEY:-}" ]]; then
        printf '%s\n' "${SSH_HOST_KEY}" > "${host_key}"
        chmod 600 "${host_key}"
    fi

    log "Starting SSH service on 127.0.0.1:${SSH_PORT}"
    SSH_LISTEN="127.0.0.1:${SSH_PORT}" \
    SSH_AUTHORIZED_KEYS="${SSH_AUTHORIZED_KEYS}" \
    SSH_HOST_KEY_FILE="${host_key}" \
        "${sshd_bin}" &
    ssh_service_pid=$!

    sleep 0.3
    if ! kill -0 "${ssh_service_pid}" 2>/dev/null; then
        ssh_service_pid=""
        disable_ssh_entry "SSH service failed to start on 127.0.0.1:${SSH_PORT}"
        return 0
    fi

    log "SSH entry ready: port ${HTTP_FRONT_PORT} serves SSH, HTTP and TLS"
    log "SSH login: ssh -p ${HTTP_FRONT_PORT} <any-user>@<host> (sshd-lite ignores the username)"
}

write_caddy_config() {
    local config_path="$1"
    local l4_block="${2:-}"
    local http_block="${3:-}"
    local panel_sni="${4:-}"
    local template_path="${_CADDY_LIB_DIR}/Caddyfile.template"

    [[ -f "${template_path}" ]] || fail "Caddy template not found: ${template_path}"

    local admin_line="admin off"
    [[ "${INBOUND_WATCHER_ENABLED:-true}" != "true" ]] || admin_line="admin unix/${CADDY_ADMIN_SOCK}"

    if [[ -z "${http_block}" ]]; then
        printf -v http_block '    handle /xh-* {\n        reverse_proxy 127.0.0.1:%s {\n            flush_interval -1\n        }\n    }\n\n    handle /ws-* {\n        reverse_proxy 127.0.0.1:%s {\n            flush_interval -1\n        }\n    }' \
            "${XHTTP_UPSTREAM_PORT}" "${WS_UPSTREAM_PORT}"
    fi

    local tls_server_name_line=""
    if [[ -n "${panel_sni}" ]]; then
        # Upstream SNI for the node API when SNI_VERIFICATION is enabled on
        # the node; the derived hostname is public tooling metadata, not a secret.
        tls_server_name_line="                tls_server_name ${panel_sni}"
    fi

    if [[ -n "${panel_sni}" && -z "${l4_block}" ]]; then
        printf -v l4_block '                @panel tls sni %s\n                route @panel {\n                    proxy 127.0.0.1:%s\n                }' \
            "${panel_sni}" "${NODE_PORT}"
    fi

    # SSH 分流放在最前：ssh matcher 只读首 4 字节判别 `SSH-`，代价最低，
    # 且与 TLS(0x16)/HTTP(method) 首字节互斥，不会误伤其它协议。
    local ssh_block=""
    if ssh_entry_enabled; then
        printf -v ssh_block '                @ssh ssh\n                route @ssh {\n                    proxy 127.0.0.1:%s\n                }' "${SSH_PORT}"
    fi

    local content
    content="$(<"${template_path}")"
    content="${content//\$\{CADDY_ADMIN_LINE\}/${admin_line}}"
    content="${content//\$\{SSH_ROUTE_BLOCK\}/${ssh_block}}"
    content="${content//\$\{L4_ROUTE_BLOCK\}/${l4_block}}"
    content="${content//\$\{HTTP_ROUTE_BLOCK\}/${http_block}}"
    content="${content//\$\{HTTP_FRONT_PORT\}/${HTTP_FRONT_PORT}}"
    content="${content//\$\{NODE_PORT\}/${NODE_PORT}}"
    content="${content//\$\{NODE_TLS_SERVER_NAME\}/${tls_server_name_line}}"
    content="${content//\$\{CADDY_SITE_DIR\}/${CADDY_SITE_DIR}}"
    printf '%s\n' "${content}" > "${config_path}"
}

# ── Inbound 动态分流 ────────────────────────────────────────────────────────
# 三个后端（jq / Node / Python）只做一件事：把 /internal/get-config 的原始 JSON
# 解析成下面这种 tab 分隔的路由记录写到 stdout。配置块生成、写文件、fmt 和热重载
# 全部由 render_inbound_routing / write_caddy_config 承担，避免多份模板替换逻辑
# 各自漂移——此前 ${SSH_ROUTE_BLOCK} 只在 bash 侧替换，Python 后端生成的 Caddyfile
# 里留着字面占位符，就是这类漂移导致的 reload 失败。
#
# 记录格式（字段以 \t 分隔）：
#   panel<TAB><sni>
#   reality<TAB><port><TAB><sni1> <sni2> ...
#   http<TAB><path><TAB><port><TAB><network>
#   conflict<TAB><path><TAB><tag(port:N)>, <tag(port:N)>
#
# 空输出表示响应里没有可分流的 inbound（调用方退回默认兜底路由）；后端解析失败
# 时以非零状态退出，调用方跳过本轮并保留上一份可用配置。
parse_inbound_config_jq() {
    jq -r '
        def inbounds: (.inbounds // []) | if type == "array" then . else [] end;
        def normalize_path: split("?")[0] | split("#")[0] | if startswith("/") then . else "/"+. end;
        def valid_port: type == "number" and . > 0 and . < 65536;
        def http_path($s):
          if $s.network == "ws" then ($s.wsSettings.path // "")
          elif $s.network == "xhttp" then ($s.xhttpSettings.path // "")
          elif $s.network == "httpupgrade" then ($s.httpupgradeSettings.path // "")
          else "" end;
        def http_candidates:
          [ inbounds[] |
            (.streamSettings // {}) as $s |
            select($s.security != "reality") |
            select($s.network as $n | $n == "ws" or $n == "xhttp" or $n == "httpupgrade") |
            (http_path($s)) as $p |
            select(($p | type) == "string" and $p != "") |
            select(.port | valid_port) |
            { path: ($p | normalize_path), port: .port, network: $s.network, tag: (.tag // "port:\(.port)") }
          ];
        def reality_records:
          [ inbounds[] |
            (.streamSettings // {}) as $s |
            select($s.security == "reality") |
            (($s.realitySettings.serverNames // []) | map(select(type == "string"))) as $names |
            select(($names | length) > 0) |
            select(.port | valid_port) |
            { port: .port, serverNames: $names }
          ] |
          group_by(.port)[] |
          "reality\t\(.[0].port)\t\([.[].serverNames[]] | unique | sort | join(" "))";
        (.panelSni // "" | if type == "string" then . else "" end) as $sni |
        (http_candidates | group_by(.path)) as $groups |
        (if $sni == "" then empty else "panel\t\($sni)" end),
        reality_records,
        ([ $groups[] | select(([.[].port] | unique | length) == 1) | .[0] ] |
          sort_by(-(.path | length), .path)[] |
          "http\t\(.path)\t\(.port)\t\(.network)"),
        ($groups[] | select(([.[].port] | unique | length) > 1) |
          "conflict\t\(.[0].path)\t\([.[] | "\(.tag)(port:\(.port))"] | join(", "))")
    ' 2>/dev/null
}

# Node / Python 后端的脚本路径；jq 后端内嵌在本文件里，没有独立脚本。
inbound_watcher_script() {
    case "$1" in
        node)   printf '%s' "${_CADDY_LIB_DIR}/inbound-watcher.js" ;;
        python) printf '%s' "${_CADDY_LIB_DIR}/inbound-watcher.py" ;;
    esac
}

# 后端分发：stdin 收原始 JSON，stdout 出路由记录，非零退出表示解析失败。
inbound_watcher_parse() {
    local backend="$1"
    local script
    script="$(inbound_watcher_script "${backend}")"

    case "${backend}" in
        jq)     parse_inbound_config_jq ;;
        node)   node "${script}" ;;
        python) python3 "${script}" ;;
        *)      return 1 ;;
    esac
}

# 把路由记录渲染成 Caddyfile 片段并落盘。l4/http 片段为空时 write_caddy_config
# 会退回默认的 /xh-* /ws-* 兜底路由，panel_sni 为空时不注入上游 SNI。
render_inbound_routing() {
    local config_path="$1"
    local records="$2"

    local -a reality_ports=() reality_snis=()
    local -a http_paths=() http_ports=() http_networks=()
    local -a conflict_paths=() conflict_tags=()
    local panel_sni=""
    local kind field1 field2 field3

    # 后端已保证记录顺序确定（reality 按端口、http 按路径长度倒序），这里只做归类。
    while IFS=$'\t' read -r kind field1 field2 field3; do
        case "${kind}" in
            panel)
                panel_sni="${field1}"
                ;;
            reality)
                reality_ports+=("${field1}")
                reality_snis+=("${field2}")
                ;;
            http)
                http_paths+=("${field1}")
                http_ports+=("${field2}")
                http_networks+=("${field3}")
                ;;
            conflict)
                conflict_paths+=("${field1}")
                conflict_tags+=("${field2}")
                ;;
        esac
    done <<<"${records}"

    local i
    for i in "${!conflict_paths[@]}"; do
        log "WARN: HTTP route conflict: path=${conflict_paths[$i]} claimed by [${conflict_tags[$i]}], skipped"
    done

    if [[ -n "${panel_sni}" ]]; then
        log "L4 route: PANEL sni=${panel_sni} -> 127.0.0.1:${NODE_PORT}"
    fi

    for i in "${!reality_ports[@]}"; do
        log "L4 route: REALITY snis=[${reality_snis[$i]}] -> 127.0.0.1:${reality_ports[$i]}"
    done

    for i in "${!http_paths[@]}"; do
        log "HTTP route: ${http_paths[$i]} [${http_networks[$i]}] -> 127.0.0.1:${http_ports[$i]}"
    done

    if (( ${#http_paths[@]} == 0 )); then
        if (( ${#reality_ports[@]} > 0 || ${#conflict_paths[@]} > 0 )); then
            log "No HTTP path inbounds detected, using fallback wildcard routes"
        elif [[ -n "${panel_sni}" ]]; then
            log "Only panel SNI detected, using default HTTP routes"
        else
            log "No routeable inbounds detected, using default config"
        fi
    fi

    local l4_block="" http_block="" matcher pattern

    if [[ -n "${panel_sni}" ]]; then
        printf -v l4_block '                @panel tls sni %s\n                route @panel {\n                    proxy 127.0.0.1:%s\n                }' \
            "${panel_sni}" "${NODE_PORT}"
    fi

    # 只有一个 REALITY 端口时沿用 @reality 这个旧名字，多端口才带端口后缀。
    for i in "${!reality_ports[@]}"; do
        if (( ${#reality_ports[@]} == 1 )); then
            matcher="reality"
        else
            matcher="reality_${reality_ports[$i]}"
        fi
        [[ -z "${l4_block}" ]] || l4_block+=$'\n'
        l4_block+="                @${matcher} tls sni ${reality_snis[$i]}"$'\n'
        l4_block+="                route @${matcher} {"$'\n'
        l4_block+="                    proxy 127.0.0.1:${reality_ports[$i]}"$'\n'
        l4_block+="                }"
    done

    for i in "${!http_paths[@]}"; do
        pattern="${http_paths[$i]}"
        [[ "${pattern}" == *'*' ]] || pattern="${pattern}*"
        (( i == 0 )) || http_block+=$'\n'$'\n'
        http_block+="    handle ${pattern} {"$'\n'
        http_block+="        reverse_proxy 127.0.0.1:${http_ports[$i]} {"$'\n'
        http_block+="            flush_interval -1"$'\n'
        http_block+="        }"$'\n'
        http_block+="    }"
    done

    write_caddy_config "${config_path}" "${l4_block}" "${http_block}" "${panel_sni}"
}

_detect_inbound_watcher_backend() {
    local preferred="${STARTER_RUNTIME:-}"
    if [[ -n "${preferred}" ]]; then
        local bin="${preferred}"
        [[ "${bin}" != "python" ]] || bin="python3"
        if command -v "${bin}" >/dev/null 2>&1; then
            printf '%s' "${preferred}"
            return 0
        fi
    fi

    local cmd
    for cmd in jq node python3; do
        if command -v "${cmd}" >/dev/null 2>&1; then
            [[ "${cmd}" != "python3" ]] && printf '%s' "${cmd}" || printf 'python'
            return 0
        fi
    done
    return 1
}

# watcher 主循环：三个后端共用这一份轮询、日志与热重载逻辑，只有解析步骤不同。
_start_inbound_watcher() {
    local config_path="$1"
    local backend="$2"
    local internal_url="http://127.0.0.1:${INTERNAL_REST_PORT}/internal/get-config"
    local interval="${INBOUND_WATCHER_INTERVAL:-15}"
    local prev_hash=""
    local first_run=1

    [[ "${interval}" =~ ^[0-9]+$ ]] || interval=15

    # 等 rw-node-go 的内部 API 就绪；超时也继续，后续轮询会自然重试。
    for _ in $(seq 1 120); do
        if (echo >"/dev/tcp/127.0.0.1/${INTERNAL_REST_PORT}") >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    while true; do
        if (( first_run )); then
            first_run=0
        else
            sleep "${interval}"
        fi

        local config_json
        config_json="$(curl -sS --max-time 5 "${internal_url}" 2>/dev/null || true)"
        [[ -n "${config_json}" ]] || continue

        # 后端解析失败时保持上一份可用配置，不做任何写入。
        local records
        if ! records="$(printf '%s' "${config_json}" | inbound_watcher_parse "${backend}")"; then
            log "WARN: ${backend} backend failed to parse inbound config; keeping current routing"
            continue
        fi

        local current_hash
        current_hash="$(printf '%s' "${records}" | md5sum | cut -d' ' -f1)"
        if [[ "${current_hash}" == "${prev_hash}" ]]; then
            continue
        fi

        render_inbound_routing "${config_path}" "${records}"
        "${CADDY_BIN}" fmt --overwrite "${config_path}" >/dev/null 2>&1 || true

        # reload 失败的原文必须打出来——被 2>/dev/null 吞掉时只剩一句 WARN，
        # 无法区分是 Caddy 没起来（admin socket 不可达）还是新配置被拒。
        local reload_output
        if reload_output="$("${CADDY_BIN}" reload --config "${config_path}" --adapter caddyfile --address "unix/${CADDY_ADMIN_SOCK}" 2>&1)"; then
            log "Caddy reloaded with updated inbound routing config"
            prev_hash="${current_hash}"
            continue
        fi

        # 只有重载成功才推进 prev_hash，下一轮会用同一份配置重试。
        log "WARN: Caddy reload failed: ${reload_output}"
        if [[ -S "${CADDY_ADMIN_SOCK}" ]]; then
            log "WARN: admin socket ${CADDY_ADMIN_SOCK} exists; likely the new config was rejected"
        else
            log "WARN: admin socket ${CADDY_ADMIN_SOCK} missing; Caddy is probably not running"
        fi
        log "WARN: will retry next cycle"
    done
}

start_inbound_watcher() {
    local config_path="$1"
    local backend

    if ! backend="$(_detect_inbound_watcher_backend)"; then
        log "WARN: Inbound watcher disabled (no jq, node, or python3 available)"
        return 0
    fi

    export CADDY_ADMIN_SOCK CADDY_BIN CADDY_SITE_DIR LOG_PREFIX

    local watcher_script
    watcher_script="$(inbound_watcher_script "${backend}")"
    if [[ -n "${watcher_script}" && ! -f "${watcher_script}" ]]; then
        log "WARN: Inbound watcher script not found: ${watcher_script}"
        return 0
    fi

    log "Inbound watcher using ${backend} backend"
    _start_inbound_watcher "${config_path}" "${backend}"
}

start_caddy_front() {
    validate_ports

    if [[ ! -x "${CADDY_BIN}" ]]; then
        fail "caddy binary not found: ${CADDY_BIN:-<not set>}"
    fi

    mkdir -p "${CADDY_CONF_DIR}"
    setup_caddy_static_site

    local config_path="${CADDY_CONF_DIR}/Caddyfile"
    write_caddy_config "${config_path}"
    "${CADDY_BIN}" fmt --overwrite "${config_path}" >/dev/null 2>&1 || true

    local validate_output
    validate_output="$(mktemp)"
    local caddy_env=()
    [[ -z "${CADDY_HOME:-}" ]] || caddy_env+=(HOME="${CADDY_HOME}")
    [[ -z "${CADDY_XDG_DATA_HOME:-}" ]] || caddy_env+=(XDG_DATA_HOME="${CADDY_XDG_DATA_HOME}")
    [[ -z "${CADDY_XDG_CONFIG_HOME:-}" ]] || caddy_env+=(XDG_CONFIG_HOME="${CADDY_XDG_CONFIG_HOME}")

    if ! env "${caddy_env[@]}" "${CADDY_BIN}" validate --config "${config_path}" --adapter caddyfile >"${validate_output}" 2>&1; then
        cat "${validate_output}" >&2
        rm -f "${validate_output}"
        fail "Caddy configuration validation failed"
    fi
    rm -f "${validate_output}"
    log "Caddy configuration is valid"

    log "Starting Caddy (HTTP on port ${HTTP_FRONT_PORT} with L4 listener wrapper)"
    env "${caddy_env[@]}" "${CADDY_BIN}" run --config "${config_path}" --adapter caddyfile &
    caddy_pid=$!

    if [[ -z "${CADDY_SKIP_PORT_WAIT:-}" ]]; then
        if ! wait_for_health "${HTTP_FRONT_PORT}" "${caddy_pid}"; then
            log "ERROR: Caddy health endpoint not responding on 127.0.0.1:${HTTP_FRONT_PORT}/health"
            return 1
        fi
    fi
}
