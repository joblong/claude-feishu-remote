#!/usr/bin/env bash
# Claude Code × 飞书远程审批 — 安装脚本(幂等 · 跨平台)
#
# 支持:
#   - macOS  → launchd (~/Library/LaunchAgents)
#   - Linux  → systemd user unit (~/.config/systemd/user),需要 loginctl enable-linger 才能登出保活
#
# 作用:
#   1. 前置检查(python3 >= 3.9, jq, tmux)
#   2. 深度 merge hooks 配置到 ~/.claude/settings.json(保留原有字段)
#   3. 软链 hooks 到 ~/.claude/hooks/
#   4. 软链 daemon 到 ~/.claude/feishu-daemon/
#   5. 渲染并安装 service(launchd plist 或 systemd unit),然后启动
#   6. 软链 bin/afk 到 ~/.local/bin/afk
#   7. 打印下一步(填 .env、服务状态、测试命令)

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
HOOKS_DIR="${CLAUDE_DIR}/hooks"
DAEMON_LINK="${CLAUDE_DIR}/feishu-daemon"        # → $SRC_DIR/daemon
RUNTIME_DIR="${CLAUDE_DIR}/feishu-remote"
LOG_DIR="${RUNTIME_DIR}"
BIN_DIR="${HOME}/.local/bin"
AFK_LINK="${BIN_DIR}/afk"
ENV_FILE="${DAEMON_LINK}/.env"

# 平台分岔
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
    *)
        printf '\033[1;31m[install ERROR]\033[0m 不支持的系统: %s (只支持 Darwin/Linux)\n' "$OS" >&2
        exit 1
        ;;
esac

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

install_pkg() {
    # 用可用的包管理器装一个包,找不到就 die
    local pkg="$1"
    # macOS 下,non-interactive shell 经常找不到 /opt/homebrew/bin 里的 brew —— 补 PATH
    if [[ "$PLATFORM" == "macos" ]] && ! command -v brew >/dev/null 2>&1; then
        for bp in /opt/homebrew/bin /usr/local/bin; do
            if [[ -x "$bp/brew" ]]; then
                export PATH="$bp:$PATH"
                break
            fi
        done
    fi
    if command -v brew >/dev/null 2>&1; then
        brew install "$pkg"
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y "$pkg"
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm "$pkg"
    else
        die "$pkg 不存在,且找不到可用的包管理器(brew/apt/dnf/yum/pacman)。请手动安装。"
    fi
}

# -------- 1. 前置检查 --------
log "前置检查... (platform=$PLATFORM)"

# 选 python3:优先 brew(macOS 避开 conda/Xcode sandbox),Linux 就用 PATH
PYTHON_BIN=""
CANDIDATES=()
if [[ "$PLATFORM" == "macos" ]]; then
    CANDIDATES=(/opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 || true)")
else
    CANDIDATES=("$(command -v python3 || true)" /usr/bin/python3 /usr/local/bin/python3)
fi
for cand in "${CANDIDATES[@]}"; do
    if [[ -n "$cand" ]] && [[ -x "$cand" ]]; then
        ver_ok=$("$cand" -c 'import sys; print(int(sys.version_info >= (3,9)))' 2>/dev/null || echo 0)
        if [[ "$ver_ok" == "1" ]]; then
            PYTHON_BIN="$cand"
            break
        fi
    fi
done
[[ -n "$PYTHON_BIN" ]] || die "找不到 python3 >= 3.9,请先安装"
PY_VER=$("$PYTHON_BIN" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
log "  python3 ($PYTHON_BIN) $PY_VER ✔"

if ! command -v jq >/dev/null 2>&1; then
    log "  jq 未安装,自动安装..."
    install_pkg jq || die "安装 jq 失败"
fi
log "  jq $(jq --version) ✔"

if ! command -v tmux >/dev/null 2>&1; then
    warn "  tmux 未安装 —— daemon 需要 tmux send-keys 把审批结果写回终端。正在自动安装..."
    install_pkg tmux || die "安装 tmux 失败 (daemon 会无法 send-keys 回终端)"
fi
log "  tmux $(tmux -V) ✔"

mkdir -p "$CLAUDE_DIR" "$HOOKS_DIR" "$RUNTIME_DIR" "$BIN_DIR"
if [[ "$PLATFORM" == "macos" ]]; then
    mkdir -p "$LAUNCH_AGENT_DIR"
else
    mkdir -p "$SYSTEMD_DIR"
fi

# -------- 2. Python 依赖 --------
log "安装 Python 依赖 (lark-oapi, python-dotenv) —— 用 $PYTHON_BIN 的 --user 空间..."
"$PYTHON_BIN" -m pip install --user --quiet --break-system-packages -r "${SRC_DIR}/daemon/requirements.txt" 2>/dev/null \
    || "$PYTHON_BIN" -m pip install --user --quiet -r "${SRC_DIR}/daemon/requirements.txt" \
    || warn "pip install 失败,daemon 启动时会报错。手动跑: $PYTHON_BIN -m pip install --user -r ${SRC_DIR}/daemon/requirements.txt"

# -------- 3. 软链 daemon 和 hooks --------
log "链接 daemon 和 hooks..."

ln -sfn "${SRC_DIR}/daemon" "$DAEMON_LINK"
ln -sf  "${SRC_DIR}/hooks/approve.sh" "${HOOKS_DIR}/approve.sh"
ln -sf  "${SRC_DIR}/hooks/notify.sh"  "${HOOKS_DIR}/notify.sh"
chmod +x "${SRC_DIR}/hooks/approve.sh" "${SRC_DIR}/hooks/notify.sh"

ln -sf "${SRC_DIR}/bin/afk" "$AFK_LINK"
chmod +x "${SRC_DIR}/bin/afk"
log "  ~/.claude/hooks/approve.sh ✔"
log "  ~/.claude/hooks/notify.sh  ✔"
log "  ~/.claude/feishu-daemon    ✔ → ${SRC_DIR}/daemon"
log "  ${AFK_LINK}                ✔"

# 提示 PATH
case ":$PATH:" in
    *":$BIN_DIR:"*) : ;;
    *) warn "  \$PATH 里没有 $BIN_DIR,请加入你的 shell rc:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# -------- 4. 深度 merge settings.json --------
log "merge ~/.claude/settings.json (hooks 字段)..."

if [[ ! -f "$SETTINGS" ]]; then
    log "  settings.json 不存在,创建空 {}"
    echo '{}' > "$SETTINGS"
fi

# 备份
BACKUP="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"
log "  备份到 $BACKUP"

# 验证现有 JSON
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    die "~/.claude/settings.json 不是合法 JSON,中止"
fi

# 构造 patch(hooks 配置)。注意 command 字段必须是绝对路径字符串。
HOOK_APPROVE="${HOOKS_DIR}/approve.sh"
HOOK_NOTIFY="${HOOKS_DIR}/notify.sh"

PATCH=$(jq -n \
    --arg approve "$HOOK_APPROVE" \
    --arg notify "$HOOK_NOTIFY" \
    '{
      hooks: {
        PreToolUse: [
          {
            matcher: "Bash|Write|Edit|MultiEdit",
            hooks: [
              { type: "command", command: $approve, timeout: 300 }
            ]
          }
        ],
        Stop: [
          {
            matcher: "",
            hooks: [
              { type: "command", command: ($notify + " stop") }
            ]
          }
        ],
        Notification: [
          {
            matcher: "",
            hooks: [
              { type: "command", command: ($notify + " notification") }
            ]
          }
        ]
      }
    }'
)

# 幂等:如果已有 hooks.PreToolUse 里带我们的 command,就跳过 merge
EXISTING=$(jq --arg c "$HOOK_APPROVE" '[.hooks.PreToolUse[]?.hooks[]? | select(.command==$c)] | length' "$SETTINGS" 2>/dev/null || echo 0)
if [[ "$EXISTING" -ge 1 ]]; then
    log "  检测到已存在我们的 hooks 配置,跳过 merge (幂等)"
else
    # 深度 merge(`*` 运算符递归合并对象)
    tmp=$(mktemp)
    jq --argjson p "$PATCH" '. * $p' "$SETTINGS" > "$tmp"
    if jq -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$SETTINGS"
        log "  settings.json merge 完成"
    else
        rm -f "$tmp"
        cp "$BACKUP" "$SETTINGS"
        die "merge 产物不是合法 JSON,已从 $BACKUP 恢复"
    fi
fi

# -------- 5. 渲染并安装 service --------
PYTHON_PATH="$PYTHON_BIN"
DAEMON_PARENT="${SRC_DIR}"
DAEMON_DIR_RESOLVED="${DAEMON_PARENT}"   # cwd

render_service() {
    local template="$1"
    local out="$2"
    local tmp
    tmp=$(mktemp)
    sed \
        -e "s|__PYTHON__|${PYTHON_PATH}|g" \
        -e "s|__DAEMON_DIR__|${DAEMON_DIR_RESOLVED}|g" \
        -e "s|__DAEMON_PARENT__|${DAEMON_PARENT}|g" \
        -e "s|__LOG_DIR__|${LOG_DIR}|g" \
        "$template" > "$tmp"
    if [[ -f "$out" ]] && cmp -s "$tmp" "$out"; then
        log "  service 未变化,跳过 ($out)"
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$out"
    log "  service 已写入 $out"
    return 0
}

if [[ "$PLATFORM" == "macos" ]]; then
    log "渲染 launchd plist..."
    render_service "${SRC_DIR}/launchd/com.user.feishu-claude.plist.template" "$PLIST" || true

    UID_NUM=$(id -u)
    DOMAIN="gui/${UID_NUM}"

    if launchctl print "${DOMAIN}/${PLIST_LABEL}" >/dev/null 2>&1; then
        log "  daemon 已加载,重新 bootstrap..."
        launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        warn "  $ENV_FILE 不存在,先不 load daemon。请拷贝 ${SRC_DIR}/.env.template 为 $ENV_FILE,填入变量后再: launchctl bootstrap $DOMAIN $PLIST"
    else
        if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
            log "  daemon bootstrap ✔"
        else
            warn "  bootstrap 失败,尝试 launchctl enable..."
            launchctl enable "${DOMAIN}/${PLIST_LABEL}" 2>/dev/null || true
            launchctl bootstrap "$DOMAIN" "$PLIST" || warn "bootstrap 再次失败,请手动 launchctl bootstrap $DOMAIN $PLIST"
        fi
    fi
else
    log "渲染 systemd user unit..."
    render_service "${SRC_DIR}/launchd/feishu-claude.service.template" "$SERVICE_FILE" || true

    systemctl --user daemon-reload

    # 检查 linger(决定登出 ssh 后服务是否继续跑)
    if command -v loginctl >/dev/null 2>&1; then
        if loginctl show-user "$(id -un)" 2>/dev/null | grep -q '^Linger=yes'; then
            log "  linger 已开启,登出后服务会继续运行 ✔"
        else
            warn "  linger 未开启。登出 ssh 后 user-level systemd 会停 —— 请以 root 运行: sudo loginctl enable-linger $(id -un)"
        fi
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        warn "  $ENV_FILE 不存在,先不启动 daemon。请拷贝 ${SRC_DIR}/.env.template 为 $ENV_FILE,填入变量后再: systemctl --user enable --now ${SERVICE_NAME}"
    else
        if systemctl --user enable --now "$SERVICE_NAME"; then
            log "  daemon started ✔"
        else
            warn "  systemctl enable --now 失败,请手动检查: systemctl --user status $SERVICE_NAME"
        fi
    fi
fi

# -------- 6. 打印下一步 --------
if [[ "$PLATFORM" == "macos" ]]; then
    START_CMD="launchctl bootstrap ${DOMAIN} ${PLIST}"
    STATUS_CMD="launchctl print ${DOMAIN}/${PLIST_LABEL} | head"
else
    START_CMD="systemctl --user enable --now ${SERVICE_NAME}"
    STATUS_CMD="systemctl --user status ${SERVICE_NAME}"
fi

printf '\n\033[1;32m========== 安装完成 ==========\033[0m\n\n'
cat <<EOF
下一步:

  1) 填写 .env:
     cp ${SRC_DIR}/.env.template ${ENV_FILE}
     # 编辑 $ENV_FILE 填入 FEISHU_APP_ID / FEISHU_APP_SECRET / FEISHU_TARGET_OPEN_ID
     # 填完启动:
     ${START_CMD}

  2) 检查 daemon:
     afk status
     ${STATUS_CMD}
     tail -f ${LOG_DIR}/daemon.log

  3) 测试 hook(终端模式 afk off 时,等同未安装):
     afk off
     cd /tmp && claude -p 'run ls'

  4) 远程审批测试(离开模式):
     afk on
     # 在 tmux 内跑 claude,触发工具调用 → 飞书收到卡片 → 点按钮 → tmux 自动按键

  5) 卸载:
     bash ${SRC_DIR}/uninstall.sh

EOF
