#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n "${_RW_NODE_CORE_LOADED:-}" ]] && return 0
_RW_NODE_CORE_LOADED=1

LOG_PREFIX="${LOG_PREFIX:-[rw-node]}"

log() {
  printf '%s %s\n' "$LOG_PREFIX" "$*"
}

fail() {
  printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

unquote_env_value() {
  local value
  value="$(trim "$1")"
  if [[ ${#value} -ge 2 ]]; then
    if [[ ${value:0:1} == "'" && ${value: -1} == "'" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi
  printf '%s' "$value"
}

strip_env_comment() {
  local value
  value="$(trim "$1")"

  if [[ ${#value} -ge 2 && ${value:0:1} == "'" ]]; then
    if [[ "$value" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      printf "'%s'" "${BASH_REMATCH[1]}"
      return 0
    fi
    fail ".env value has unmatched single quote"
  fi

  if [[ ${#value} -ge 2 && ${value:0:1} == '"' ]]; then
    if [[ "$value" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
      printf '"%s"' "${BASH_REMATCH[1]}"
      return 0
    fi
    fail ".env value has unmatched double quote"
  fi

  if [[ "$value" == *"#"* ]]; then
    value="${value%%#*}"
  fi
  trim "$value"
}

load_env_file() {
  local env_file="${1:-${ENV_FILE:-${CWD:-.}/.env}}"
  [[ -f "$env_file" ]] || return 0

  local line_no=0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ -z "$line" || ${line:0:1} == "#" ]] && continue

    if [[ "$line" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="$(trim "$line")"
    fi

    if [[ "$line" != *=* ]]; then
      fail ".env line $line_no is invalid: missing '='"
    fi

    key="${line%%=*}"
    value="${line#*=}"
    key="$(trim "$key")"

    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      fail ".env line $line_no has invalid variable name: $key"
    fi

    value="$(strip_env_comment "$value")"
    value="$(unquote_env_value "$value")"
    if [[ ! -v "$key" ]]; then
      printf -v "$key" '%s' "$value"
      export "$key"
    fi
  done < "$env_file"
}

resolve_secret_key() {
  if [[ -v SECRET_KEY && -n "${SECRET_KEY}" ]]; then
    return 0
  fi

  if [[ ! -v SECRET_KEY_1 ]]; then
    return 0
  fi

  SECRET_KEY=""
  local i=1 part_name
  while true; do
    part_name="SECRET_KEY_${i}"
    [[ -v "${part_name}" ]] || break
    SECRET_KEY+="${!part_name}"
    i=$((i + 1))
  done
  export SECRET_KEY
}

set_default_env() {
  resolve_secret_key
  [[ -v NODE_PORT ]]              || NODE_PORT=2222
  [[ -v NODE_TLS_CLIENT_AUTH ]]   || NODE_TLS_CLIENT_AUTH=mtls
  [[ -v INTERNAL_REST_PORT ]]     || INTERNAL_REST_PORT=61001
  [[ -v REQUIRE_SECRET_KEY ]]     || REQUIRE_SECRET_KEY=true
  [[ -v RW_NODE_DIR ]]            || RW_NODE_DIR="${RW_NODE_DIR_DEFAULT:-.}"
  [[ -v XRAY_LOCATION_ASSET ]]    || XRAY_LOCATION_ASSET="${XRAY_LOCATION_ASSET_DEFAULT:-}"
  [[ -v HTTP_FRONT_PORT ]]        || HTTP_FRONT_PORT="${PORT:-3000}"
  [[ -v XHTTP_UPSTREAM_PORT ]]    || XHTTP_UPSTREAM_PORT=8080
  [[ -v WS_UPSTREAM_PORT ]]       || WS_UPSTREAM_PORT=8880
  [[ -v HTTP_FRONT_ENABLED ]]     || HTTP_FRONT_ENABLED=true
  [[ -v CADDY_INDEX_PAGE ]]       || CADDY_INDEX_PAGE="${CADDYIndexPage:-mikutap}"
  [[ -v INBOUND_WATCHER_ENABLED ]]  || INBOUND_WATCHER_ENABLED=true
  [[ -v INBOUND_WATCHER_INTERVAL ]] || INBOUND_WATCHER_INTERVAL=15
  [[ -v ARGO_TOKEN ]]             || ARGO_TOKEN=
  [[ -v ARGO_LOG_LEVEL ]]         || ARGO_LOG_LEVEL=info

  export NODE_PORT NODE_TLS_CLIENT_AUTH INTERNAL_REST_PORT REQUIRE_SECRET_KEY
  export RW_NODE_DIR XRAY_LOCATION_ASSET HTTP_FRONT_PORT XHTTP_UPSTREAM_PORT WS_UPSTREAM_PORT
  export HTTP_FRONT_ENABLED CADDY_INDEX_PAGE INBOUND_WATCHER_ENABLED INBOUND_WATCHER_INTERVAL
  export ARGO_TOKEN ARGO_LOG_LEVEL
}

is_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

validate_ports() {
  local name
  for name in HTTP_FRONT_PORT NODE_PORT XHTTP_UPSTREAM_PORT WS_UPSTREAM_PORT; do
    is_port "${!name}" || fail "$name must be a valid TCP port"
  done

  [[ "$HTTP_FRONT_PORT" != "$NODE_PORT" ]] || fail "HTTP_FRONT_PORT must differ from NODE_PORT"
}

wait_for_port() {
  local port="$1"
  local pid="${2:-}"

  for _ in $(seq 1 50); do
    if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
      return 1
    fi
    if (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_health() {
  local port="$1"
  local pid="${2:-}"

  for _ in $(seq 1 50); do
    if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
      return 1
    fi
    if curl -sf --max-time 1 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

canonical_path() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    cd "${path}" && pwd -P
  elif [[ -e "${path}" ]]; then
    printf '%s/%s\n' "$(cd "$(dirname "${path}")" && pwd -P)" "$(basename "${path}")"
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

ensure_linux() {
  [[ "$(uname -s)" == "Linux" ]] || fail "unsupported platform: $(uname -s); only Linux x64/arm64 is supported"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   printf '%s' "amd64" ;;
    aarch64|arm64)  printf '%s' "arm64" ;;
    *) fail "unsupported architecture: $(uname -m); only x64/arm64 is supported" ;;
  esac
}

detect_rw_node_go_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)   printf '%s' "rw-node-go-linux-64.tar.gz" ;;
    aarch64|arm64)  printf '%s' "rw-node-go-linux-arm64-v8a.tar.gz" ;;
    *) fail "unsupported architecture: $(uname -m); only x64/arm64 is supported" ;;
  esac
}

detect_cloudflared_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)   printf '%s' "cloudflared-linux-amd64" ;;
    aarch64|arm64)  printf '%s' "cloudflared-linux-arm64" ;;
    *) fail "unsupported architecture: $(uname -m); only x64/arm64 is supported" ;;
  esac
}

kill_if_running() {
  local pid="${!1:-}"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && kill "${pid}" 2>/dev/null || true
}
