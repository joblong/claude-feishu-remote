# 飞书自建应用配置(一次性,~15 分钟)

> 目标:拿到 `FEISHU_APP_ID` / `FEISHU_APP_SECRET` / `FEISHU_TARGET_OPEN_ID`,并让应用能通过 WebSocket 长连接收 `card.action.trigger` 事件。

## 1. 建应用

1. 打开 <https://open.feishu.cn/app>,登录
2. 创建企业自建应用 → 填名称/图标
3. 在「凭证与基础信息」页拿到 **App ID** 和 **App Secret**(填入 `.env`)

## 2. 添加机器人能力

侧栏「添加应用能力」→ 添加「机器人」。

## 3. 权限配置

侧栏「权限管理」→ 搜索并勾选:

| 权限 | 用途 |
| --- | --- |
| `im:message` | 发消息 / 更新消息 |
| `im:message:send_as_bot` | 以机器人身份发消息 |
| `im:resource` | (可选)下载/上传资源 |

勾选后「申请发布」,管理员审批通过才生效。开发者自建企业通常自己就是管理员。

## 4. 事件订阅 — 切换为长连接

这是**最关键的一步**。

1. 侧栏「事件与回调」(或「事件订阅」)
2. 订阅方式选 **「使用长连接接收事件」** / `WebSocket`,不要填 Request URL
3. 在「订阅事件」里搜索并添加:
   - `im.message.receive_v1` — 机器人接收消息
   - `card.action.trigger` — 按钮回调

## 5. 版本发布

「版本管理与发布」→ 创建版本 → 提交审核 → 发布。开发者版本对自己租户立即生效。

## 6. 拿目标 `open_id`

审批卡片推给你自己,所以需要**你的** open_id。

**方法 A**(推荐 — daemon 自动打印):

daemon 订阅了 `im.message.receive_v1`,机器人收到任何消息时都会在日志里打印发送者的 open_id。思路是:先让 daemon 跑起来,然后给机器人发一句话,读日志拿值。

1. **填占位凭证让 daemon 能启动**

   编辑 `~/.claude/feishu-daemon/.env`,把 `FEISHU_APP_ID` 和 `FEISHU_APP_SECRET` 填成真实值。`FEISHU_TARGET_OPEN_ID` 这一行**必须非空**(代码里是 `required=True`),先随便填个占位值:
   ```
   FEISHU_APP_ID=cli_xxxxxxxxxxxx
   FEISHU_APP_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   FEISHU_TARGET_OPEN_ID=ou_placeholder
   ```

2. **启动(或重启) daemon**

   macOS:
   ```bash
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.feishu-claude.plist
   # 已加载过的话用 kickstart 重启:
   launchctl kickstart -k gui/$(id -u)/com.user.feishu-claude
   ```

   Linux:
   ```bash
   systemctl --user restart feishu-claude.service
   ```

   确认启动成功:
   ```bash
   afk status       # 应显示 daemon : running
   tail ~/.claude/feishu-remote/daemon.log    # 应看到 "daemon starting" 和 WebSocket 连接日志
   ```

3. **给机器人发消息**

   在飞书里搜你创建的机器人名字 → 加为好友 → 1:1 对话里发任意一句(比如 `hello`)。

4. **读日志拿 open_id**

   ```bash
   tail -f ~/.claude/feishu-remote/daemon.log
   ```

   你会看到类似这样一行(来自 daemon 的 `on_message` handler):
   ```
   2026-04-29 ... INFO feishu-daemon: im.message.receive_v1 open_id=ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx chat_id=oc_xxx content=...
   ```

   复制 `ou_` 开头那一串(32 位 hex)。

5. **回填真实 open_id 并重启**

   把 `.env` 里 `FEISHU_TARGET_OPEN_ID=ou_placeholder` 改成刚拿到的真实 `ou_...`,重启 daemon(同步骤 2)。

**方法 B**:开放平台后台「通讯录 → 成员 → 你自己」也能看到 open_id(有的租户隐藏)。

## 7. 端到端自测

```bash
afk on                      # 必须在 tmux 里(bin/afk 会检查 $TMUX)
claude -p 'run ls'          # 在同一 tmux pane 里
```

触发 Bash 工具调用时,手机飞书应该收到审批卡片。点「允许」/「拒绝」,Claude Code 继续或中止。

## 常见坑

- **「长连接」灰掉 / 不能选**:某些老企业套餐限制。临时方案:先用 Request URL + `cloudflared tunnel`(免费)代替,后续再切长连
- **事件订阅 UI 里找不到 `card.action.trigger`**:确认已添加「机器人」能力;个别旧版 UI 叫「卡片回传」
- **权限申请后没生效**:审核状态要"已通过"才能用;自己是管理员可秒过
- **消息发不出来**:目标用户必须和机器人"互加好友"(在 1:1 里发送过任何消息)
