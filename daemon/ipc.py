"""Filesystem IPC between approve.sh hook and feishu-daemon."""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

from . import config


def sentinel_exists() -> bool:
    return config.SENTINEL_FILE.exists()


def pending_path(req_id: str) -> Path:
    return config.PENDING_DIR / f"{req_id}.json"


def result_path(req_id: str) -> Path:
    return config.RESULT_DIR / f"{req_id}.json"


def session_allow_path(session_id: str) -> Path:
    return config.SESSION_ALLOW_DIR / session_id


def atomic_write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_json(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def session_allowed(session_id: str, tool_name: str) -> bool:
    p = session_allow_path(session_id)
    if not p.exists():
        return False
    try:
        tools = p.read_text(encoding="utf-8").splitlines()
    except OSError:
        return False
    return "*" in tools or tool_name in tools


def grant_session_allow(session_id: str, tool_name: str) -> None:
    p = session_allow_path(session_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    existing = p.read_text(encoding="utf-8").splitlines() if p.exists() else []
    if tool_name in existing or "*" in existing:
        return
    with open(p, "a", encoding="utf-8") as f:
        f.write(tool_name + "\n")
