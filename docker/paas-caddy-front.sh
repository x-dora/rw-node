DEFAULT_CADDY_INDEX_PAGE="mikutap"
DEFAULT_CADDY_INDEX_PAGE_URL="https://github.com/AYJCSGM/mikutap/archive/master.zip"
CADDY_SITE_MARKER=".rw-node-caddy-site-dir"

resolve_caddy_index_page() {
    local resource="$1"
    local key="${resource,,}"

    case "${key}" in
        ""|"mikutap")
            if [[ -f "${CADDY_DEFAULT_SITE_DIR:-}/index.html" ]]; then
                echo "${CADDY_DEFAULT_SITE_DIR}"
            else
                echo "builtin:fallback"
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
            echo "${CADDY_LOG_PREFIX:-[PaaS]} ERROR: refusing to reset unsafe directory: ${target_dir}"
            return 1
            ;;
    esac

    mkdir -p "${target_dir}"
    target_real="$(cd "${target_dir}" && pwd -P)"
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        work_real="$(cd "${WORK_DIR}" && pwd -P)"
    fi
    if [[ -n "${CONF_DIR:-}" && -d "${CONF_DIR}" ]]; then
        conf_real="$(cd "${CONF_DIR}" && pwd -P)"
    fi

    case "${target_real}" in
        ""|"/"|"/bin"|"/etc"|"/lib"|"/opt"|"/root"|"/sbin"|"/tmp"|"/usr"|"/usr/bin"|"/usr/local"|"/usr/local/bin"|"/var"|"/var/lib")
            echo "${CADDY_LOG_PREFIX:-[PaaS]} ERROR: refusing to reset unsafe directory: ${target_real}"
            return 1
            ;;
    esac

    if [[ "${target_real}" == "${work_real}" || "${target_real}" == "${conf_real}" ]]; then
        echo "${CADDY_LOG_PREFIX:-[PaaS]} ERROR: refusing to reset unsafe directory: ${target_dir}"
        return 1
    fi

    find "${target_real}" -mindepth 1 -maxdepth 1 -exec rm -rf {} \;
}

canonical_path() {
    local path="$1"
    local dir
    local base

    if [[ -d "${path}" ]]; then
        cd "${path}" && pwd -P
    elif [[ -e "${path}" ]]; then
        dir="$(dirname "${path}")"
        base="$(basename "${path}")"
        printf '%s/%s\n' "$(cd "${dir}" && pwd -P)" "${base}"
    else
        return 1
    fi
}

path_is_same_or_under() {
    local child="$1"
    local parent="$2"

    [[ "${child}" == "${parent}" || "${child}" == "${parent}/"* ]]
}

directory_has_entries() {
    local dir="$1"

    [[ -n "$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]]
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
        echo "${CADDY_LOG_PREFIX:-[PaaS]} ERROR: custom CADDY_SITE_DIR must be empty or contain ${CADDY_SITE_MARKER}: ${site_dir}"
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
        echo "${CADDY_LOG_PREFIX:-[PaaS]} ERROR: CADDY_INDEX_PAGE source and CADDY_SITE_DIR must be separate directories: ${local_resource}"
        return 1
    fi
}

create_fallback_static_site() {
    local site_dir="${1:-${CADDY_SITE_DIR}}"

    cat > "${site_dir}/index.html" << 'EOF'
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
EOF
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
            echo "${CADDY_LOG_PREFIX:-[PaaS]} Downloading static camouflage page: ${resource}"
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
                echo "${CADDY_LOG_PREFIX:-[PaaS]} ERROR: static camouflage page resource not found: ${resource}"
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
        echo "${CADDY_LOG_PREFIX:-[PaaS]} WARN: using fallback static camouflage page"
        create_fallback_static_site "${staging_dir}"
    fi

    if [[ ! -f "${staging_dir}/index.html" ]]; then
        echo "${CADDY_LOG_PREFIX:-[PaaS]} WARN: static camouflage page has no index.html; using fallback"
        reset_directory "${staging_dir}" || return 1
        create_fallback_static_site "${staging_dir}"
    fi

    mkdir -p "${final_site_dir}"
    staging_real="$(canonical_path "${staging_dir}")"
    final_real="$(canonical_path "${final_site_dir}")"
    if path_is_same_or_under "${staging_real}" "${final_real}" || path_is_same_or_under "${final_real}" "${staging_real}"; then
        echo "${CADDY_LOG_PREFIX:-[PaaS]} ERROR: CADDY_SITE_DIR and Caddy staging directory must not contain each other: ${final_site_dir}"
        return 1
    fi

    publish_static_site "${staging_dir}" "${final_site_dir}"
}

write_caddy_config() {
    local config_path="$1"

    cat > "${config_path}" << EOF
{
    admin off
    auto_https off
    persist_config off

    log {
        level WARN
    }

    layer4 {
        :${HTTP_FRONT_PORT} {
            @tls tls
            route @tls {
                proxy 127.0.0.1:${NODE_PORT}
            }
            route {
                proxy 127.0.0.1:${CADDY_HTTP_PORT}
            }
        }
    }

    servers :${CADDY_HTTP_PORT} {
        protocols h1
    }
}

http://:${CADDY_HTTP_PORT} {
    handle /health {
        respond "ok" 200
    }

    handle /xh-* {
        reverse_proxy 127.0.0.1:${XHTTP_UPSTREAM_PORT} {
            flush_interval -1
        }
    }

    handle /ws-* {
        reverse_proxy 127.0.0.1:${WS_UPSTREAM_PORT} {
            flush_interval -1
        }
    }

    handle /node/* {
        reverse_proxy https://127.0.0.1:${NODE_PORT} {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }

    handle /vision/* {
        reverse_proxy https://127.0.0.1:${NODE_PORT} {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }

    handle {
        root * "${CADDY_SITE_DIR}"
        try_files {path} {path}/ /index.html
        encode gzip
        file_server
    }
}
EOF
}

start_caddy_front() {
    local config_path="${CADDY_CONF_DIR}/Caddyfile"
    local log_prefix="${CADDY_LOG_PREFIX:-[PaaS]}"

    if ! is_port "${HTTP_FRONT_PORT}"; then
        echo "${log_prefix} ERROR: HTTP_FRONT_PORT must be a valid TCP port"
        exit 1
    fi

    if [[ "${HTTP_FRONT_PORT}" == "${NODE_PORT}" ]]; then
        echo "${log_prefix} ERROR: HTTP_FRONT_PORT must differ from NODE_PORT"
        exit 1
    fi

    if ! is_port "${XHTTP_UPSTREAM_PORT}"; then
        echo "${log_prefix} ERROR: XHTTP_UPSTREAM_PORT must be a valid TCP port"
        exit 1
    fi

    if ! is_port "${WS_UPSTREAM_PORT}"; then
        echo "${log_prefix} ERROR: WS_UPSTREAM_PORT must be a valid TCP port"
        exit 1
    fi

    CADDY_HTTP_PORT=$((HTTP_FRONT_PORT + 1))

    if ! is_port "${CADDY_HTTP_PORT}"; then
        echo "${log_prefix} ERROR: CADDY_HTTP_PORT (${CADDY_HTTP_PORT}) must be a valid TCP port; adjust HTTP_FRONT_PORT"
        exit 1
    fi

    if [[ "${CADDY_HTTP_PORT}" == "${NODE_PORT}" ]]; then
        echo "${log_prefix} ERROR: CADDY_HTTP_PORT (${CADDY_HTTP_PORT}) conflicts with NODE_PORT"
        exit 1
    fi

    if [[ "${CADDY_HTTP_PORT}" == "${XHTTP_UPSTREAM_PORT}" ]]; then
        echo "${log_prefix} ERROR: CADDY_HTTP_PORT (${CADDY_HTTP_PORT}) conflicts with XHTTP_UPSTREAM_PORT"
        exit 1
    fi

    if [[ "${CADDY_HTTP_PORT}" == "${WS_UPSTREAM_PORT}" ]]; then
        echo "${log_prefix} ERROR: CADDY_HTTP_PORT (${CADDY_HTTP_PORT}) conflicts with WS_UPSTREAM_PORT"
        exit 1
    fi

    if [[ ! -x "${CADDY_BIN}" ]]; then
        echo "${log_prefix} ERROR: caddy binary not found"
        exit 1
    fi

    mkdir -p "${CADDY_CONF_DIR}"
    setup_caddy_static_site
    write_caddy_config "${config_path}"

    "${CADDY_BIN}" validate --config "${config_path}" --adapter caddyfile

    echo "${log_prefix} Starting Caddy (layer4 on port ${HTTP_FRONT_PORT}, HTTP on internal port ${CADDY_HTTP_PORT})"
    "${CADDY_BIN}" run --config "${config_path}" --adapter caddyfile &
    caddy_pid=$!

    if ! wait_for_port "${HTTP_FRONT_PORT}" "${caddy_pid}"; then
        echo "${log_prefix} ERROR: Caddy did not accept TCP connections on 127.0.0.1:${HTTP_FRONT_PORT}"
        terminate
        exit 1
    fi
}
