#!/usr/bin/env bash
# PreToolUse hook — Phase 3.
#
# 决策顺序:
#   1. permission_mode=bypassPermissions → allow
#   2. permission_mode=acceptEdits & tool ∈ {Write,Edit,MultiEdit} → allow
#   3. session allow-list 命中(* 或 tool_name)→ allow
#   4. sentinel 不存在 (afk off) → ask(交给 Claude Code 原生 UI)
#   5. sentinel 存在 (afk on) → 非阻塞写 pending 通知 daemon 推飞书卡片 → ask
#
# 关键:hook 永不阻塞。终端原生 UI 和飞书卡片并行存在;先响应的一边生效。
# daemon 从 pending 记录的 TMUX_PANE 用 tmux send-keys 把手机按键写回终端。

set -u

RUNTIME_DIR="${HOME}/.claude/feishu-remote"
PENDING_DIR="${RUNTIME_DIR}/pending"
SESSION_ALLOW_DIR="${RUNTIME_DIR}/session-allow"
SENTINEL="${RUNTIME_DIR}/away-mode"
LOG="${RUNTIME_DIR}/hook.log"

mkdir -p "$PENDING_DIR" "$SESSION_ALLOW_DIR"

log_line() {
    printf '[%s] approve.sh %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >> "$LOG"
}

emit_decision() {
    local decision="$1"
    local reason="${2:-}"
    if [[ -n "$reason" ]]; then
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$decision" "$reason"
    else
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s"}}\n' "$decision"
    fi
    exit 0
}

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
    log_line "jq 不存在,降级为 ask (安装时应该自动装 jq)"
    emit_decision "ask"
fi

session_id=$(printf '%s' "$input" | jq -r '.session_id // ""')
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
tool_use_id=$(printf '%s' "$input" | jq -r '.tool_use_id // ""')
permission_mode=$(printf '%s' "$input" | jq -r '.permission_mode // "default"')
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

# --- 1. bypassPermissions: 用户已全放开 ---
if [[ "$permission_mode" == "bypassPermissions" ]]; then
    log_line "session=$session_id tool=$tool_name mode=$permission_mode → allow (bypass)"
    emit_decision "allow"
fi

# --- 2. acceptEdits: 对齐原生语义 ---
if [[ "$permission_mode" == "acceptEdits" ]]; then
    case "$tool_name" in
        Write|Edit|MultiEdit|NotebookEdit)
            log_line "session=$session_id tool=$tool_name mode=$permission_mode → allow (acceptEdits)"
            emit_decision "allow"
            ;;
    esac
fi

# --- 3. session allow-list ---
allow_file="${SESSION_ALLOW_DIR}/${session_id}"
if [[ -n "$session_id" ]] && [[ -f "$allow_file" ]]; then
    if grep -qxE "(\*|$tool_name)" "$allow_file" 2>/dev/null; then
        log_line "session=$session_id tool=$tool_name → allow (session allow-list hit)"
        emit_decision "allow"
    fi
fi

# --- 4. sentinel 不存在:终端模式 ---
if [[ ! -e "$SENTINEL" ]]; then
    log_line "session=$session_id tool=$tool_name mode=$permission_mode → ask (afk off)"
    emit_decision "ask"
fi

# --- 5. sentinel 存在:离开模式,非阻塞写 pending ---
req_id="${tool_use_id:-$(date +%s%N)-$$}"
pending_file="${PENDING_DIR}/${req_id}.json"

# 整理 tool_input 为紧凑 JSON
tool_input=$(printf '%s' "$input" | jq -c '.tool_input // {}')

# 后台原子写,不阻塞 hook 主流程
(
    jq -n \
        --arg req_id "$req_id" \
        --arg session_id "$session_id" \
        --arg tool_name "$tool_name" \
        --argjson tool_input "$tool_input" \
        --arg cwd "$cwd" \
        --arg tmux_pane "${TMUX_PANE:-}" \
        --arg created_at "$(date +%s)" \
        '{req_id:$req_id, session_id:$session_id, tool_name:$tool_name, tool_input:$tool_input, cwd:$cwd, tmux_pane:$tmux_pane, created_at:($created_at|tonumber)}' \
        > "${pending_file}.tmp" \
    && mv "${pending_file}.tmp" "$pending_file"
) &

log_line "session=$session_id tool=$tool_name → ask (afk on, pending=$req_id tmux=${TMUX_PANE:-none})"
emit_decision "ask"
