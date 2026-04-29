"""Runtime paths and env for the Feishu daemon & hooks side."""
from __future__ import annotations

import os
import re
import tempfile
from pathlib import Path

try:
    from dotenv import load_dotenv
except ImportError:
    load_dotenv = None


PLACEHOLDER_OPEN_ID_VALUES = {"", "ou_placeholder"}


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


def is_placeholder_open_id(value: str | None) -> bool:
    if value is None:
        return True
    v = value.strip()
    if v in PLACEHOLDER_OPEN_ID_VALUES:
        return True
    return not v.startswith("ou_")


def persist_target_open_id(new_value: str) -> None:
    """原子地把 .env 里的 FEISHU_TARGET_OPEN_ID=... 行替换成 new_value。

    保留其他行、注释、空行、顺序。若不存在该行则追加。写盘后 chmod 600。
    同时更新 os.environ 以便进程内后续读取一致。
    """
    new_line = f"FEISHU_TARGET_OPEN_ID={new_value}"
    text = ENV_FILE.read_text(encoding="utf-8") if ENV_FILE.exists() else ""
    updated, n = re.subn(
        r"^FEISHU_TARGET_OPEN_ID=.*$", new_line, text, count=1, flags=re.M
    )
    if n == 0:
        if text and not text.endswith("\n"):
            updated = text + "\n" + new_line + "\n"
        else:
            updated = text + new_line + "\n"

    ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(ENV_FILE.parent), prefix=".tmp.env.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(updated)
        os.chmod(tmp, 0o600)
        os.replace(tmp, ENV_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    os.environ["FEISHU_TARGET_OPEN_ID"] = new_value
