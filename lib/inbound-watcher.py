#!/usr/bin/env python3
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.error

LOG_PREFIX = os.environ.get("LOG_PREFIX", "[rw-node]")
INTERNAL_REST_PORT = os.environ.get("INTERNAL_REST_PORT", "61001")
CADDY_ADMIN_SOCK = os.environ.get("CADDY_ADMIN_SOCK", "/tmp/caddy-admin.sock")
CADDY_BIN = os.environ.get("CADDY_BIN", "caddy")
INBOUND_WATCHER_INTERVAL = int(os.environ.get("INBOUND_WATCHER_INTERVAL", "15"))
HTTP_FRONT_PORT = os.environ.get("HTTP_FRONT_PORT", "3000")
NODE_PORT = os.environ.get("NODE_PORT", "2222")
XHTTP_UPSTREAM_PORT = os.environ.get("XHTTP_UPSTREAM_PORT", "8080")
WS_UPSTREAM_PORT = os.environ.get("WS_UPSTREAM_PORT", "8880")
CADDY_SITE_DIR = os.environ.get("CADDY_SITE_DIR", "")


def log(msg: str) -> None:
    print(f"{LOG_PREFIX} {msg}", flush=True)


def http_get(url: str, timeout: int = 5) -> str:
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode()


def normalize_path(p: str) -> str:
    if not p:
        return ""
    normalized = p.split("?")[0].split("#")[0]
    if normalized and not normalized.startswith("/"):
        normalized = "/" + normalized
    return normalized


def get_http_path(stream_settings: dict) -> str:
    network = stream_settings.get("network", "")
    if network == "ws":
        return stream_settings.get("wsSettings", {}).get("path", "")
    elif network == "xhttp":
        return stream_settings.get("xhttpSettings", {}).get("path", "")
    elif network == "httpupgrade":
        return stream_settings.get("httpupgradeSettings", {}).get("path", "")
    return ""


def extract_inbound_config(config: dict) -> dict:
    inbounds = config.get("inbounds", [])
    reality_routes: list[dict] = []
    http_path_candidates: list[dict] = []

    for ib in inbounds:
        stream = ib.get("streamSettings")
        if not stream:
            continue

        if stream.get("security") == "reality":
            names = stream.get("realitySettings", {}).get("serverNames", [])
            port = ib.get("port")
            if names and port:
                reality_routes.append({"port": port, "serverNames": names})
            continue

        network = stream.get("network", "")
        if network in ("ws", "xhttp", "httpupgrade"):
            raw_path = get_http_path(stream)
            normalized = normalize_path(raw_path)
            if normalized:
                http_path_candidates.append({
                    "path": normalized,
                    "port": ib.get("port"),
                    "network": network,
                    "tag": ib.get("tag", f"port:{ib.get('port')}"),
                })

    merged_reality = merge_reality_routes(reality_routes)
    http_routes, conflicts = resolve_http_routes(http_path_candidates)
    panel_sni = config.get("panelSni")
    if not isinstance(panel_sni, str):
        panel_sni = ""

    return {
        "realityRoutes": merged_reality,
        "httpRoutes": http_routes,
        "conflicts": conflicts,
        "panelSni": panel_sni,
    }


def merge_reality_routes(routes: list[dict]) -> list[dict]:
    by_port: dict[int, set] = {}
    for r in routes:
        existing = by_port.setdefault(r["port"], set())
        existing.update(r["serverNames"])
    return [
        {"port": port, "serverNames": sorted(names)}
        for port, names in sorted(by_port.items())
    ]


def resolve_http_routes(candidates: list[dict]) -> tuple[list[dict], list[dict]]:
    by_path: dict[str, list[dict]] = {}
    for c in candidates:
        by_path.setdefault(c["path"], []).append(c)

    routes = []
    conflicts = []

    for p, entries in by_path.items():
        ports = set(e["port"] for e in entries)
        if len(ports) == 1:
            routes.append(entries[0])
        else:
            conflicts.append({
                "path": p,
                "tags": [f"{e['tag']}(port:{e['port']})" for e in entries],
            })

    routes.sort(key=lambda r: -len(r["path"]))
    return routes, conflicts


def generate_l4_route_block(reality_routes: list[dict], panel_sni: str = "") -> str:
    lines = []
    if panel_sni:
        lines.append(f"                @panel tls sni {panel_sni}")
        lines.append(f"                route @panel {{")
        lines.append(f"                    proxy 127.0.0.1:{NODE_PORT}")
        lines.append(f"                }}")
    if not reality_routes:
        return "\n".join(lines)
    for r in reality_routes:
        snis = " ".join(r["serverNames"])
        matcher = "reality" if len(reality_routes) == 1 else f"reality_{r['port']}"
        lines.append(f"                @{matcher} tls sni {snis}")
        lines.append(f"                route @{matcher} {{")
        lines.append(f"                    proxy 127.0.0.1:{r['port']}")
        lines.append(f"                }}")
    return "\n".join(lines)


def generate_http_route_block(http_routes: list[dict]) -> str:
    if not http_routes:
        lines = [
            f"    handle /xh-* {{",
            f"        reverse_proxy 127.0.0.1:{XHTTP_UPSTREAM_PORT} {{",
            f"            flush_interval -1",
            f"        }}",
            f"    }}",
            f"",
            f"    handle /ws-* {{",
            f"        reverse_proxy 127.0.0.1:{WS_UPSTREAM_PORT} {{",
            f"            flush_interval -1",
            f"        }}",
            f"    }}",
        ]
        return "\n".join(lines)

    lines = []
    for i, r in enumerate(http_routes):
        path_pattern = r["path"] if r["path"].endswith("*") else f"{r['path']}*"
        lines.append(f"    handle {path_pattern} {{")
        lines.append(f"        reverse_proxy 127.0.0.1:{r['port']} {{")
        lines.append(f"            flush_interval -1")
        lines.append(f"        }}")
        lines.append(f"    }}")
        if i < len(http_routes) - 1:
            lines.append("")
    return "\n".join(lines)


def generate_caddy_config(l4_block: str, http_block: str, panel_sni: str = "") -> str:
    template_path = os.path.join(os.path.dirname(__file__), "Caddyfile.template")
    with open(template_path) as f:
        content = f.read()

    admin_line = (
        f"admin unix/{CADDY_ADMIN_SOCK}"
        if os.environ.get("INBOUND_WATCHER_ENABLED", "true") != "false"
        else "admin off"
    )

    # Upstream SNI for the node API when SNI_VERIFICATION is enabled on the
    # node; the derived hostname is public tooling metadata, not a secret.
    tls_server_name_line = f"                tls_server_name {panel_sni}" if panel_sni else ""

    replacements = {
        "${CADDY_ADMIN_LINE}": admin_line,
        "${L4_ROUTE_BLOCK}": l4_block,
        "${HTTP_ROUTE_BLOCK}": http_block,
        "${HTTP_FRONT_PORT}": HTTP_FRONT_PORT,
        "${NODE_PORT}": NODE_PORT,
        "${NODE_TLS_SERVER_NAME}": tls_server_name_line,
        "${CADDY_SITE_DIR}": CADDY_SITE_DIR,
    }
    for placeholder, value in replacements.items():
        content = content.replace(placeholder, value)

    return content


def hash_string(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


def caddy_fmt(config_path: str) -> None:
    try:
        subprocess.run(
            [CADDY_BIN, "fmt", "--overwrite", config_path],
            capture_output=True,
            timeout=5,
            check=False,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass


def caddy_reload(config_path: str) -> bool:
    try:
        subprocess.run(
            [
                CADDY_BIN,
                "reload",
                "--config",
                config_path,
                "--adapter",
                "caddyfile",
                "--address",
                f"unix/{CADDY_ADMIN_SOCK}",
            ],
            capture_output=True,
            timeout=10,
            check=True,
        )
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return False


def wait_for_port(port: int, max_wait: int = 120) -> None:
    deadline = time.monotonic() + max_wait
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(1)


def main(config_path=None) -> int:
    if config_path is None:
        if len(sys.argv) < 2:
            print(
                f"{LOG_PREFIX} ERROR: inbound-watcher.py requires config_path argument",
                file=sys.stderr,
            )
            return 1
        config_path = sys.argv[1]
    wait_for_port(int(INTERNAL_REST_PORT))

    prev_hash = ""
    internal_url = f"http://127.0.0.1:{INTERNAL_REST_PORT}/internal/get-config"
    first_run = True

    while True:
        if first_run:
            first_run = False
        else:
            time.sleep(INBOUND_WATCHER_INTERVAL)

        try:
            raw = http_get(internal_url)
            config = json.loads(raw)
        except Exception:
            continue

        if not config:
            if isinstance(config, dict) and config.get("panelSni"):
                # Panel SNI alone is still routeable: it feeds the node API
                # upstream SNI before the first xray start.
                pass
            else:
                continue

        result = extract_inbound_config(config)
        reality_routes = result["realityRoutes"]
        http_routes = result["httpRoutes"]
        conflicts = result["conflicts"]
        panel_sni = result["panelSni"]

        hash_input = json.dumps(
            {"realityRoutes": reality_routes, "httpRoutes": http_routes, "panelSni": panel_sni},
            sort_keys=True,
        )
        current_hash = hash_string(hash_input)

        if current_hash == prev_hash:
            continue

        prev_hash = current_hash

        for c in conflicts:
            log(f"WARN: HTTP route conflict: path={c['path']} claimed by [{', '.join(c['tags'])}], skipped")

        if panel_sni:
            log(f"L4 route: PANEL sni={panel_sni} -> 127.0.0.1:{NODE_PORT}")

        if reality_routes:
            for r in reality_routes:
                log(f"L4 route: REALITY snis=[{' '.join(r['serverNames'])}] -> 127.0.0.1:{r['port']}")

        if http_routes:
            for r in http_routes:
                log(f"HTTP route: {r['path']} [{r['network']}] -> 127.0.0.1:{r['port']}")
        elif reality_routes or conflicts:
            log("No HTTP path inbounds detected, using fallback wildcard routes")

        if not reality_routes and not http_routes and not conflicts:
            if panel_sni:
                log("Only panel SNI detected, using default HTTP routes")
            else:
                log("No routeable inbounds detected, using default config")

        l4_block = generate_l4_route_block(reality_routes, panel_sni)
        http_block = generate_http_route_block(http_routes)

        with open(config_path, "w") as f:
            f.write(generate_caddy_config(l4_block, http_block, panel_sni))

        caddy_fmt(config_path)

        if caddy_reload(config_path):
            log("Caddy reloaded with updated inbound routing config")
        else:
            log("WARN: Caddy reload failed, will retry next cycle")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
