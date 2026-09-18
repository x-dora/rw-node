#!/usr/bin/env bash
set -euo pipefail

PREFIX="[bash-starter]"
LOG_PREFIX="$PREFIX"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CWD="$SCRIPT_DIR"
INSTALL_DIR="$CWD/.rw-node"
BIN_DIR="$INSTALL_DIR/bin"
ASSET_DIR="$INSTALL_DIR/share/xray"
# 兼容改造前的 CADDY_SITE_DIR：老部署的 .env 里写的是旧名字。
FRONT_SITE_DIR="${FRONT_SITE_DIR:-${CADDY_SITE_DIR:-${INSTALL_DIR}/www}}"
FRONT_DEFAULT_SITE_DIR="${FRONT_DEFAULT_SITE_DIR:-${CADDY_DEFAULT_SITE_DIR:-}}"
SITE_BUILD_DIR="${SITE_BUILD_DIR:-${INSTALL_DIR}/conf/site}"
APP_BIN="$BIN_DIR/rw-node-go"
FRONT_BIN_DEFAULT="$BIN_DIR/rw-node-front"
FRONT_VERSION_FILE="$INSTALL_DIR/.rw-node-front-version"
CLOUDFLARED_BIN_DEFAULT="$BIN_DIR/cloudflared"
VERSION_FILE="$INSTALL_DIR/.rw-node-go-version"
CLOUDFLARED_VERSION_FILE="$INSTALL_DIR/.cloudflared-version"
GEOCHECK_BIN_DEFAULT="$BIN_DIR/geocheck"
GEOCHECK_VERSION_FILE="$INSTALL_DIR/.geocheck-version"
SSHD_LITE_BIN_DEFAULT="$BIN_DIR/sshd-lite"
SSH_DIR="$INSTALL_DIR/ssh"
LIB_DIR="$INSTALL_DIR/lib"

LIB_REPO="${LIB_REPO:-x-dora/rw-node}"
LIB_VERSION="${LIB_VERSION:-main}"

LIB_FILES=(
  core.sh
  front.sh
  site.sh
  ssh.sh
  provision.sh
  cloudflared.sh
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

_FRONT_LIB_DIR="$LIB_DIR"
_SITE_LIB_DIR="$LIB_DIR"
_SSH_LIB_DIR="$LIB_DIR"
_PROVISION_LIB_DIR="$LIB_DIR"
_CLOUDFLARED_LIB_DIR="$LIB_DIR"

# shellcheck source=/dev/null
source "$LIB_DIR/core.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/front.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/ssh.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/provision.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/cloudflared.sh"

RW_NODE_DIR_DEFAULT="$CWD"
XRAY_LOCATION_ASSET_DEFAULT="$ASSET_DIR"
ENV_FILE="$CWD/.env"

front_pid=""
app_pid=""
cloudflared_pid=""
cloudflared_mode=""
ssh_service_pid=""
shutting_down=0

cleanup() {
  local code="${1:-0}"
  local pid
  if (( shutting_down )); then
    exit "$code"
  fi
  shutting_down=1

  for pid in "$app_pid" "$front_pid" "$cloudflared_pid" "$ssh_service_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  sleep 5 &
  local timer_pid=$!
  while kill -0 "$timer_pid" 2>/dev/null; do
    local all_done=1
    for pid in "$app_pid" "$front_pid" "$cloudflared_pid" "$ssh_service_pid"; do
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        all_done=0
      fi
    done
    (( all_done )) && break
    sleep 0.2
  done
  kill "$timer_pid" 2>/dev/null || true

  for pid in "$app_pid" "$front_pid" "$cloudflared_pid" "$ssh_service_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  for pid in "$app_pid" "$front_pid" "$cloudflared_pid" "$ssh_service_pid"; do
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
  done
  exit "$code"
}

handle_signal() {
  cleanup 0
}

install_geocheck() {
  # Best-effort: /node/stats/get-geocheck degrades to error A018 without the
  # binary, so a download failure must not abort startup. ensure_geocheck calls
  # fail(), which exits, so it runs in a subshell to contain that exit.
  if [[ -n "${GEOCHECK_BINARY_PATH:-}" ]]; then
    return 0
  fi

  if (ensure_geocheck); then
    GEOCHECK_BINARY_PATH="$GEOCHECK_BIN_DEFAULT"
    export GEOCHECK_BINARY_PATH
    log "geocheck ready at $GEOCHECK_BINARY_PATH"
    return 0
  fi

  log "WARN: geocheck install failed; get-geocheck will degrade to A018"
}

main() {
  cd "$CWD"
  load_env_file
  set_default_env

  require_command curl
  require_command mktemp
  require_command tar
  ensure_linux
  validate_ports

  ensure_front_proxy
  FRONT_BIN="${FRONT_BIN:-$FRONT_BIN_DEFAULT}"
  export FRONT_BIN

  ensure_rw_node_go
  install_geocheck

  if [[ "${SSH_ENABLED:-false}" == "true" ]]; then
    # Best-effort: 拿不到 sshd-lite 只是没有 SSH 入口，不应阻塞节点启动。
    # ensure_sshd_lite 失败时会调用 fail() 退出，因此放进子 shell 收敛退出码；
    # 子 shell 内的变量赋值不会回传，二进制路径统一在这里补齐。
    if (ensure_sshd_lite); then
      SSHD_LITE_BIN="${SSHD_LITE_BIN:-$SSHD_LITE_BIN_DEFAULT}"
      export SSHD_LITE_BIN
      log "sshd-lite ready at $SSHD_LITE_BIN"
    else
      log "WARN: sshd-lite install failed; SSH entry stays disabled"
    fi
  fi

  if cloudflare_tunnel_enabled; then
    ensure_cloudflared
    CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-$CLOUDFLARED_BIN_DEFAULT}"
  fi

  FRONT_SKIP_PORT_WAIT=1
  mkdir -p "$SITE_BUILD_DIR"
  start_ssh_service
  start_front_proxy

  trap handle_signal INT TERM

  log "starting rw-node-go"
  "$APP_BIN" &
  app_pid=$!

  if cloudflare_tunnel_enabled; then
    run_cloudflared_default
  fi

  while true; do
    if ! kill -0 "$front_pid" 2>/dev/null; then
      wait "$front_pid" || true
      log "front proxy exited"
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
