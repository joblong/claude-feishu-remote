#!/usr/bin/env bash
# PreToolUse hook — Phase 3.
#
# 决策顺序:
#   1. permission_mode=bypassPermissions → allow
#   2. permission_mode=acceptEdits & tool ∈ {Write,Edit,MultiEdit} → allow
#   3. session allow-list 命中(* 或 tool_name)→ allow
#   4. sentinel 不存在 (afk off) → ask(交给 Claude Code 原生 UI)
#   5. sentinel 存在 (afk on) → 风险分级:
#        5a. Edit/Write/MultiEdit/NotebookEdit 落在 cwd 子树 → allow
#        5b. Bash 命中黑名单 → fall through 推卡;首词在白名单 → allow
#        5c. 其他 → 非阻塞写 pending 通知 daemon 推飞书卡片 → ask
#
# 关键:hook 永不阻塞。终端原生 UI 和飞书卡片并行存在;先响应的一边生效。
# daemon 从 pending 记录的 TMUX_PANE 用 tmux send-keys 把手机按键写回终端。
# 分级规则硬编码在本文件,改动走 git review(见 docs/DESIGN.md §10)。

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

# --- 4.5. 风险分级(只在 afk on 时生效) ---
# 把 ~/x、相对路径转成绝对路径。不依赖 realpath(macOS 默认无)。
normalize_path() {
    local p="$1"
    [[ -z "$p" ]] && { printf ''; return; }
    # ~ 展开
    if [[ "$p" == "~" ]]; then p="$HOME"
    elif [[ "$p" == "~/"* ]]; then p="$HOME/${p#~/}"
    fi
    # 已是绝对路径则原样返回
    if [[ "$p" == /* ]]; then printf '%s' "$p"; return; fi
    # 相对路径:基于 $cwd 拼接(不解析 ../,够用)
    if [[ -n "${cwd:-}" ]]; then
        printf '%s/%s' "$cwd" "$p"
    else
        printf '%s' "$p"
    fi
}

# 4.5.1 Edit/Write/MultiEdit/NotebookEdit:工作区内自动放行
case "$tool_name" in
    Edit|Write|MultiEdit)
        target_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
        ;;
    NotebookEdit)
        target_path=$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // ""')
        ;;
    *)
        target_path=""
        ;;
esac
if [[ -n "$target_path" ]] && [[ -n "$cwd" ]]; then
    abs_target=$(normalize_path "$target_path")
    abs_cwd=$(normalize_path "$cwd")
    # cwd 末尾去掉 / 再比较,避免 //
    abs_cwd="${abs_cwd%/}"
    if [[ "$abs_target" == "$abs_cwd" ]] || [[ "$abs_target" == "$abs_cwd"/* ]]; then
        log_line "session=$session_id tool=$tool_name path=$abs_target → allow (workspace edit)"
        emit_decision "allow"
    fi
    # Claude 的 auto memory 写入 ~/.claude/projects/<repo>/memory/*.md,属于 AI 工作区
    # 不放行整个 ~/.claude(避免误改 settings.json),只放 memory 子目录
    if [[ "$abs_target" == "$HOME/.claude/projects/"*"/memory/"* ]]; then
        log_line "session=$session_id tool=$tool_name path=$abs_target → allow (claude memory)"
        emit_decision "allow"
    fi
fi

# 4.5.2 Bash:黑名单优先,白名单首词放行
if [[ "$tool_name" == "Bash" ]]; then
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    # 黑名单:任意 token 命中即推卡(优先级最高,先于白名单)
    # 顺序无关,只要命中其一就 fall through 到第 5 步
    blacklist_pat='(\b(rm|sudo|chmod|chown|dd|mkfs|fdisk|shutdown|reboot|halt|kill|killall|pkill)\b)'
    blacklist_pat+='|(\b(curl|wget)\b.*\|.*\b(sh|bash|zsh)\b)'
    blacklist_pat+='|(\bgit[[:space:]]+push\b.*--force)'
    blacklist_pat+='|(\bgit[[:space:]]+push\b.*-f\b)'
    blacklist_pat+='|(\bgit[[:space:]]+reset\b.*--hard)'
    blacklist_pat+='|(\bgit[[:space:]]+clean\b.*-[a-zA-Z]*f)'
    blacklist_pat+='|(>[[:space:]]*(/etc/|/usr/|~/\.ssh|~/\.aws|~/\.config|/var/))'
    blacklist_pat+='|((/etc/|~/\.ssh|/\.ssh|~/\.aws|/\.aws|/var/log/|/usr/local/etc))'
    blacklist_pat+='|(\bdocker[[:space:]]+(rm|system[[:space:]]+prune|volume[[:space:]]+rm))'
    blacklist_pat+='|(\bnpm[[:space:]]+publish\b)'
    blacklist_pat+='|(\bpip[[:space:]]+uninstall\b)'

    if printf '%s' "$cmd" | grep -qE "$blacklist_pat"; then
        log_line "session=$session_id tool=Bash → ask (blacklist hit) cmd=$(printf '%s' "$cmd" | head -c 120)"
        # fall through 到第 5 步推卡
    else
        first_word=$(printf '%s' "$cmd" | head -n1 | awk '{print $1}' | sed 's|.*/||')
        whitelist=" ls cat head tail wc grep find file stat du df ps top htop free \
echo printf which whereis whoami pwd id uname date uptime \
cd pushd popd export env true false : \
git diff cmp shasum sha256sum md5 md5sum jq yq tree \
node npm yarn pnpm python python3 pip pip3 make tmux \
mkdir touch test [ "
        if [[ "$whitelist" == *" $first_word "* ]]; then
            log_line "session=$session_id tool=Bash → allow (whitelist: $first_word)"
            emit_decision "allow"
        fi
        # 不在白名单也不在黑名单 → 默认推卡
    fi
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
