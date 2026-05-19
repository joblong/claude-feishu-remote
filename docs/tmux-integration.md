# tmux 集成(可选)

> 在 tmux 状态栏常驻显示 afk 模式,并用一个空闲的快捷键一键切换 `afk on/off`。完全可选 —— 不配也能正常用 `afk` CLI。

## 为什么放在 tmux 里

`bin/afk` 启动时会检查 `$TMUX`,要求**必须在 tmux 内**才能 `afk on`。原因是离开模式下 Claude Code 会被 hook 阻塞等飞书回调,如果不在 tmux 里,本地终端一关就断,远程审批也就失去意义。

既然 afk 与 tmux 强绑定,把状态栏指示器和切换键也放进 `.tmux.conf` 是顺理成章的。

## 状态栏指示器

在 `~/.tmux.conf` 里加(或合并进现有 `status-right`):

```tmux
set -g status-right '#(test -e ~/.claude/feishu-remote/away-mode && echo "🏃 afk" || echo "💻 tty") | %Y-%m-%d %H:%M'
set -g status-right-length 60
set -g status-interval 5
```

效果:

| 显示 | 含义 |
| --- | --- |
| `🏃 afk` | 离开模式,飞书审批生效 |
| `💻 tty` | 终端模式,Claude Code 原生 UI |

原理是 `test -e` 探测 sentinel 文件 `~/.claude/feishu-remote/away-mode` 是否存在。`status-interval 5` 让状态栏每 5 秒刷新一次,`afk on/off` 后最多 5 秒就会反映。

## 一键切换键

把 tmux 默认 prefix 改为 `C-a` 之后,`C-b` 就空出来了,正好用作 afk 切换:

```tmux
set -g prefix C-a
unbind C-b
bind C-a send-prefix

bind -n C-b run-shell ' \
    if [ -e ~/.claude/feishu-remote/away-mode ]; then \
        ~/.local/bin/afk off >/dev/null 2>&1; \
        tmux display "afk: OFF 终端模式"; \
    else \
        ~/.local/bin/afk on >/dev/null 2>&1; \
        tmux display "afk: ON 离开模式(飞书审批已生效)"; \
    fi'
```

要点:

- `bind -n` 表示**不需要 prefix**,直接 `Ctrl+B` 触发,在任意 pane 生效
- 不在 tmux 里时按不到这个键 —— 天然约束了 `afk on` 只能在 tmux 内开启,与 `bin/afk` 的 `$TMUX` 检查一致
- 如果你想保留默认 prefix `C-b`,把上面 `bind -n C-b ...` 换成其他空闲键即可,例如 `bind -n C-y ...`

热重载:在 tmux 里按 `C-a r`(若已绑定 `bind r source-file ~/.tmux.conf`),或 `tmux source-file ~/.tmux.conf`。

## 优雅降级

两段配置都不会因为 claude-feishu-remote 没装而出错:

- `test -e` 文件不存在时返回非零,状态栏直接显示 `💻 tty`
- `C-b` 触发时 `~/.local/bin/afk` 不存在,`run-shell` 静默失败,tmux 仍显示提示文案(只是真正的切换不会发生)

所以你可以放心把这段配置同步到尚未安装 claude-feishu-remote 的机器上。

## 完整参考配置

仓库里有一份开箱即用的样例:[`examples/.tmux.conf`](../examples/.tmux.conf)。除了上面两段 afk 集成,还包含:

- 前缀键改 `C-a`、`escape-time 0`、`history-limit 50000`
- `C-q` 进复制模式 + Vi 键位 + OSC 52 剪贴板(SSH 远端也能用)
- `C-a |` / `C-a -` 分屏继承当前目录
- `C-a h/j/k/l` Vim 风格切面板
- `C-g` 一键切换鼠标 ON/OFF
- `C-a r` 热重载

### 一键应用

如果你**没有**自己的 `.tmux.conf`,直接拷过去:

```bash
cp examples/.tmux.conf ~/.tmux.conf
tmux source-file ~/.tmux.conf   # 已在 tmux 里就这样重载,否则下次启动自动生效
```

如果你**已经有**自己的配置,只摘上面两段(状态栏 + `C-b` 切换)即可,其余按需。

### 多机同步

samples 文件就是普通配置文件,跨机同步用 `scp` 最简单:

```bash
scp examples/.tmux.conf user@host:~/.tmux.conf
ssh user@host 'tmux source-file ~/.tmux.conf 2>/dev/null || true'
```

校验三端一致:

```bash
shasum examples/.tmux.conf
ssh user@host 'shasum ~/.tmux.conf'
```

> ⚠️ `install.sh` **不会**自动碰你的 `~/.tmux.conf` —— `examples/` 只是参考样例,需要你手动拷或合并。这是有意设计,避免覆盖你已有的 tmux 配置。
