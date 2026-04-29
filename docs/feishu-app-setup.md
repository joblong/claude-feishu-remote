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

1. 把 .env 里 APP_ID / APP_SECRET 填好,daemon 先跑起来(`launchctl bootstrap …` 或 `python3 -m daemon.feishu_daemon`)
2. 在飞书里把机器人拉到 1:1 对话,@机器人 随便说一句
3. `tail ~/.claude/feishu-remote/daemon.log` 会看到类似:
   ```
   im.message.receive_v1 open_id=ou_xxxxxxxxxxxxxxxxxxxxx chat_id=oc_... content=...
   ```
4. 把 `ou_...` 写入 `.env` 的 `FEISHU_TARGET_OPEN_ID`,重启 daemon

**方法 B**:开放平台后台「通讯录 → 成员 → 你自己」也能看到 open_id(有的租户隐藏)。

## 常见坑

- **「长连接」灰掉 / 不能选**:某些老企业套餐限制。临时方案:先用 Request URL + `cloudflared tunnel`(免费)代替,后续再切长连
- **事件订阅 UI 里找不到 `card.action.trigger`**:确认已添加「机器人」能力;个别旧版 UI 叫「卡片回传」
- **权限申请后没生效**:审核状态要"已通过"才能用;自己是管理员可秒过
- **消息发不出来**:目标用户必须和机器人"互加好友"(在 1:1 里发送过任何消息)
