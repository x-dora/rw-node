#!/usr/bin/env bash
# shellcheck shell=bash
#
# 静态伪装页准备。这部分与前置实现无关：以前是喂给 Caddy 的 file_server，
# 现在交给 frontproxy 的静态目录，逻辑本身没变。
[[ -n "${_RW_NODE_SITE_LOADED:-}" ]] && return 0
_RW_NODE_SITE_LOADED=1

_SITE_LIB_DIR="${_SITE_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
# shellcheck source=core.sh
[[ -n "${_RW_NODE_CORE_LOADED:-}" ]] || source "${_SITE_LIB_DIR}/core.sh"

DEFAULT_INDEX_PAGE="mikutap"
DEFAULT_INDEX_PAGE_URL="https://github.com/AYJCSGM/mikutap/archive/master.zip"
SITE_DIR_MARKER=".rw-node-site-dir"

resolve_index_page() {
    local resource="$1"
    local key="${resource,,}"

    case "${key}" in
        ""|"mikutap")
            if [[ -f "${FRONT_DEFAULT_SITE_DIR:-}/index.html" ]]; then
                echo "${FRONT_DEFAULT_SITE_DIR}"
            else
                echo "${DEFAULT_INDEX_PAGE_URL}"
            fi
            ;;
        "mikutap-remote"|"mikutap-url")
            echo "${DEFAULT_INDEX_PAGE_URL}"
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

# 清空目录，但带安全白名单：这些路径一旦传错参数就是灾难性的。
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
    if [[ -n "${SITE_BUILD_DIR:-}" && -d "${SITE_BUILD_DIR}" ]]; then
        conf_real="$(cd "${SITE_BUILD_DIR}" && pwd -P)"
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
        log "ERROR: FRONT_INDEX_PAGE source and FRONT_SITE_DIR must be separate directories: ${local_resource}"
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

    if [[ -f "${site_real}/${SITE_DIR_MARKER}" || "${site_real}" == "${default_site_real}" ]]; then
        return 0
    fi

    if directory_has_entries "${site_real}"; then
        log "ERROR: custom FRONT_SITE_DIR must be empty or contain ${SITE_DIR_MARKER}: ${site_dir}"
        return 1
    fi
}

publish_static_site() {
    local staging_dir="$1"
    local final_site_dir="$2"

    site_dir_can_be_reset "${final_site_dir}" || return 1
    reset_directory "${final_site_dir}" || return 1
    cp -a "${staging_dir}/." "${final_site_dir}/"
    touch "${final_site_dir}/${SITE_DIR_MARKER}"
}

create_fallback_static_site() {
    local site_dir="${1:-${FRONT_SITE_DIR}}"

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

install_index_file() {
    local file_path="$1"
    local site_dir="$2"
    local extract_dir="${SITE_BUILD_DIR}/extract"

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

install_index_resource() {
    local resource="$1"
    local site_dir="$2"
    local download_path="${SITE_BUILD_DIR}/index-page.asset"
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
            install_index_file "${download_path}" "${site_dir}"
            ;;
        file://*)
            local_path="${resource#file://}"
            install_index_resource "${local_path}" "${site_dir}"
            ;;
        *)
            if [[ -d "${resource}" ]]; then
                cp -a "${resource}/." "${site_dir}/"
            elif [[ -f "${resource}" ]]; then
                install_index_file "${resource}" "${site_dir}"
            else
                log "ERROR: static camouflage page resource not found: ${resource}"
                return 1
            fi
            ;;
    esac
}

setup_static_site() {
    local requested_resource="${FRONT_INDEX_PAGE:-${DEFAULT_INDEX_PAGE}}"
    local resolved_resource
    local final_site_dir="${FRONT_SITE_DIR}"
    local staging_dir="${SITE_BUILD_DIR}/build"
    local staging_real
    local final_real

    resolved_resource="$(resolve_index_page "${requested_resource}")"
    mkdir -p "${SITE_BUILD_DIR}"
    reject_resource_inside_site_dir "${resolved_resource}" "${final_site_dir}" || return 1
    reset_directory "${staging_dir}" || return 1

    if ! install_index_resource "${resolved_resource}" "${staging_dir}"; then
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
        log "ERROR: FRONT_SITE_DIR and the site staging directory must not contain each other: ${final_site_dir}"
        return 1
    fi

    publish_static_site "${staging_dir}" "${final_site_dir}"
}
