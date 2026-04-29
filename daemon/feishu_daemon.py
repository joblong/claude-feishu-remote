"""Feishu daemon — Phase 3 (dual-end always-on architecture).

Architecture:
- approve.sh 永不阻塞,总是返回 `ask`。在 away 模式下同时写 pending 文件。
- daemon 看到 pending → 推飞书卡片(永不超时)。
- 用户点按钮 → daemon 用 `tmux send-keys` 把 1/2 写回 approve.sh 所在 tmux pane,
  模拟在终端按下 Claude Code 原生 UI 的数字键。
- 终端先响应 vs 手机先响应:用 handled 文件标记胜者,另一端变成"已处理"状态。

Responsibilities:
1. WS long-connection to Feishu, handle im.message.receive_v1 + card.action.trigger
2. Poll ~/.claude/feishu-remote/pending/ for new approval requests written by approve.sh
3. For each pending: send interactive card to FEISHU_TARGET_OPEN_ID, save message_id back
4. On card button press: write handled marker + tmux send-keys to target pane, update card
5. On duplicate click: ignore via handled marker, show "已处理过"
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

from . import cards, config, ipc


POLL_INTERVAL = 0.5


def _setup_logging() -> logging.Logger:
    config.ensure_runtime_dirs()
    level_name = os.environ.get("FEISHU_LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=[
            logging.FileHandler(str(config.LOG_FILE), encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )
    return logging.getLogger("feishu-daemon")


log = logging.getLogger("feishu-daemon")


class FeishuState:
    """Shared state between WS handlers and pending poller. Cards never expire."""

    def __init__(self, lark_client, target_open_id: str):
        self.client = lark_client  # lark.Client (REST), NOT ws.Client
        self.target_open_id = target_open_id
        # req_id -> pending dict (includes message_id once sent, tmux_pane, etc.)
        self.active: dict[str, dict] = {}
        self.lock = threading.Lock()

    def register_sent(self, req_id: str, message_id: str, pending: dict) -> None:
        with self.lock:
            pending["message_id"] = message_id
            self.active[req_id] = pending
            # persist message_id back to pending file so record survives daemon restart
            try:
                ipc.atomic_write_json(ipc.pending_path(req_id), pending)
            except Exception:
                log.exception("failed to persist message_id for req %s", req_id)

    def lookup(self, req_id: str) -> dict | None:
        with self.lock:
            return self.active.get(req_id)

    def drop(self, req_id: str) -> None:
        with self.lock:
            self.active.pop(req_id, None)

    def try_bind_target(self, open_id: str) -> bool:
        """线程安全地把 target_open_id 从占位值替换成 open_id。已绑定返回 False。"""
        with self.lock:
            if not config.is_placeholder_open_id(self.target_open_id):
                return False
            self.target_open_id = open_id
            return True


def _send_card(state: FeishuState, req_id: str, pending: dict) -> str | None:
    """Send the approval card. Return message_id on success, None on failure."""
    try:
        from lark_oapi.api.im.v1 import CreateMessageRequest, CreateMessageRequestBody
    except ImportError:
        log.exception("lark-oapi not available")
        return None

    card = cards.build_approval_card(
        req_id=req_id,
        session_id=pending.get("session_id", "?"),
        tool_name=pending.get("tool_name", "?"),
        tool_input=pending.get("tool_input", {}),
        cwd=pending.get("cwd", "?"),
    )

    req = (
        CreateMessageRequest.builder()
        .receive_id_type("open_id")
        .request_body(
            CreateMessageRequestBody.builder()
            .receive_id(state.target_open_id)
            .msg_type("interactive")
            .content(json.dumps(card, ensure_ascii=False))
            .build()
        )
        .build()
    )

    try:
        resp = state.client.im.v1.message.create(req)
    except Exception:
        log.exception("exception sending card for req %s", req_id)
        return None

    if not resp.success():
        log.error("send card failed req=%s code=%s msg=%s log_id=%s",
                  req_id, resp.code, resp.msg, resp.get_log_id())
        return None

    message_id = resp.data.message_id
    log.info("card sent req=%s message_id=%s", req_id, message_id)
    return message_id


def _pending_poller(state: FeishuState) -> None:
    """Background thread: find new pendings (no message_id yet) and send cards. Cards never expire."""
    log.info("pending poller started, watching %s", config.PENDING_DIR)
    while True:
        try:
            for p in sorted(config.PENDING_DIR.glob("*.json")):
                req_id = p.stem
                if state.lookup(req_id) is not None:
                    continue
                pending = ipc.read_json(p)
                if pending is None:
                    continue
                # Already sent in a previous daemon run? (has message_id — just remember it)
                if pending.get("message_id"):
                    with state.lock:
                        state.active[req_id] = pending
                    continue
                # Terminal already handled before daemon got to it? Skip send, just remember for late-click handling
                if ipc.result_path(req_id).exists():
                    log.info("pending %s already resolved by terminal, skipping send", req_id)
                    with state.lock:
                        state.active[req_id] = pending
                    continue
                message_id = _send_card(state, req_id, pending)
                if message_id:
                    state.register_sent(req_id, message_id, pending)
        except Exception:
            log.exception("pending poller iteration failed")
        time.sleep(POLL_INTERVAL)


def _tmux_send_key(pane: str, key: str) -> tuple[bool, str]:
    """Send a single key to a tmux pane. Returns (ok, message)."""
    if not pane:
        return False, "no TMUX_PANE recorded in pending"
    tmux_bin = shutil.which("tmux")
    if not tmux_bin:
        return False, "tmux binary not found on daemon host"
    try:
        # -l 表示 literal(不当作按键名);Claude Code UI 的数字键直接写字符即可
        res = subprocess.run(
            [tmux_bin, "send-keys", "-t", pane, "-l", key],
            capture_output=True, text=True, timeout=5,
        )
        if res.returncode != 0:
            return False, f"tmux send-keys rc={res.returncode} stderr={res.stderr.strip()}"
        return True, "ok"
    except subprocess.TimeoutExpired:
        return False, "tmux send-keys timed out"
    except Exception as e:
        return False, f"tmux send-keys exception: {e}"


def _cleanup_poller(state: FeishuState) -> None:
    """Background thread: remove pending/result files older than 1h."""
    while True:
        try:
            cutoff = time.time() - 3600
            for d in (config.PENDING_DIR, config.RESULT_DIR):
                for p in d.glob("*.json"):
                    try:
                        if p.stat().st_mtime < cutoff:
                            p.unlink(missing_ok=True)
                            state.drop(p.stem)
                    except OSError:
                        pass
        except Exception:
            log.exception("cleanup iteration failed")
        time.sleep(300)


def _make_on_card_action(state: "FeishuState"):
    from lark_oapi.event.callback.model.p2_card_action_trigger import P2CardActionTriggerResponse

    def on_card_action(data):
        try:
            value = data.event.action.value or {}
            operator = data.event.operator.open_id
            msg_id = data.event.context.open_message_id
            action = value.get("action")
            req_id = value.get("req_id")
            session_id = value.get("session_id", "")
            tool_name = value.get("tool_name", "")
            log.info("card.action.trigger operator=%s req_id=%s action=%s msg_id=%s",
                     operator, req_id, action, msg_id)

            if not req_id or action not in ("allow", "deny", "allow_session"):
                return P2CardActionTriggerResponse({
                    "toast": {"type": "error", "content": "无效按钮"},
                })

            pending = state.lookup(req_id)
            # 已被终端或上一次点击处理:show handled card,不再 send-keys
            if ipc.result_path(req_id).exists():
                log.info("duplicate/late click on resolved req=%s", req_id)
                updated = cards.build_handled_card(req_id, tool_name)
                return P2CardActionTriggerResponse({
                    "toast": {"type": "warning", "content": "已处理过,请忽略"},
                    "card": {"type": "raw", "data": updated},
                })
            # 正常情况下 pending 一定在内存里;如果不在,pending 文件直接读
            if pending is None:
                pending = ipc.read_json(ipc.pending_path(req_id)) or {}

            decision = action  # allow | deny | allow_session
            tmux_pane = pending.get("tmux_pane") or ""

            # allow / allow_session → 在 Claude Code UI 按 "1" (Yes)
            # deny → 按 "2" (No)
            # allow_session 额外写白名单,这样当会话内之后再触发同 tool_name 时 approve.sh 直接 allow
            key = "2" if decision == "deny" else "1"
            if decision == "allow_session" and session_id and tool_name:
                ipc.grant_session_allow(session_id, tool_name)
                log.info("session allow-list granted session=%s tool=%s", session_id, tool_name)

            ok, msg = _tmux_send_key(tmux_pane, key)
            if not ok:
                log.error("tmux send-keys failed req=%s pane=%s key=%s: %s",
                          req_id, tmux_pane, key, msg)
                return P2CardActionTriggerResponse({
                    "toast": {"type": "error", "content": f"tmux 发送失败:{msg}"},
                })
            log.info("tmux send-keys ok req=%s pane=%s key=%s decision=%s", req_id, tmux_pane, key, decision)

            # 记录胜者,防止终端再点或手机再点
            ipc.atomic_write_json(
                ipc.result_path(req_id),
                {"decision": decision, "by": operator, "ts": time.time(), "via": "feishu"},
            )
            state.drop(req_id)

            updated = cards.build_result_card(req_id, tool_name, decision, operator)
            return P2CardActionTriggerResponse({
                "toast": {"type": "success", "content": {"allow": "已允许", "deny": "已拒绝", "allow_session": "已允许(本会话)"}[decision]},
                "card": {"type": "raw", "data": updated},
            })
        except Exception:
            log.exception("card action handler failed")
            return P2CardActionTriggerResponse({
                "toast": {"type": "error", "content": "内部错误,请查 daemon.log"},
            })

    return on_card_action


def _send_text(state: FeishuState, open_id: str, text: str) -> None:
    """向指定用户发一条纯文本消息。用于绑定成功反馈等场景。"""
    try:
        from lark_oapi.api.im.v1 import CreateMessageRequest, CreateMessageRequestBody
    except ImportError:
        log.exception("lark-oapi not available")
        return
    req = (
        CreateMessageRequest.builder()
        .receive_id_type("open_id")
        .request_body(
            CreateMessageRequestBody.builder()
            .receive_id(open_id)
            .msg_type("text")
            .content(json.dumps({"text": text}, ensure_ascii=False))
            .build()
        )
        .build()
    )
    try:
        resp = state.client.im.v1.message.create(req)
    except Exception:
        log.exception("exception sending text to open_id=%s", open_id)
        return
    if not resp.success():
        log.error("send text failed open_id=%s code=%s msg=%s", open_id, resp.code, resp.msg)


def _make_on_message(state: "FeishuState"):
    def on_message(data) -> None:
        try:
            sender_open_id = data.event.sender.sender_id.open_id
            chat_id = data.event.message.chat_id
            chat_type = data.event.message.chat_type or ""
            content = data.event.message.content
            log.info("im.message.receive_v1 open_id=%s chat_type=%s chat_id=%s content=%s",
                     sender_open_id, chat_type, chat_id, content)

            # 自动绑定审批者:只接受 1:1 (p2p) 消息,群聊忽略(TOFU 防误绑)
            if chat_type != "p2p":
                return
            if not state.try_bind_target(sender_open_id):
                return  # 已绑定过,忽略
            try:
                config.persist_target_open_id(sender_open_id)
                log.info("自动绑定审批者 open_id=%s 已持久化到 .env", sender_open_id)
            except Exception:
                log.exception("persist_target_open_id 失败,绑定仅存在于内存")
            _send_text(state, sender_open_id, "已绑定审批者")
        except Exception:
            log.exception("failed to parse im.message.receive_v1 payload")
    return on_message


def main() -> int:
    global log
    log = _setup_logging()
    config.load_env()

    app_id = config.get_env("FEISHU_APP_ID", required=True)
    app_secret = config.get_env("FEISHU_APP_SECRET", required=True)
    target_open_id = config.get_env("FEISHU_TARGET_OPEN_ID", default="") or ""

    try:
        import lark_oapi as lark
    except ImportError as e:
        log.error("lark-oapi not installed: %s", e)
        return 2

    # REST client for sending/patching messages
    rest_client = (
        lark.Client.builder()
        .app_id(app_id)
        .app_secret(app_secret)
        .log_level(lark.LogLevel.INFO)
        .build()
    )

    state = FeishuState(rest_client, target_open_id)

    if config.is_placeholder_open_id(target_open_id):
        log.warning(
            "FEISHU_TARGET_OPEN_ID 未绑定,等待首条 1:1 消息自动绑定。"
            "请把机器人拉到 1:1 对话里发任意一句话(不要在群里发,群消息会被忽略)。"
        )

    event_handler = (
        lark.EventDispatcherHandler.builder("", "")
        .register_p2_im_message_receive_v1(_make_on_message(state))
        .register_p2_card_action_trigger(_make_on_card_action(state))
        .build()
    )

    ws_client = lark.ws.Client(
        app_id,
        app_secret,
        event_handler=event_handler,
        log_level=lark.LogLevel.INFO,
    )

    # Start background pollers
    threading.Thread(target=_pending_poller, args=(state,), daemon=True).start()
    threading.Thread(target=_cleanup_poller, args=(state,), daemon=True).start()

    log.info("daemon starting. sentinel=%s runtime_dir=%s target=%s",
             config.SENTINEL_FILE, config.RUNTIME_DIR, target_open_id)
    ws_client.start()  # blocking
    log.warning("ws client returned (should be infinite); exiting 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
