# claude-feishu-remote — 方案与实现记录

> Phase 3 终版。由 openClawMac (macOS) 端到端验证通过,待推 tprod (Ubuntu)。

## 1. 目标

用户主力工作流是 **Mac(本地)→ ssh → 远程服务器 → tmux → Claude Code CLI**。
需求:离开电脑时,工具调用审批能走到手机飞书,点 **允许 / 拒绝 / 本会话全允许**,而不必赶回终端。

硬约束:
- 本地/远程都**没有公网 IP**,不用 ngrok/cloudflared
- 必须用飞书(用户工作即时通讯)
- 长期稳定,每天用
- 在电脑前时(`afk off`)对 Claude Code **零打扰** —— 不推任何卡片、不改变原生权限 UI 行为

## 2. 架构(最终版)

### 2.1 总体数据流

```
                      ┌─── afk off (terminal mode) ───────────────────┐
                      │                                                │
 Claude Code ─PreToolUse JSON─▶ approve.sh ──返回 {permissionDecision:"ask"}──▶ Claude Code 原生 UI (1/2)
                      │                                                │
                      └─── afk on (away mode) ────────────────────────┘
                                     │
                                     ├─ (在内存里做 5 级决策)
                                     │    1. bypassPermissions         → allow
                                     │    2. acceptEdits + edit tool   → allow
                                     │    3. session allow-list 命中   → allow
                                     │    4. sentinel 不存在           → ask (等同 afk off)
                                     │    5. sentinel 存在             → 后台写 pending/{tool_use_id}.json,含 TMUX_PANE;同样返回 ask
                                     │
                                     ▼
                           ~/.claude/feishu-remote/pending/*.json
                                     │
                                     │    pending_poller 轮询 (0.5s)
                                     ▼
                         feishu-daemon (lark-oapi WS 长连)
                                     │
                                     ├── im.v1.message.create(卡片) ──▶ 用户手机飞书
                                     │                                     │ 点按钮
                                     ▼                                     ▼
                          card.action.trigger (WS 回推)   ◀─── WS ────────┘
                                     │
                                     ├── 写 result/{req_id}.json (标记胜者,防重复)
                                     ├── [allow_session] 写 session-allow/{session_id}
                                     └── tmux send-keys -l -t <TMUX_PANE> "1" / "2"
                                                    │
                                                    ▼
                                    Claude Code 原生 UI 收到数字键,继续执行
```

### 2.2 关键设计决策

| # | 决策 | 原因 |
| - | ---- | ---- |
| 1 | **Hook 永不阻塞**,一律返回 `ask` | Claude Code hook 在非交互 shell 里跑,抢不到 TTY;阻塞会吃满 600s 超时 |
| 2 | **卡片永不超时** | 用户明确要求"超时≠拒绝";兜底靠"终端始终可响应",而不是替用户决定 |
| 3 | **按钮回调走 `tmux send-keys`** | Claude Code 原生 UI 只认 stdin,没别的办法注入决定;而且原生 UI 在 hook `ask` 时只有 2 选项(1. Yes / 2. No),不是 3 选项 |
| 4 | **`allow_session` 在 daemon 侧维护白名单文件**,hook 第 3 步读它 | 原生 UI 没有"本会话全允许"按钮,我们自己兜底 |
| 5 | **daemon 和 Claude Code 必须同机** | `tmux send-keys` 需要 daemon 能看到那个 tmux server,所以 daemon 跑在远程服务器上,不在 Mac 本地 |
| 6 | **launchd plist / systemd unit 都显式清空代理** | 继承环境里的 `all_proxy=socks5://...` 会让 lark-oapi WS 要求 `python-socks`;飞书国内直连更稳 |
| 7 | **`card.action.trigger` 走 WS 长连** | 免公网 IP、免 HTTPS 回调。`lark-oapi` v2 `lark.ws.Client` 自带 auto_reconnect |

### 2.3 双端并存,不做 race

- 终端 UI 和飞书卡片**始终同时在线**
- **谁先响应谁胜出**:
  - 终端先按 `1`/`2` → Claude Code 继续;之后手机再点,daemon 发现 `result/<req_id>.json` 已存在 → 显示 `build_handled_card` 灰色"已在终端处理"
  - 手机先点 → daemon 写 result + send-keys → 终端 UI 自动消失,卡片变 `build_result_card`
- 没有"优先级"、没有"超时切换",只有"胜者写 result"

## 3. 代码结构

```
claude-feishu-remote/
├── install.sh                # 跨平台幂等安装(macOS launchd / Linux systemd)
├── uninstall.sh              # 跨平台回滚
├── .env.template             # FEISHU_APP_ID / FEISHU_APP_SECRET / FEISHU_TARGET_OPEN_ID
├── bin/afk                   # CLI: afk on|off|status
├── hooks/
│   ├── approve.sh            # PreToolUse,5 级决策,永不阻塞
│   └── notify.sh             # Stop/Notification 占位
├── daemon/
│   ├── feishu_daemon.py      # WS 长连 + pending 轮询 + 按钮回调(send-keys)
│   ├── cards.py              # 审批卡 / 结果卡 / "已处理"卡
│   ├── ipc.py                # pending/result/session-allow 文件协议
│   ├── config.py             # env 和路径常量
│   └── requirements.txt      # lark-oapi, python-dotenv
├── launchd/
│   ├── com.user.feishu-claude.plist.template    # macOS
│   └── feishu-claude.service.template           # Linux systemd user unit
└── docs/
    ├── DESIGN.md             # (本文档)
    └── feishu-app-setup.md   # 飞书开放平台一次性配置
```

### 3.1 approve.sh 决策逻辑

```
input = stdin JSON ({session_id, tool_name, tool_input, tool_use_id, permission_mode, cwd, ...})

if permission_mode == "bypassPermissions":        → allow
elif permission_mode == "acceptEdits" and tool in {Write,Edit,MultiEdit,NotebookEdit}:
                                                  → allow
elif tool_name ∈ session_allow_list[session_id]:  → allow
elif not sentinel_exists():                       → ask            (afk off)
else:                                             写 pending,→ ask (afk on,双端并行)
```

返回格式(PreToolUse hook 现代输出):
```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow|ask"}}
```

### 3.2 daemon 按钮回调逻辑

```
on_card_action:
  req_id, action ← data.event.action.value
  if result/{req_id}.json 已存在:          → 显示 handled_card,什么都不做
  key = "2" if action == "deny" else "1"
  if action == "allow_session":             写 session-allow/{session_id}
  tmux send-keys -l -t <pending.tmux_pane> <key>
  写 result/{req_id}.json
  return P2CardActionTriggerResponse(card=result_card, toast="已xx")
```

### 3.3 运行时目录

```
~/.claude/feishu-remote/
├── away-mode                           # sentinel,存在=afk on
├── pending/<tool_use_id>.json          # hook 写,daemon 读
├── result/<tool_use_id>.json           # daemon 写(或双端 race 的胜者写),防重复
├── session-allow/<session_id>          # 每行一个 tool_name 或 "*"
├── daemon.log / hook.log               # 日志
└── daemon.stdout.log / .stderr.log     # launchd/systemd 捕获
```

## 4. 部署

### 4.1 macOS (launchd user agent)

```bash
cd ~/aiDev/others/claude-feishu-remote
bash install.sh                                   # 幂等
cp .env.template ~/.claude/feishu-daemon/.env     # 填 App ID/Secret/open_id
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.feishu-claude.plist
```

`install.sh` 做的事:
- 选 python3(优先 `/opt/homebrew/bin/python3`)
- 自动装 jq、tmux(通过 brew,非交互 shell 下自己补 PATH)
- 深度 merge `~/.claude/settings.json` 里的 hooks 字段(保留原有)
- 软链 hooks / daemon / afk
- 渲染 plist,`launchctl bootstrap gui/<uid>`(若 .env 存在)

验证:`afk status` 应显示 `daemon : running`。

### 4.2 Linux (systemd user unit,tprod 待验证)

```bash
cd ~/aiDev/others/claude-feishu-remote
bash install.sh
# 脚本会提示:sudo loginctl enable-linger $(id -un)   ← 登出 ssh 后服务继续跑
cp .env.template ~/.claude/feishu-daemon/.env
systemctl --user enable --now feishu-claude.service
```

注意事项:
- systemd user unit 默认**登出 ssh 就停**,必须 `loginctl enable-linger`
- Ubuntu 用 apt 装 jq/tmux,install.sh 会自动调
- 清代理变量在 unit 的 `[Service]` 段,和 plist 一致

### 4.3 卸载

```bash
bash ~/aiDev/others/claude-feishu-remote/uninstall.sh
```

保留 `.env` 和 runtime 数据,其他清干净。

## 5. 飞书开放平台配置(一次性)

详见 `docs/feishu-app-setup.md`。要点:

1. 自建应用,加"机器人"能力
2. 权限:`im:message`、`im:message:send_as_bot`
3. **事件与回调切"长连接 / WebSocket"**(关键,免公网 IP)
4. 订阅事件:`im.message.receive_v1`、`card.action.trigger`
5. 拿三个填 `.env`:`App ID`、`App Secret`、用户自己的 `open_id`(可以让 daemon 日志帮你打,@机器人发一条消息就打出来了)

## 6. 关于 Phase 2 (Stop/Notification 通知)

目前 `notify.sh` 是占位。后续可做:
- 用户不在终端时,Claude Code 停完(Stop hook)→ daemon 推一条简短飞书消息,告诉用户完成了,可以打开手机查看/继续
- Notification hook(权限请求之外的 Claude Code 通知)同样转发

这不是审批闭环必需,优先级低。

## 7. 验证记录

### 2026-04-28 openClawMac

三按钮端到端(daemon.log 摘要):
```
19:21:05 card sent req=toolu_bdrk_013DvwX3...
19:21:46 card.action.trigger action=allow
19:21:46 tmux send-keys ok pane=%0 key=1 decision=allow            ✔
19:20:06 card sent req=toolu_bdrk_01BiXp...
19:21:50 card.action.trigger action=deny
19:21:50 tmux send-keys ok pane=%0 key=2 decision=deny             ✔
19:22:17 card sent req=toolu_bdrk_013kr4...
19:22:28 card.action.trigger action=allow_session
19:22:28 session allow-list granted session=3a504aad... tool=Bash  ✔
19:22:28 tmux send-keys ok pane=%0 key=1 decision=allow_session    ✔
```

- WS 长连稳定(`connected to wss://msg-frontier.feishu.cn/ws/v2`)
- `afk status` 显示 `daemon : running`(修了老 `launchctl list` 探活 bug)

### tprod

**尚未部署**。要做:
1. rsync 代码到 tprod
2. `bash install.sh`(Linux 分支)
3. `sudo loginctl enable-linger tal`
4. 拷 .env、`systemctl --user enable --now feishu-claude.service`
5. tmux 里跑 `claude -p 'run ls'`,三按钮各一次

## 8. 已知局限和未来改进

- **只能同机(Claude Code 和 daemon)**:因为要 `tmux send-keys`。要跨机,可能得做 "WebSocket 从 Mac 回到远程 tmux" 之类的管道,成本高,当前不做。
- **tmux 是硬依赖**:不在 tmux 里跑 Claude Code 时,手机按钮无效(`TMUX_PANE` 为空,daemon 会报错 toast)。可以接受,我们本来就只在 tmux 里用。
- **`allow_session` 粒度是 tool_name 级**,不是 "这条命令" 级。想 "只允许这一条 Bash" 得用 `allow` 单次。
- **没有 web UI / Skill 打包**。纯命令行工程。
- **没有 `/afk` 远程切换**:想在手机上打开 afk 模式需要本地 `afk on`。可以补:daemon 里收到 `@机器人 afk on/off` 时 `touch`/`rm` sentinel。

## 9. 铁律(改这个项目时)

1. **hook 永不阻塞**。任何想加的新功能都不能让 hook 等网络。
2. **daemon 必须和 Claude Code 同机**。`tmux send-keys` 的前提。
3. **推 tprod 之前先在 openClawMac 验一次**,tprod 是线上。
4. **launchd/systemd 的 Environment 里代理清空**,每改 unit 文件都要检查。
5. **卡片不加超时**。真想加"提醒",做成单独通知而不是"xxx 后变 deny"。
