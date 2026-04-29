"""Runtime paths and env for the Feishu daemon & hooks side."""
from __future__ import annotations

import os
from pathlib import Path

try:
    from dotenv import load_dotenv
except ImportError:
    load_dotenv = None


HOME = Path.home()

RUNTIME_DIR = HOME / ".claude" / "feishu-remote"
SENTINEL_FILE = RUNTIME_DIR / "away-mode"
PENDING_DIR = RUNTIME_DIR / "pending"
RESULT_DIR = RUNTIME_DIR / "result"
SESSION_ALLOW_DIR = RUNTIME_DIR / "session-allow"
LOG_FILE = RUNTIME_DIR / "daemon.log"

DAEMON_DIR = HOME / ".claude" / "feishu-daemon"
ENV_FILE = DAEMON_DIR / ".env"


def load_env() -> None:
    if load_dotenv is not None and ENV_FILE.exists():
        load_dotenv(ENV_FILE)


def get_env(key: str, default: str | None = None, required: bool = False) -> str | None:
    val = os.environ.get(key, default)
    if required and not val:
        raise RuntimeError(f"missing required env var: {key}")
    return val


def ensure_runtime_dirs() -> None:
    for d in (RUNTIME_DIR, PENDING_DIR, RESULT_DIR, SESSION_ALLOW_DIR):
        d.mkdir(parents=True, exist_ok=True)
