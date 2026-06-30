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
REALITY_SPLIT_INTERVAL = int(os.environ.get("REALITY_SPLIT_INTERVAL", "15"))
HTTP_FRONT_PORT = os.environ.get("HTTP_FRONT_PORT", "3000")
NODE_PORT = os.environ.get("NODE_PORT", "2222")
CADDY_HTTP_PORT = os.environ.get("CADDY_HTTP_PORT", str(int(HTTP_FRONT_PORT) + 1))
XHTTP_UPSTREAM_PORT = os.environ.get("XHTTP_UPSTREAM_PORT", "8080")
WS_UPSTREAM_PORT = os.environ.get("WS_UPSTREAM_PORT", "8880")
CADDY_SITE_DIR = os.environ.get("CADDY_SITE_DIR", "")


def log(msg: str) -> None:
    print(f"{LOG_PREFIX} {msg}", flush=True)


def http_get(url: str, timeout: int = 5) -> str:
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode()


def extract_reality_config(config: dict) -> tuple[str, str]:
    inbounds = config.get("inbounds", [])
    reality_inbounds = [
        ib
        for ib in inbounds
        if ib.get("streamSettings", {}).get("security") == "reality"
    ]

    if not reality_inbounds:
        return "", ""

    port = str(reality_inbounds[0].get("port", ""))
    all_names: set[str] = set()
    for ib in reality_inbounds:
        names = (
            ib.get("streamSettings", {})
            .get("realitySettings", {})
            .get("serverNames", [])
        )
        all_names.update(names)

    if not all_names:
        return "", ""

    return port, " ".join(sorted(all_names))


def generate_caddy_config(reality_snis: str, reality_port: str) -> str:
    template_path = os.path.join(os.path.dirname(__file__), "Caddyfile.template")
    with open(template_path) as f:
        content = f.read()

    admin_line = f"admin unix/{CADDY_ADMIN_SOCK}"
    reality_block = ""
    if reality_snis and reality_port:
        reality_block = "\n".join([
            f"            @reality tls sni {reality_snis}",
            "            route @reality {",
            f"                proxy 127.0.0.1:{reality_port}",
            "            }",
        ])

    replacements = {
        "${CADDY_ADMIN_LINE}": admin_line,
        "${REALITY_ROUTE_BLOCK}": reality_block,
        "${HTTP_FRONT_PORT}": HTTP_FRONT_PORT,
        "${NODE_PORT}": NODE_PORT,
        "${CADDY_HTTP_PORT}": CADDY_HTTP_PORT,
        "${XHTTP_UPSTREAM_PORT}": XHTTP_UPSTREAM_PORT,
        "${WS_UPSTREAM_PORT}": WS_UPSTREAM_PORT,
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
                f"{LOG_PREFIX} ERROR: reality-watcher.py requires config_path argument",
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
            time.sleep(REALITY_SPLIT_INTERVAL)

        try:
            raw = http_get(internal_url)
            config = json.loads(raw)
        except Exception:
            continue

        if not config:
            continue

        reality_port, reality_snis = extract_reality_config(config)
        current_hash = hash_string(f"{reality_port}\n{reality_snis}")

        if current_hash == prev_hash:
            continue

        prev_hash = current_hash

        if reality_snis and reality_port:
            log(f"REALITY split detected: snis=[{reality_snis}] port={reality_port}")
        else:
            log("REALITY split cleared, reverting to default TLS routing")

        with open(config_path, "w") as f:
            f.write(generate_caddy_config(reality_snis, reality_port))

        caddy_fmt(config_path)

        if caddy_reload(config_path):
            log("Caddy reloaded with updated REALITY split config")
        else:
            log("WARN: Caddy reload failed, will retry next cycle")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
