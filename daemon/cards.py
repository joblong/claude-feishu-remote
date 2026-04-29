"""Feishu interactive card JSON builders. Schema borrows from cygra/claude-code-feishu-hooks."""
from __future__ import annotations


def build_approval_card(req_id: str, session_id: str, tool_name: str, tool_input: dict, cwd: str) -> dict:
    summary = _summarize_tool_input(tool_name, tool_input)
    return {
        "config": {"wide_screen_mode": True},
        "header": {
            "title": {"tag": "plain_text", "content": f"Approval · {tool_name}"},
            "template": "orange",
        },
        "elements": [
            {"tag": "div", "text": {"tag": "lark_md", "content": f"**Tool**: `{tool_name}`\n**CWD**: `{cwd}`\n**Session**: `{session_id[:8]}…`"}},
            {"tag": "div", "text": {"tag": "lark_md", "content": summary}},
            {"tag": "hr"},
            {
                "tag": "action",
                "actions": [
                    {
                        "tag": "button",
                        "text": {"tag": "plain_text", "content": "允许"},
                        "type": "primary",
                        "value": {"action": "allow", "req_id": req_id, "session_id": session_id, "tool_name": tool_name},
                    },
                    {
                        "tag": "button",
                        "text": {"tag": "plain_text", "content": "拒绝"},
                        "type": "danger",
                        "value": {"action": "deny", "req_id": req_id, "session_id": session_id, "tool_name": tool_name},
                    },
                    {
                        "tag": "button",
                        "text": {"tag": "plain_text", "content": "本会话全允许"},
                        "type": "default",
                        "value": {"action": "allow_session", "req_id": req_id, "session_id": session_id, "tool_name": tool_name},
                    },
                ],
            },
        ],
    }


def build_result_card(req_id: str, tool_name: str, decision: str, by: str) -> dict:
    color = {"allow": "green", "allow_session": "green", "deny": "red"}.get(decision, "grey")
    label = {"allow": "已允许", "allow_session": "已允许(本会话全允许)", "deny": "已拒绝"}.get(decision, decision)
    return {
        "config": {"wide_screen_mode": True},
        "header": {
            "title": {"tag": "plain_text", "content": f"{label} · {tool_name}"},
            "template": color,
        },
        "elements": [
            {"tag": "div", "text": {"tag": "lark_md", "content": f"处理者:{by}\nreq_id:`{req_id}`"}},
        ],
    }


def build_handled_card(req_id: str, tool_name: str) -> dict:
    """已在终端处理:手机端按钮晚于终端响应时替换成这张卡。"""
    return {
        "config": {"wide_screen_mode": True},
        "header": {
            "title": {"tag": "plain_text", "content": f"已在终端处理 · {tool_name}"},
            "template": "grey",
        },
        "elements": [
            {"tag": "div", "text": {"tag": "lark_md", "content": f"本次调用已经在终端侧决定,无需手机端再操作。\nreq_id:`{req_id}`"}},
        ],
    }


def _summarize_tool_input(tool_name: str, tool_input: dict) -> str:
    if tool_name == "Bash":
        cmd = str(tool_input.get("command", "")).strip()
        if len(cmd) > 500:
            cmd = cmd[:500] + "…"
        return f"```\n{cmd}\n```"
    if tool_name in ("Write", "Edit", "MultiEdit"):
        fp = tool_input.get("file_path", "")
        return f"**file**: `{fp}`"
    try:
        import json
        s = json.dumps(tool_input, ensure_ascii=False, indent=2)
        if len(s) > 800:
            s = s[:800] + "…"
        return f"```json\n{s}\n```"
    except Exception:
        return "_(不能序列化的 tool_input)_"
