#!/usr/bin/env bash
# Stop / Notification hook — scaffold version.
# Logs the event. Phase 4 will push a Feishu card when sentinel is on.

set -u

LOG_DIR="${HOME}/.claude/feishu-remote"
mkdir -p "${LOG_DIR}"
LOG="${LOG_DIR}/hook.log"

arg="${1:-unknown}"
input=$(cat)

if command -v jq >/dev/null 2>&1; then
    event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""')
    session_id=$(printf '%s' "$input" | jq -r '.session_id // ""')
    message=$(printf '%s' "$input" | jq -r '.message // ""')
    last_msg=$(printf '%s' "$input" | jq -r '.last_assistant_message // ""' | head -c 200)
else
    event="?"; session_id="?"; message="?"; last_msg="?"
fi

printf '[%s] notify.sh arg=%s event=%s session=%s message=%q last=%q\n' \
    "$(date +%Y-%m-%dT%H:%M:%S%z)" "$arg" "$event" "$session_id" "$message" "$last_msg" \
    >> "$LOG"

exit 0
