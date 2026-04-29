# claude-feishu-remote

Claude Code CLI × 飞书 双模式远程审批。

- **终端模式** (`afk off`,默认):Claude Code 原生权限 UI 照常弹出,飞书零打扰
- **离开模式** (`afk on`):PreToolUse hook 阻塞等飞书,手机点按钮决定允许/拒绝
- 按钮:**允许 / 拒绝 / 本会话全允许**
- 不需要公网 IP / ngrok / cloudflared —— 飞书 `card.action.trigger` 走 WebSocket 长连

## 架构

```
Claude Code ──PreToolUse(stdin JSON)──▶ ~/.claude/hooks/approve.sh
                                              │
                               ┌──────────────┴───────────────┐
                               │                              │
                     sentinel 不存在              sentinel 存在
                     (终端模式)                   (离开模式)
                          │                              │
                          ▼                              ▼
              返回 permissionDecision        写 pending/<tool_use_id>.json
                   = "ask"                  等 result/<tool_use_id>.json
              Claude Code 原生 UI                         │
                                                          ▼
                                                 feishu-daemon (WS)
                                                          │
                                                          ▼
                                                     手机飞书卡片
                                                     ├ 允许 / 拒绝
                                                     └ 本会话全允许
```

## 安装

```bash
git clone https://github.com/joblong/claude-feishu-remote.git
cd claude-feishu-remote

# 1) 把 .env.template 复制并填入飞书 App 凭证
cp .env.template ~/.claude/feishu-daemon/.env   # install.sh 会自动建目录
# 编辑 ~/.claude/feishu-daemon/.env 三个字段

# 2) 安装(幂等,可重复)
bash install.sh
```

前置:macOS + Python ≥ 3.9 + Homebrew(脚本会自动 `brew install jq`)。

## 飞书应用配置

见 [docs/feishu-app-setup.md](docs/feishu-app-setup.md)。要点:

- 自建应用 + 添加机器人
- 权限:`im:message`、`im:message:send_as_bot`
- **事件订阅模式切为"长连接 / WebSocket"**(而不是 Request URL)
- 订阅两个事件:`im.message.receive_v1`、`card.action.trigger`

## 使用

```bash
afk status     # 查 sentinel 和 daemon 状态
afk on         # 打开离开模式(出门前一键)
afk off        # 关闭(回到终端)

tail -f ~/.claude/feishu-remote/daemon.log    # 看 daemon 日志
tail -f ~/.claude/feishu-remote/hook.log      # 看 hook 被触发的记录
```

## 当前状态

**脚手架阶段** — 目录结构、install/uninstall、daemon 空壳、hook 返回 `ask`。功能未完全就绪:

- ✅ 安装/卸载幂等
- ✅ Daemon 启动、订阅两个事件、打日志
- ✅ Hook 返回 `ask`,不干扰 Claude Code 原生 UI
- ⏳ Phase 2: 接收飞书消息能打印发送者 open_id(方便拿目标 ID)
- ⏳ Phase 3: sentinel 切换、pending/result 文件协议、卡片闭环
- ⏳ Phase 4: 白名单、`/afk` 远程切换、Stop 通知、Skill 打包

## 卸载

```bash
bash uninstall.sh    # 在 clone 下来的目录里执行
```

## 致谢

设计中直接参考/借鉴了:
- [joewongjc/feishu-claude-code](https://github.com/joewongjc/feishu-claude-code) — WS 长连客户端、看门狗思路
- [Cygra/claude-code-feishu-hooks](https://github.com/Cygra/claude-code-feishu-hooks) — 卡片 JSON schema
- [MarioZZJ/cc-notify-hooks](https://github.com/MarioZZJ/cc-notify-hooks) — pending 文件机制
- [kyujin-cho/claude-code-remote](https://github.com/kyujin-cho/claude-code-remote) — hook 旁路 + 白名单设计
