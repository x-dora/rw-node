#!/usr/bin/env bash
set -euo pipefail

PREFIX="[bash-starter]"
LOG_PREFIX="$PREFIX"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CWD="$SCRIPT_DIR"
INSTALL_DIR="$CWD/.rw-node"
BIN_DIR="$INSTALL_DIR/bin"
ASSET_DIR="$INSTALL_DIR/share/xray"
CADDY_CONF_DIR="$INSTALL_DIR/conf/caddy"
CADDY_DATA_DIR="$INSTALL_DIR/caddy/data"
CADDY_CONFIG_DIR="$INSTALL_DIR/caddy/config"
CADDY_ADMIN_SOCK="$INSTALL_DIR/caddy/admin.sock"
CADDY_SITE_DIR="${CADDY_SITE_DIR:-${INSTALL_DIR}/www}"
CADDY_DEFAULT_SITE_DIR="${CADDY_DEFAULT_SITE_DIR:-}"
APP_BIN="$BIN_DIR/rw-node-go"
CADDY_BIN_DEFAULT="$BIN_DIR/caddy"
CLOUDFLARED_BIN_DEFAULT="$BIN_DIR/cloudflared"
VERSION_FILE="$INSTALL_DIR/.rw-node-go-version"
CLOUDFLARED_VERSION_FILE="$INSTALL_DIR/.cloudflared-version"
LIB_DIR="$INSTALL_DIR/lib"

LIB_REPO="${LIB_REPO:-x-dora/rw-node}"
LIB_VERSION="${LIB_VERSION:-main}"

LIB_FILES=(
  core.sh
  caddy.sh
  provision.sh
  cloudflared.sh
  reality-watcher.js
  reality-watcher.py
  Caddyfile.template
)

log() {
  printf '%s %s\n' "$PREFIX" "$*"
}

fail() {
  printf '%s ERROR: %s\n' "$PREFIX" "$*" >&2
  exit 1
}

ensure_lib() {
  local all_present=1
  for f in "${LIB_FILES[@]}"; do
    if [[ ! -f "$LIB_DIR/$f" ]]; then
      all_present=0
      break
    fi
  done
  if (( all_present )); then
    return 0
  fi

  log "downloading shared libraries from $LIB_REPO@$LIB_VERSION"
  mkdir -p "$LIB_DIR"

  local base_url="https://raw.githubusercontent.com/$LIB_REPO/$LIB_VERSION/lib"
  for f in "${LIB_FILES[@]}"; do
    if [[ -f "$LIB_DIR/$f" ]]; then
      continue
    fi
    log "  fetching lib/$f"
    if ! curl -fsSL -o "$LIB_DIR/$f" "$base_url/$f"; then
      rm -f "$LIB_DIR/$f"
      fail "failed to download lib/$f from $base_url/$f"
    fi
  done
}

ensure_lib

_CADDY_LIB_DIR="$LIB_DIR"
_PROVISION_LIB_DIR="$LIB_DIR"
_CLOUDFLARED_LIB_DIR="$LIB_DIR"

# shellcheck source=/dev/null
source "$LIB_DIR/core.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/caddy.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/provision.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/cloudflared.sh"

RW_NODE_DIR_DEFAULT="$CWD"
XRAY_LOCATION_ASSET_DEFAULT="$ASSET_DIR"
ENV_FILE="$CWD/.env"

caddy_pid=""
app_pid=""
cloudflared_pid=""
cloudflared_mode=""
watcher_pid=""
shutting_down=0

CADDY_HOME="$CWD"
CADDY_XDG_DATA_HOME="$CADDY_DATA_DIR"
CADDY_XDG_CONFIG_HOME="$CADDY_CONFIG_DIR"

cleanup() {
  local code="${1:-0}"
  local pid
  if (( shutting_down )); then
    exit "$code"
  fi
  shutting_down=1

  for pid in "$app_pid" "$caddy_pid" "$cloudflared_pid" "$watcher_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  sleep 5 &
  local timer_pid=$!
  while kill -0 "$timer_pid" 2>/dev/null; do
    local all_done=1
    for pid in "$app_pid" "$caddy_pid" "$cloudflared_pid" "$watcher_pid"; do
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        all_done=0
      fi
    done
    (( all_done )) && break
    sleep 0.2
  done
  kill "$timer_pid" 2>/dev/null || true

  for pid in "$app_pid" "$caddy_pid" "$cloudflared_pid" "$watcher_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  wait "$app_pid" 2>/dev/null || true
  wait "$caddy_pid" 2>/dev/null || true
  wait "$cloudflared_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  exit "$code"
}

handle_signal() {
  cleanup 0
}

main() {
  cd "$CWD"
  load_env_file
  set_default_env
  inspect_env_if_requested
  dry_run_if_requested

  require_command curl
  require_command mktemp
  require_command tar
  ensure_linux
  validate_ports

  ensure_caddy
  CADDY_BIN="${CADDY_BIN:-$CADDY_BIN_DEFAULT}"
  export CADDY_BIN

  ensure_rw_node_go
  if cloudflare_tunnel_enabled; then
    ensure_cloudflared
    CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-$CLOUDFLARED_BIN_DEFAULT}"
  fi

  CADDY_SKIP_PORT_WAIT=1
  mkdir -p "$CADDY_DATA_DIR" "$CADDY_CONFIG_DIR"
  start_caddy_front

  trap handle_signal INT TERM

  log "starting rw-node-go"
  "$APP_BIN" &
  app_pid=$!

  if [[ "${REALITY_SPLIT_ENABLED:-true}" == "true" && "${REALITY_WATCHER_EXTERNAL:-}" != "true" ]]; then
    start_reality_watcher "$CADDY_CONF_DIR/Caddyfile" &
    watcher_pid=$!
  fi

  if cloudflare_tunnel_enabled; then
    run_cloudflared_default
  fi

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
    if [[ -n "$cloudflared_pid" ]] && ! kill -0 "$cloudflared_pid" 2>/dev/null; then
      wait "$cloudflared_pid" || true
      if [[ "$cloudflared_mode" == "default" ]]; then
        log "cloudflared default startup failed; retrying with fixed edge addresses"
        cloudflared_pid=""
        run_cloudflared_fixed_edge
        sleep 0.5
        continue
      fi
      log "cloudflared fixed-edge startup failed; continuing without Cloudflare Tunnel"
      cloudflared_pid=""
      cloudflared_mode=""
    fi
    sleep 0.5
  done
}

main "$@"
