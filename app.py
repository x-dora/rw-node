#!/usr/bin/env python3
import importlib.util
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path


PREFIX = "[python-starter]"
ROOT_DIR = Path(__file__).resolve().parent
START_SCRIPT = ROOT_DIR / "start.sh"
INSTALL_DIR = ROOT_DIR / ".rw-node"
WATCHER_SCRIPT = INSTALL_DIR / "lib" / "reality-watcher.py"
WATCHER_CONFIG_PATH = str(INSTALL_DIR / "conf" / "caddy" / "Caddyfile")

child_process = None
shutting_down = False


def load_env_file(filepath: Path) -> None:
    if not filepath.exists():
        return
    for line in filepath.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        eq = line.find("=")
        if eq < 0:
            continue
        key = line[:eq].strip()
        val = line[eq + 1 :].strip()
        if len(val) >= 2 and val[0] in ('"', "'") and val[-1] == val[0]:
            val = val[1:-1]
        os.environ.setdefault(key, val)


def run_watcher() -> None:
    while not WATCHER_SCRIPT.exists():
        time.sleep(0.5)
    spec = importlib.util.spec_from_file_location(
        "reality_watcher", str(WATCHER_SCRIPT)
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.main(WATCHER_CONFIG_PATH)


def terminate(signum: int) -> None:
    global shutting_down
    if shutting_down:
        return
    shutting_down = True

    if child_process and child_process.poll() is None:
        try:
            child_process.send_signal(signum)
        except ProcessLookupError:
            pass


def handle_signal(signum, _frame) -> None:
    terminate(signum)


def main() -> int:
    global child_process

    if not START_SCRIPT.exists():
        print(
            f"{PREFIX} ERROR: missing start script: {START_SCRIPT}",
            file=sys.stderr,
            flush=True,
        )
        return 1

    load_env_file(ROOT_DIR / ".env")

    os.environ.setdefault(
        "CADDY_ADMIN_SOCK", str(INSTALL_DIR / "caddy" / "admin.sock")
    )
    os.environ.setdefault("CADDY_BIN", str(INSTALL_DIR / "bin" / "caddy"))
    os.environ.setdefault("CADDY_SITE_DIR", str(INSTALL_DIR / "www"))

    child_process = subprocess.Popen(
        ["bash", str(START_SCRIPT)],
        cwd=ROOT_DIR,
        env={**os.environ, "REALITY_WATCHER_EXTERNAL": "true"},
    )

    if os.environ.get("REALITY_SPLIT_ENABLED", "true") != "false":
        threading.Thread(target=run_watcher, daemon=True).start()

    return_code = child_process.wait()
    if return_code < 0:
        signum = -return_code
        os.kill(os.getpid(), signum)
        return 128 + signum
    return return_code


signal.signal(signal.SIGINT, handle_signal)
signal.signal(signal.SIGTERM, handle_signal)

if __name__ == "__main__":
    raise SystemExit(main())
