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

## 6. 绑定审批者 `open_id`(自动)

审批卡片要推给你自己,所以 daemon 需要知道你的 `open_id`。**不用手动查**——启动后在飞书 1:1 对话里发一句话就行,daemon 会自动绑定并把 open_id 回写到 `.env`。

1. **填好 APP_ID / APP_SECRET,open_id 留空**

   `~/.claude/feishu-daemon/.env`:
   ```
   FEISHU_APP_ID=cli_xxxxxxxxxxxx
   FEISHU_APP_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   FEISHU_TARGET_OPEN_ID=
   ```

2. **启动 daemon**

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

   日志里会看到:`FEISHU_TARGET_OPEN_ID 未绑定,等待首条 1:1 消息自动绑定…`。

3. **在飞书 1:1 对话里给机器人发一句话**

   搜机器人名字 → 加为好友 → **私聊**里发任意内容(比如 `hi`)。

   手机上会立刻收到 daemon 的回复 `已绑定审批者`,`.env` 里的 `FEISHU_TARGET_OPEN_ID=` 也会被自动填好。完成。

### 为什么只接受 1:1 消息

如果机器人还在其他群里,群消息会被 daemon **主动忽略**。这样即使有人先在群里 @机器人,也不会抢到你的绑定位。TOFU(Trust On First Use)是"第一条 1:1 消息",不是"第一条任何消息"。

### 换人 / 换主机怎么办

```bash
afk unbind                                           # 清空 .env 里的 FEISHU_TARGET_OPEN_ID
launchctl kickstart -k gui/$(id -u)/com.user.feishu-claude   # 重启 daemon
# 新的人发一条 1:1 消息即可接管
```

### 手动查(可选,不推荐)

如果自动绑定不能用,也可以去飞书开放平台后台「通讯录 → 成员 → 你自己」翻 open_id(有的租户隐藏),手动填入 `.env` 里 `FEISHU_TARGET_OPEN_ID=ou_...` 再重启 daemon。

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
