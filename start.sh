#!/usr/bin/env bash
set -Eeuo pipefail

PREFIX="[bash-starter]"
REPO="x-dora/rw-node-go"
CADDY_REPO="caddyserver/caddy"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CWD="$SCRIPT_DIR"
INSTALL_DIR="$CWD/.rw-node-go"
BIN_DIR="$INSTALL_DIR/bin"
ASSET_DIR="$INSTALL_DIR/share/xray"
CONF_DIR="$INSTALL_DIR/conf/caddy"
CADDY_DATA_DIR="$INSTALL_DIR/caddy/data"
CADDY_CONFIG_DIR="$INSTALL_DIR/caddy/config"
APP_BIN="$BIN_DIR/rw-node-go"
CADDY_BIN_DEFAULT="$BIN_DIR/caddy"
VERSION_FILE="$INSTALL_DIR/.rw-node-go-version"
CADDY_VERSION_FILE="$INSTALL_DIR/.caddy-version"
CADDYFILE="$CONF_DIR/Caddyfile"

caddy_pid=""
app_pid=""
shutting_down=0
caddy_bin_resolved=""

log() {
  printf '%s %s\n' "$PREFIX" "$*"
}

fail() {
  printf '%s ERROR: %s\n' "$PREFIX" "$*" >&2
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
  local env_file="$CWD/.env"
  [[ -f "$env_file" ]] || return 0

  local line_no=0
  local line key value rest
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

set_default_env() {
  [[ -v NODE_PORT ]] || NODE_PORT=2222
  [[ -v NODE_TLS_CLIENT_AUTH ]] || NODE_TLS_CLIENT_AUTH=none
  [[ -v INTERNAL_REST_PORT ]] || INTERNAL_REST_PORT=61001
  [[ -v REQUIRE_SECRET_KEY ]] || REQUIRE_SECRET_KEY=true
  [[ -v RW_NODE_DIR ]] || RW_NODE_DIR="$CWD"
  [[ -v XRAY_LOCATION_ASSET ]] || XRAY_LOCATION_ASSET="$ASSET_DIR"
  [[ -v HTTP_FRONT_PORT ]] || HTTP_FRONT_PORT="${PORT:-3000}"
  [[ -v XHTTP_UPSTREAM_PORT ]] || XHTTP_UPSTREAM_PORT=8080
  [[ -v WS_UPSTREAM_PORT ]] || WS_UPSTREAM_PORT=8880
  export NODE_PORT NODE_TLS_CLIENT_AUTH INTERNAL_REST_PORT REQUIRE_SECRET_KEY
  export RW_NODE_DIR XRAY_LOCATION_ASSET HTTP_FRONT_PORT XHTTP_UPSTREAM_PORT WS_UPSTREAM_PORT
}

ensure_linux() {
  [[ "$(uname -s)" == "Linux" ]] || fail "unsupported platform: $(uname -s); only Linux x64/arm64 is supported"
}

detect_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s' "rw-node-go-linux-64.tar.gz" ;;
    aarch64|arm64) printf '%s' "rw-node-go-linux-arm64-v8a.tar.gz" ;;
    *) fail "unsupported architecture: $(uname -m); only x64/arm64 is supported" ;;
  esac
}

detect_caddy_asset_regex() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s' '^caddy_.*_linux_amd64\.tar\.gz$' ;;
    aarch64|arm64) printf '%s' '^caddy_.*_linux_arm64\.tar\.gz$' ;;
    *) fail "unsupported architecture: $(uname -m); only x64/arm64 is supported" ;;
  esac
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

github_api_get() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: rw-node-go-starter" \
    "$1"
}

extract_json_string() {
  local key="$1"
  sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/p" | head -n 1
}

resolve_latest_tag() {
  local repo="$1"
  github_api_get "https://api.github.com/repos/$repo/releases/latest" | extract_json_string "tag_name"
}

download_file() {
  local url="$1"
  local destination="$2"
  curl -fL \
    -H "User-Agent: rw-node-go-starter" \
    -o "$destination" \
    "$url"
  [[ -s "$destination" ]] || fail "download created an empty archive: $destination"
}

resolve_caddy_release_json() {
  if [[ -n "${CADDY_VERSION:-}" ]]; then
    github_api_get "https://api.github.com/repos/$CADDY_REPO/releases/tags/$CADDY_VERSION"
  else
    github_api_get "https://api.github.com/repos/$CADDY_REPO/releases/latest"
  fi
}

find_caddy_download_url() {
  local release_json="$1"
  local regex
  regex="$(detect_caddy_asset_regex)"

  awk -v regex="$regex" '
    /"name"[[:space:]]*:/ {
      name = $0
      sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", name)
      sub(/".*$/, "", name)
    }
    /"browser_download_url"[[:space:]]*:/ {
      url = $0
      sub(/^.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", url)
      sub(/".*$/, "", url)
      if (name ~ regex) {
        print url
        exit
      }
    }
  ' <<< "$release_json"
}

ensure_caddy() {
  if [[ -n "${CADDY_BIN:-}" ]]; then
    [[ -f "$CADDY_BIN" ]] || fail "CADDY_BIN does not exist: $CADDY_BIN"
    [[ -x "$CADDY_BIN" ]] || fail "CADDY_BIN is not executable: $CADDY_BIN"
    caddy_bin_resolved="$CADDY_BIN"
    return 0
  fi

  if [[ -x "$CADDY_BIN_DEFAULT" ]]; then
    log "Caddy already installed; skipping download"
    caddy_bin_resolved="$CADDY_BIN_DEFAULT"
    return 0
  fi

  local release_json tag url asset_name tmp_dir archive stage_dir staged_bin
  release_json="$(resolve_caddy_release_json)"
  tag="$(extract_json_string "tag_name" <<< "$release_json")"
  [[ -n "$tag" ]] || fail "unable to resolve Caddy release assets"
  url="$(find_caddy_download_url "$release_json")"
  [[ -n "$url" ]] || fail "Caddy $tag does not provide a supported Linux asset for $(uname -m)"
  asset_name="${url##*/}"
  tmp_dir="$INSTALL_DIR/tmp"
  archive="$tmp_dir/$asset_name"
  stage_dir="$tmp_dir/caddy-stage"
  staged_bin="$stage_dir/caddy"

  log "installing Caddy $tag"
  rm -rf "$tmp_dir"
  mkdir -p "$stage_dir" "$BIN_DIR"
  download_file "$url" "$archive"
  tar -xzf "$archive" -C "$stage_dir"
  [[ -f "$staged_bin" ]] || fail "Caddy release asset is missing caddy"
  cp "$staged_bin" "$CADDY_BIN_DEFAULT"
  chmod 755 "$CADDY_BIN_DEFAULT"
  printf '%s\n' "$tag" > "$CADDY_VERSION_FILE"
  rm -rf "$tmp_dir"
  caddy_bin_resolved="$CADDY_BIN_DEFAULT"
}

resolve_rw_node_go_version() {
  if [[ -n "${RW_NODE_GO_VERSION:-}" ]]; then
    printf '%s' "$RW_NODE_GO_VERSION"
    return 0
  fi

  local version
  version="$(resolve_latest_tag "$REPO")"
  [[ -n "$version" ]] || fail "unable to resolve latest rw-node-go release"
  printf '%s' "$version"
}

has_rw_node_go_install() {
  [[ -x "$APP_BIN" && -f "$ASSET_DIR/geoip.dat" && -f "$ASSET_DIR/geosite.dat" ]]
}

ensure_rw_node_go() {
  if has_rw_node_go_install; then
    log "rw-node-go already installed; skipping download"
    return 0
  fi

  local asset_name version url tmp_dir archive stage_dir staged_bin staged_geoip staged_geosite
  asset_name="$(detect_asset_name)"
  version="$(resolve_rw_node_go_version)"
  url="https://github.com/$REPO/releases/download/$version/$asset_name"
  tmp_dir="$INSTALL_DIR/tmp"
  archive="$tmp_dir/$asset_name"
  stage_dir="$tmp_dir/stage"
  staged_bin="$stage_dir/rw-node-go"
  staged_geoip="$stage_dir/geoip.dat"
  staged_geosite="$stage_dir/geosite.dat"

  log "installing rw-node-go $version"
  rm -rf "$tmp_dir"
  mkdir -p "$stage_dir" "$BIN_DIR" "$ASSET_DIR"
  download_file "$url" "$archive"
  tar -xzf "$archive" -C "$stage_dir"

  [[ -f "$staged_bin" ]] || fail "rw-node-go release asset is missing rw-node-go"
  [[ -f "$staged_geoip" && -f "$staged_geosite" ]] || fail "rw-node-go release asset is missing geoip.dat or geosite.dat"

  cp "$staged_bin" "$APP_BIN"
  chmod 755 "$APP_BIN"
  cp "$staged_geoip" "$ASSET_DIR/geoip.dat"
  cp "$staged_geosite" "$ASSET_DIR/geosite.dat"
  printf '%s\n' "$version" > "$VERSION_FILE"
  rm -rf "$tmp_dir"
}

write_caddyfile() {
  mkdir -p "$CONF_DIR"
  cat > "$CADDYFILE" <<EOF
{
    admin localhost:2019
    auto_https off
}

http://:$HTTP_FRONT_PORT {
    handle /health {
        respond "ok\n" 200
    }

    handle /xh-* {
        reverse_proxy 127.0.0.1:$XHTTP_UPSTREAM_PORT
    }

    handle /ws-* {
        reverse_proxy 127.0.0.1:$WS_UPSTREAM_PORT
    }

    handle /node/* {
        reverse_proxy https://127.0.0.1:$NODE_PORT {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }

    handle /vision/* {
        reverse_proxy https://127.0.0.1:$NODE_PORT {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }

    handle {
        respond 404
    }
}
EOF
}

cleanup() {
  local code="${1:-0}"
  local pid
  if (( shutting_down )); then
    exit "$code"
  fi
  shutting_down=1

  for pid in "$app_pid" "$caddy_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  sleep 5 &
  local timer_pid=$!
  while kill -0 "$timer_pid" 2>/dev/null; do
    local all_done=1
    for pid in "$app_pid" "$caddy_pid"; do
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        all_done=0
      fi
    done
    (( all_done )) && break
    sleep 0.2
  done
  kill "$timer_pid" 2>/dev/null || true

  for pid in "$app_pid" "$caddy_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  wait "$app_pid" 2>/dev/null || true
  wait "$caddy_pid" 2>/dev/null || true
  exit "$code"
}

handle_signal() {
  cleanup 0
}

inspect_env_if_requested() {
  [[ "${RW_NODE_STARTER_INSPECT_ENV:-}" == "1" ]] || return 0
  printf 'NODE_PORT=%s\n' "$NODE_PORT"
  printf 'NODE_TLS_CLIENT_AUTH=%s\n' "$NODE_TLS_CLIENT_AUTH"
  printf 'INTERNAL_REST_PORT=%s\n' "$INTERNAL_REST_PORT"
  printf 'REQUIRE_SECRET_KEY=%s\n' "$REQUIRE_SECRET_KEY"
  printf 'RW_NODE_DIR=%s\n' "$RW_NODE_DIR"
  printf 'XRAY_LOCATION_ASSET=%s\n' "$XRAY_LOCATION_ASSET"
  printf 'HTTP_FRONT_PORT=%s\n' "$HTTP_FRONT_PORT"
  printf 'XHTTP_UPSTREAM_PORT=%s\n' "$XHTTP_UPSTREAM_PORT"
  printf 'WS_UPSTREAM_PORT=%s\n' "$WS_UPSTREAM_PORT"
  printf 'CADDY_BIN=%s\n' "${CADDY_BIN:-}"
  printf 'CADDY_VERSION=%s\n' "${CADDY_VERSION:-}"
  printf 'RW_NODE_GO_VERSION=%s\n' "${RW_NODE_GO_VERSION:-}"
  exit 0
}

dry_run_if_requested() {
  [[ -n "${RW_NODE_STARTER_DRY_RUN_EXIT:-}" ]] || return 0
  [[ "$RW_NODE_STARTER_DRY_RUN_EXIT" =~ ^[0-9]+$ ]] || fail "RW_NODE_STARTER_DRY_RUN_EXIT must be numeric"
  exit "$RW_NODE_STARTER_DRY_RUN_EXIT"
}

main() {
  cd "$CWD"
  load_env_file
  set_default_env
  inspect_env_if_requested
  dry_run_if_requested

  require_command curl
  require_command tar
  ensure_linux
  validate_ports

  ensure_caddy
  ensure_rw_node_go
  write_caddyfile
  mkdir -p "$CADDY_DATA_DIR" "$CADDY_CONFIG_DIR"

  HOME="$CWD" XDG_DATA_HOME="$CADDY_DATA_DIR" XDG_CONFIG_HOME="$CADDY_CONFIG_DIR" \
    "$caddy_bin_resolved" validate --config "$CADDYFILE" --adapter caddyfile

  trap handle_signal INT TERM

  log "starting Caddy on port $HTTP_FRONT_PORT"
  HOME="$CWD" XDG_DATA_HOME="$CADDY_DATA_DIR" XDG_CONFIG_HOME="$CADDY_CONFIG_DIR" \
    "$caddy_bin_resolved" run --config "$CADDYFILE" --adapter caddyfile &
  caddy_pid=$!

  log "starting rw-node-go"
  "$APP_BIN" &
  app_pid=$!

  while true; do
    if ! kill -0 "$caddy_pid" 2>/dev/null; then
      wait "$caddy_pid" || true
      log "caddy exited"
      cleanup 1
    fi
    if ! kill -0 "$app_pid" 2>/dev/null; then
      wait "$app_pid" || true
      log "rw-node-go exited"
      cleanup 1
    fi
    sleep 0.5
  done
}

main "$@"
