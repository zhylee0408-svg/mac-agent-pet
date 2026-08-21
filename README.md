# Discipline Companion

Discipline 是 macOS 本地浮动桌宠，实时显示你正在用的 agent（DeepSeek Harness 或 Codex Desktop）的运行状态。它不修改任何应用，也不展示/复制/记录对话内容。

## 状态源：两个平等的可选源

桌宠监控 **DSH（DeepSeek Harness）** 和 **Codex Desktop** 两个状态源，两者**地位平等、无固定来源优先级**。桌宠先比较状态语义，状态相同时才比较最近活动时间：

- **DSH**：通过 `dsh-plugin`（跑在 DSH 进程内的插件，见 `dsh-plugin/`）把实时状态写入 `~/.dsh/live-status.json`，桌宠轮询该文件。
- **Codex**：只读连接 Codex Desktop 的本地 IPC（follower 协议），实时订阅任务线程状态；连接成功但没有任务时明确发布“在线 + Idle”，只有 follower 断开才视为离线。`~/.codex/sessions/**/*.jsonl` 会话日志用于发现任务，并在 follower 在线时补充 Ready/Blocked 转场。

Codex follower 在任务边界发生短暂重连时，Discipline 会先保留 Codex 的 Idle 来源归属最多 10 秒，避免刚完成就瞬间跳回另一个 Idle 来源；10 秒内未恢复才正式视为离线。菜单栏 Bridge 以实时快照和明确的连接事件判断 `follower live` / `reconnecting`，不会把诊断计数中的 `0 waiting` 误判成断连。

驱动选择规则：`Needs input > Blocked > Running > Ready > Idle`；同状态时最近活动的来源获胜。若一个来源刚完成、另一个来源处于更高状态，Ready 会插播 **5 秒**后返回更高状态；没有更高状态时 Ready 正常停留 60 秒。两个源都 Idle 时保留最近 30 分钟内活动过的来源；都没有近期活动或两个实时源都离线时显示中立（`—`）。

## 状态语义（DSH 与 Codex 已对齐）

| 状态 | 触发 | 语义 |
|---|---|---|
| `running` | turn/task 开始或进行中 | 保持到明确的完成、失败、取消或来源离线 |
| `needs` | 等待批准/用户输入 | 保持到批准/回答、任务结束或来源离线 |
| `ready` | turn/task 完成 | 停留 **60 秒** → idle |
| `blocked` | 出错/中止/失败 | 最长保留 **10 小时**；恢复事件（新 turn/新任务/批准请求）会提前清除 |

> 30 分钟只用于两个来源都 Idle 后的“最近使用来源”归属，不会把 Running 或 Needs input 强制降级为 Idle。

> Codex 会话日志兜底有额外约束：只统计最近 24h 更新过的会话；且兜底的 blocked
> 只在出错后 10 小时内有效（陈旧故障不报红）。DSH 路径的 blocked 同样有 10h 上限，
> 并由插件在重启时恢复 10h 内的历史故障（昨晚出错、今早重开 → 爆红）。

## 菜单栏

菜单栏图标提供：状态来源行（`DSH` / `Codex` / `—`）、`State` 行、detail 行、`Bridge:` 连接诊断行，以及：

- **Open ▸**：`Open Codex`、`Open DSH`（若 `127.0.0.1:3080` 不通则自动后台拉起 DSH 后打开浏览器；启动目录可用 `defaults write com.zhylee.discipline dshLaunchDir <路径>` 配置，默认 `~`）
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

## Android 本地预览

`Android/` 内包含当前轻量移动端同步预览：五色状态灯、Offline、通知排版、声音规则、针对 ColorOS 15 动态状态栏图标的无 root 兼容实现，以及真实配对、端到端解密和 FCM 后台接收入口。

构建并通过 USB 覆盖安装：

```bash
./Android/build.sh
./Android/install.sh
```

产物为 `Android/Discipline-local-preview.apk`。完整范围、ColorOS 实现约束和验收步骤见 `Android/README.md`。

## 移动端真实同步（待首次配对验证）

真实同步沿用 `Protocol/` 和 `Relay/` 的 v1 协议：Mac 只上传最终来源、五态、各来源在线状态和更新时间；对话正文、终端输出、文件内容与 detail 文本都不会进入移动端 payload。状态在 Mac 上使用 X25519 + HKDF-SHA256 派生的 AES-256-GCM 密钥加密，中继只转发密文，并在 10 分钟没有心跳后发送签名 Offline 事件。

Mac 菜单中的 **Mobile sync ▸** 已包含配对状态、**Copy pairing code** 和 **Revoke phone access…**。配对码是五分钟有效的 `discipline://pair?...` 文本；Android 后续只需粘贴到单一输入框并点击 Connect。手机自行生成设备 ID、私钥和访问令牌，长期密钥不会直接放进配对码。

公网中继已部署并通过健康检查。下一检查点通过以下偏好项给 Mac 指定真实 Worker 地址与 Ed25519 公钥：

```bash
defaults write com.zhylee.discipline mobileRelayURL 'https://discipline-relay.discipline-zhylee.workers.dev'
defaults write com.zhylee.discipline mobileRelaySigningPublicKey '8VxJWAv2SMq6GKqimymk8r6EY8VWUJ8K1PxatV3OTRY'
```

未配置时菜单明确显示 `Mobile: Not configured`，也不会发起状态上传。中继只保存配对与路由元数据，不保存状态密文、任务正文、终端输出或文件内容。
