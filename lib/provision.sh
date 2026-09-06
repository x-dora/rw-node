#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n "${_RW_NODE_PROVISION_LOADED:-}" ]] && return 0
_RW_NODE_PROVISION_LOADED=1

_PROVISION_LIB_DIR="${_PROVISION_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
# shellcheck source=core.sh
[[ -n "${_RW_NODE_CORE_LOADED:-}" ]] || source "${_PROVISION_LIB_DIR}/core.sh"

PROVISION_REPO="${PROVISION_REPO:-x-dora/rw-node-go}"
CLOUDFLARED_REPO="${CLOUDFLARED_REPO:-cloudflare/cloudflared}"
GEOCHECK_REPO="${GEOCHECK_REPO:-remnawave/geocheck}"
GEOCHECK_VERSION_DEFAULT="${GEOCHECK_VERSION_DEFAULT:-0.3.0}"

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

find_release_asset_download_url() {
  local release_json="$1"
  local asset_name="$2"
  local url name

  while IFS= read -r url; do
    name="${url##*/}"
    if [[ "$name" == "$asset_name" ]]; then
      printf '%s' "$url"
      return 0
    fi
  done < <(
    grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$release_json" \
      | sed -E 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)"/\1/'
  )
}

resolve_rw_node_go_version() {
  if [[ -n "${RW_NODE_GO_VERSION:-}" ]]; then
    printf '%s' "$RW_NODE_GO_VERSION"
    return 0
  fi

  local version
  version="$(resolve_latest_tag "$PROVISION_REPO")"
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
  asset_name="$(detect_rw_node_go_asset_name)"
  version="$(resolve_rw_node_go_version)"
  url="https://github.com/$PROVISION_REPO/releases/download/$version/$asset_name"
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

ensure_caddy() {
  if [[ -n "${CADDY_BIN:-}" && -x "${CADDY_BIN}" ]]; then
    log "Caddy already available at ${CADDY_BIN}; skipping download"
    return 0
  fi

  if [[ -x "$CADDY_BIN_DEFAULT" ]]; then
    log "Caddy already installed; skipping download"
    CADDY_BIN="$CADDY_BIN_DEFAULT"
    return 0
  fi

  local arch url
  arch="$(detect_arch)"
  url="https://caddyserver.com/api/download?os=linux&arch=${arch}&p=github.com/mholt/caddy-l4"

  log "downloading Caddy with layer4 plugin (linux/$arch)"
  mkdir -p "$BIN_DIR"
  download_file "$url" "$CADDY_BIN_DEFAULT"
  chmod 755 "$CADDY_BIN_DEFAULT"
  CADDY_BIN="$CADDY_BIN_DEFAULT"
}

ensure_geocheck() {
  # Best-effort: the stats/get-geocheck route degrades to error A018 when the
  # binary is missing, so failures only warn.
  if [[ -x "$GEOCHECK_BIN_DEFAULT" ]]; then
    log "geocheck already installed; skipping download"
    return 0
  fi

  local version release_json archive tmp_dir
  version="v${GEOCHECK_VERSION_DEFAULT}"
  if [[ "${GEOCHECK_VERSION:-}" != "" ]]; then
    version="${GEOCHECK_VERSION}"
    [[ "$version" == v* ]] || version="v${version}"
  fi

  release_json="$(github_api_get "https://api.github.com/repos/$GEOCHECK_REPO/releases/tags/$version")"
  [[ -n "$release_json" ]] || fail "unable to resolve geocheck release $version"

  tmp_dir="$INSTALL_DIR/tmp/geocheck"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir" "$BIN_DIR"

  log "installing geocheck $version"
  archive="$(find_release_asset_download_url "$release_json" "geocheck_linux_$(detect_arch).tar.gz")"
  [[ -n "$archive" ]] || fail "geocheck $version does not provide a linux/$(detect_arch) archive"

  download_file "$archive" "$tmp_dir/geocheck.tar.gz"
  download_file "${archive%/*}/checksums.txt" "$tmp_dir/checksums.txt"
  (cd "$tmp_dir" && grep "  geocheck_linux_$(detect_arch).tar.gz\$" checksums.txt | sha256sum -c -) \
    || { rm -rf "$tmp_dir"; fail "geocheck archive checksum mismatch"; }

  tar -xzf "$tmp_dir/geocheck.tar.gz" -C "$tmp_dir" geocheck
  cp "$tmp_dir/geocheck" "$GEOCHECK_BIN_DEFAULT"
  chmod 755 "$GEOCHECK_BIN_DEFAULT"
  printf '%s\n' "$version" > "$GEOCHECK_VERSION_FILE"
  rm -rf "$tmp_dir"
}

resolve_cloudflared_release_json() {
  if [[ -n "${CLOUDFLARED_VERSION:-}" ]]; then
    github_api_get "https://api.github.com/repos/$CLOUDFLARED_REPO/releases/tags/$CLOUDFLARED_VERSION"
  else
    github_api_get "https://api.github.com/repos/$CLOUDFLARED_REPO/releases/latest"
  fi
}

ensure_cloudflared() {
  if [[ -n "${CLOUDFLARED_BIN:-}" && -x "${CLOUDFLARED_BIN}" ]]; then
    log "cloudflared already available at ${CLOUDFLARED_BIN}; skipping download"
    return 0
  fi

  if [[ -x "$CLOUDFLARED_BIN_DEFAULT" ]]; then
    log "cloudflared already installed; skipping download"
    CLOUDFLARED_BIN="$CLOUDFLARED_BIN_DEFAULT"
    return 0
  fi

  local release_json tag asset_name url tmp_dir staged_bin
  release_json="$(resolve_cloudflared_release_json)"
  tag="$(extract_json_string "tag_name" <<< "$release_json")"
  [[ -n "$tag" ]] || fail "unable to resolve cloudflared release assets"
  asset_name="$(detect_cloudflared_asset_name)"
  url="$(find_release_asset_download_url "$release_json" "$asset_name")"
  [[ -n "$url" ]] || fail "cloudflared $tag does not provide $asset_name"
  tmp_dir="$INSTALL_DIR/tmp"
  staged_bin="$tmp_dir/$asset_name"

  log "installing cloudflared $tag"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir" "$BIN_DIR"
  download_file "$url" "$staged_bin"
  cp "$staged_bin" "$CLOUDFLARED_BIN_DEFAULT"
  chmod 755 "$CLOUDFLARED_BIN_DEFAULT"
  printf '%s\n' "$tag" > "$CLOUDFLARED_VERSION_FILE"
  rm -rf "$tmp_dir"
  CLOUDFLARED_BIN="$CLOUDFLARED_BIN_DEFAULT"
}
