#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
from pathlib import Path


PREFIX = "[python-starter]"
ROOT_DIR = Path(__file__).resolve().parent
START_SCRIPT = ROOT_DIR / "start.sh"
INSTALL_DIR = ROOT_DIR / ".rw-node"

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

    os.environ.setdefault("HTTP_FRONT_PORT", os.environ.get("PORT", "3000"))
    # 前置实现换成 rw-node-front 后，原来那组 CADDY_*（HTTP 端口、socket 路径、
    # 二进制路径）都不再被任何东西读取，只保留静态页目录。
    os.environ.setdefault("FRONT_SITE_DIR", str(INSTALL_DIR / "www"))

    child_process = subprocess.Popen(
        ["bash", str(START_SCRIPT)],
        cwd=ROOT_DIR,
        env=os.environ.copy(),
    )

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
