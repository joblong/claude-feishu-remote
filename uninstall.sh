#!/usr/bin/env bash
# Claude Code × 飞书远程审批 — 卸载脚本
# 作用:
#   1. bootout launchd
#   2. 删 plist
#   3. 删 hooks 软链
#   4. 删 daemon 软链
#   5. 从 settings.json 移除我们的 hooks 条目(保留其他字段)
#   6. 删 ~/.local/bin/afk 软链
#   (.env 和 runtime 数据保留,用户手动清理)

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
HOOKS_DIR="${CLAUDE_DIR}/hooks"
DAEMON_LINK="${CLAUDE_DIR}/feishu-daemon"
BIN_DIR="${HOME}/.local/bin"
AFK_LINK="${BIN_DIR}/afk"

HOOK_APPROVE="${HOOKS_DIR}/approve.sh"
HOOK_NOTIFY="${HOOKS_DIR}/notify.sh"

OS="$(uname -s)"
case "$OS" in
    Darwin)
        PLATFORM="macos"
        LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
        PLIST_LABEL="com.user.feishu-claude"
        PLIST="${LAUNCH_AGENT_DIR}/${PLIST_LABEL}.plist"
        ;;
    Linux)
        PLATFORM="linux"
        SYSTEMD_DIR="${HOME}/.config/systemd/user"
        SERVICE_NAME="feishu-claude.service"
        SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}"
        ;;
esac

log()  { printf '\033[1;34m[uninstall]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[uninstall]\033[0m %s\n' "$*" >&2; }

# 1. 停并移除服务
if [[ "${PLATFORM:-}" == "macos" ]]; then
    UID_NUM=$(id -u)
    DOMAIN="gui/${UID_NUM}"
    if [[ -f "$PLIST" ]] && launchctl print "${DOMAIN}/${PLIST_LABEL}" >/dev/null 2>&1; then
        log "bootout daemon..."
        launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || warn "bootout 失败,继续"
    fi
    if [[ -f "$PLIST" ]]; then
        rm -f "$PLIST"
        log "删 $PLIST"
    fi
elif [[ "${PLATFORM:-}" == "linux" ]]; then
    if systemctl --user list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
        log "stop & disable systemd unit..."
        systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || warn "systemctl disable 失败,继续"
    fi
    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE"
        log "删 $SERVICE_FILE"
        systemctl --user daemon-reload 2>/dev/null || true
    fi
fi

# 3/4. 删软链
for link in "$HOOK_APPROVE" "$HOOK_NOTIFY" "$DAEMON_LINK" "$AFK_LINK"; do
    if [[ -L "$link" ]]; then
        rm -f "$link"
        log "删 $link"
    fi
done

# 5. 从 settings.json 移除 hooks 条目
if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
    BACKUP="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$BACKUP"
    log "settings.json 备份 $BACKUP"

    tmp=$(mktemp)
    jq --arg approve "$HOOK_APPROVE" --arg notify_stop "${HOOK_NOTIFY} stop" --arg notify_n "${HOOK_NOTIFY} notification" '
        # 过滤掉三类 hook 条目里我们写入的 command
        .hooks.PreToolUse   |= ((. // []) | map(.hooks |= map(select(.command != $approve))) | map(select(.hooks | length > 0))) |
        .hooks.Stop         |= ((. // []) | map(.hooks |= map(select(.command != $notify_stop))) | map(select(.hooks | length > 0))) |
        .hooks.Notification |= ((. // []) | map(.hooks |= map(select(.command != $notify_n))) | map(select(.hooks | length > 0))) |
        # 如果某个 event 数组为空,删掉整个 key
        (if (.hooks.PreToolUse // [] | length) == 0 then del(.hooks.PreToolUse) else . end) |
        (if (.hooks.Stop // [] | length) == 0 then del(.hooks.Stop) else . end) |
        (if (.hooks.Notification // [] | length) == 0 then del(.hooks.Notification) else . end) |
        # 如果整个 hooks 对象空了,删掉
        (if (.hooks // {} | length) == 0 then del(.hooks) else . end)
    ' "$SETTINGS" > "$tmp"

    if jq -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$SETTINGS"
        log "已从 settings.json 移除 hooks 条目"
    else
        rm -f "$tmp"
        cp "$BACKUP" "$SETTINGS"
        warn "settings.json 修改失败,已回滚到 $BACKUP"
    fi
fi

cat <<EOF

\033[1;32m========== 卸载完成 ==========\033[0m

保留项(请按需手动删除):
  - ${CLAUDE_DIR}/feishu-remote/         (daemon.log, sentinel, pending/result)
  - ${HOME}/.claude/feishu-daemon/.env    (App ID/Secret)
  - 源码目录                              ${SRC_DIR}
EOF
