#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
from pathlib import Path


PREFIX = "[python-starter]"
ROOT_DIR = Path(__file__).resolve().parent
START_SCRIPT = ROOT_DIR / "start.sh"

child_process = None
shutting_down = False


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
        print(f"{PREFIX} ERROR: missing start script: {START_SCRIPT}", file=sys.stderr, flush=True)
        return 1

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
