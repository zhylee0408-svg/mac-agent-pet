# Discipline Companion

Discipline 是 macOS 本地浮动桌宠，实时显示你正在用的 agent（DeepSeek Harness 或 Codex Desktop）的运行状态。它不修改任何应用，也不展示/复制/记录对话内容。

## 状态源：两个平等的可选源

桌宠监控 **DSH（DeepSeek Harness）** 和 **Codex Desktop** 两个状态源，两者**地位平等、无默认优先级**——谁最近在干活谁就是当前驱动源（活动抢占），你正在用谁，桌宠就显示谁的状态：

- **DSH**：通过 `dsh-plugin`（跑在 DSH 进程内的插件，见 `dsh-plugin/`）把实时状态写入 `~/.dsh/live-status.json`，桌宠轮询该文件。
- **Codex**：只读连接 Codex Desktop 的本地 IPC（follower 协议），实时订阅任务线程状态；Codex Desktop 不可用时回退到 `~/.codex/sessions/**/*.jsonl` 会话日志。

驱动选择规则：两个源都空闲时取最近 30 分钟内活动过的那个；都没有近期活动则显示中立（`—`）；两个都离线才用会话日志兜底。

## 状态语义（DSH 与 Codex 已对齐）

| 状态 | 触发 | 语义 |
|---|---|---|
| `running` | turn/task 开始或进行中 | 30 分钟无活动 → idle |
| `needs` | 等待批准/用户输入 | **粘住**，直到决定（或 30 分钟无活动） |
| `ready` | turn/task 完成 | 停留 **60 秒** → idle |
| `blocked` | 出错/中止/失败 | **粘住**，直到恢复事件（新 turn/新任务/批准请求）才切换 |

> Codex 侧额外有一条 24 小时会话新鲜度过滤：超过 24h 未更新的会话不计入（含粘住 blocked）。

## 菜单栏

菜单栏图标提供：状态来源行（`DSH` / `Codex` / `—` / `Session logs`）、`State` 行、detail 行、`Bridge:` 连接诊断行，以及：

- **Open ▸**：`Open DSH`（若 `127.0.0.1:3080` 不通则自动后台拉起 DSH 后打开浏览器；启动目录可用 `defaults write com.zhylee.discipline dshLaunchDir <路径>` 配置，默认 `~`）、`Open ChatGPT`
- **Preview state ▸**：临时预览 5 个状态
- **Show / Hide**

## 构建

```bash
./build.sh
./build/Discipline.app/Contents/MacOS/Discipline --self-test
open ./build/Discipline.app
```

## 本地安装

安装位置刻意放在 `/Applications` 之外（不出现在启动台）：

```text
~/Library/Application Support/Discipline/Discipline.app
```

启动器 `discipline` 安装在 `/opt/homebrew/bin`（已在 PATH），运行即启动桌宠且不阻塞终端。桌宠已注册为登录项（开机自启）。重新构建后更新隐藏安装：

```bash
./Scripts/update-hidden.sh
```

## DSH 插件安装

见 `dsh-plugin/README.md`：把 `live-status.mjs` 放到 `~/.dsh/plugins/`、`cordis.patch.yml` 放到 `~/.dsh/`（home 级补丁），重启 DSH 生效。`readyWindowMs`（默认 60000）可在补丁 `config` 中调整。
