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

write_caddy_config() {
    local config_path="$1"
    local reality_snis="${2:-}"
    local reality_port="${3:-}"
    local template_path="${_CADDY_LIB_DIR}/Caddyfile.template"

    [[ -f "${template_path}" ]] || fail "Caddy template not found: ${template_path}"

    local admin_line="admin off"
    [[ "${REALITY_SPLIT_ENABLED:-true}" != "true" ]] || admin_line="admin unix/${CADDY_ADMIN_SOCK}"

    local reality_block=""
    if [[ -n "${reality_snis}" && -n "${reality_port}" ]]; then
        printf -v reality_block '            @reality tls sni %s\n            route @reality {\n                proxy 127.0.0.1:%s\n            }' \
            "${reality_snis}" "${reality_port}"
    fi

    local content
    content="$(<"${template_path}")"
    content="${content//\$\{CADDY_ADMIN_LINE\}/${admin_line}}"
    content="${content//\$\{REALITY_ROUTE_BLOCK\}/${reality_block}}"
    content="${content//\$\{HTTP_FRONT_PORT\}/${HTTP_FRONT_PORT}}"
    content="${content//\$\{NODE_PORT\}/${NODE_PORT}}"
    content="${content//\$\{CADDY_HTTP_PORT\}/${CADDY_HTTP_PORT}}"
    content="${content//\$\{XHTTP_UPSTREAM_PORT\}/${XHTTP_UPSTREAM_PORT}}"
    content="${content//\$\{WS_UPSTREAM_PORT\}/${WS_UPSTREAM_PORT}}"
    content="${content//\$\{CADDY_SITE_DIR\}/${CADDY_SITE_DIR}}"
    printf '%s\n' "${content}" > "${config_path}"
}

extract_reality_config_jq() {
    local config_json="$1"

    echo "${config_json}" | jq -r '
        [.inbounds // [] | .[] |
         select(.streamSettings.security == "reality") |
         {
           port: .port,
           serverNames: (.streamSettings.realitySettings.serverNames // [])
         }
        ] |
        if length == 0 then empty
        else
          {
            port: (map(.port) | first),
            serverNames: [map(.serverNames[]) | unique | .[]]
          } |
          "\(.port)\n\(.serverNames | join(" "))"
        end
    ' 2>/dev/null || true
}

_detect_reality_watcher_backend() {
    local starter_runtime="${STARTER_RUNTIME:-}"

    if [[ -n "${starter_runtime}" ]]; then
        case "${starter_runtime}" in
            node)
                if command -v node >/dev/null 2>&1; then
                    printf 'node'
                    return 0
                fi
                ;;
            python)
                if command -v python3 >/dev/null 2>&1; then
                    printf 'python'
                    return 0
                fi
                ;;
        esac
    fi

    if command -v jq >/dev/null 2>&1; then
        printf 'jq'
        return 0
    fi
    if command -v node >/dev/null 2>&1; then
        printf 'node'
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf 'python'
        return 0
    fi

    return 1
}

_start_reality_watcher_jq() {
    local config_path="$1"
    local interval="${REALITY_SPLIT_INTERVAL:-15}"
    local internal_url="http://127.0.0.1:${INTERNAL_REST_PORT}/internal/get-config"
    local prev_hash=""

    for _ in $(seq 1 120); do
        if (echo >"/dev/tcp/127.0.0.1/${INTERNAL_REST_PORT}") >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    local first_run=1
    while true; do
        if (( first_run )); then
            first_run=0
        else
            sleep "${interval}"
        fi

        local config_json
        config_json="$(curl -sS --max-time 5 "${internal_url}" 2>/dev/null || true)"
        if [[ -z "${config_json}" || "${config_json}" == "{}" ]]; then
            continue
        fi

        local reality_info
        reality_info="$(extract_reality_config_jq "${config_json}")"
        local reality_port=""
        local reality_snis=""

        if [[ -n "${reality_info}" ]]; then
            reality_port="$(echo "${reality_info}" | head -1)"
            reality_snis="$(echo "${reality_info}" | tail -1)"
        fi

        local current_hash
        current_hash="$(printf '%s\n%s' "${reality_port}" "${reality_snis}" | md5sum | cut -d' ' -f1)"

        if [[ "${current_hash}" == "${prev_hash}" ]]; then
            continue
        fi

        prev_hash="${current_hash}"

        if [[ -n "${reality_snis}" && -n "${reality_port}" ]]; then
            log "REALITY split detected: snis=[${reality_snis}] port=${reality_port}"
            write_caddy_config "${config_path}" "${reality_snis}" "${reality_port}"
        else
            log "REALITY split cleared, reverting to default TLS routing"
            write_caddy_config "${config_path}" "" ""
        fi

        "${CADDY_BIN}" fmt --overwrite "${config_path}" >/dev/null 2>&1 || true

        if "${CADDY_BIN}" reload --config "${config_path}" --adapter caddyfile --address "unix/${CADDY_ADMIN_SOCK}" 2>/dev/null; then
            log "Caddy reloaded with updated REALITY split config"
        else
            log "WARN: Caddy reload failed, will retry next cycle"
        fi
    done
}

start_reality_watcher() {
    local config_path="$1"
    local backend

    if ! backend="$(_detect_reality_watcher_backend)"; then
        log "WARN: REALITY dynamic split disabled (no jq, node, or python3 available)"
        return 0
    fi

    export CADDY_ADMIN_SOCK CADDY_BIN CADDY_HTTP_PORT CADDY_SITE_DIR LOG_PREFIX

    case "${backend}" in
        jq)
            log "REALITY watcher using jq backend"
            _start_reality_watcher_jq "${config_path}"
            ;;
        node)
            local watcher_script="${_CADDY_LIB_DIR}/reality-watcher.js"
            if [[ ! -f "${watcher_script}" ]]; then
                log "WARN: REALITY watcher script not found: ${watcher_script}"
                return 0
            fi
            log "REALITY watcher using Node.js backend"
            node "${watcher_script}" "${config_path}"
            ;;
        python)
            local watcher_script="${_CADDY_LIB_DIR}/reality-watcher.py"
            if [[ ! -f "${watcher_script}" ]]; then
                log "WARN: REALITY watcher script not found: ${watcher_script}"
                return 0
            fi
            log "REALITY watcher using Python backend"
            python3 "${watcher_script}" "${config_path}"
            ;;
    esac
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

    log "Starting Caddy (layer4 on port ${HTTP_FRONT_PORT}, HTTP on internal port ${CADDY_HTTP_PORT})"
    env "${caddy_env[@]}" "${CADDY_BIN}" run --config "${config_path}" --adapter caddyfile &
    caddy_pid=$!

    if [[ -z "${CADDY_SKIP_PORT_WAIT:-}" ]]; then
        if ! wait_for_port "${HTTP_FRONT_PORT}" "${caddy_pid}"; then
            log "ERROR: Caddy did not accept TCP connections on 127.0.0.1:${HTTP_FRONT_PORT}"
            return 1
        fi
    fi
}
