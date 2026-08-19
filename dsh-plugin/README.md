# dsh-plugin — Discipline pet 的 DSH 状态插件（方案 A）

让桌宠读取 DeepSeek Harness 的实时状态。

## 原理

`live-status.mjs` 是跑在 DSH 进程内的 host 插件：订阅 `session/event`
（turn/start、approval/asked、turn/end 等），把聚合后的状态实时写到
`$DSH_HOME/live-status.json`（默认 `~/.dsh/live-status.json`）。
桌宠（Swift 侧 `DSHStatusMonitor`）每秒轮询该文件。

文件字段：`state`（idle/running/needs/ready/blocked）、`detail`、`diagnostic`、
`updatedAt`（最近事件时间=活动）、`heartbeatAt`（最近写入时间=插件存活）、
`sessions`（各会话明细）。

## 安装（一次性）

```bash
# 1. 插件文件放在 profile 之外，避免 profile 重新初始化被清掉
mkdir -p ~/.dsh/plugins
cp live-status.mjs ~/.dsh/plugins/live-status.mjs

# 2. 用 home 级补丁（$DSH_HOME/cordis.patch.yml）挂载插件
cp cordis.patch.yml ~/.dsh/cordis.patch.yml

# 3. 重启 DSH（补丁在启动时加载；会结束当前 DSH 会话）
npx -y @deepseek-ai/dsh web
```

## 卸载 / 故障恢复

- 删除 `~/.dsh/cordis.patch.yml`（或还原为 `[]`）。
- 删除 `~/.dsh/plugins/live-status.mjs`。
- 重启 DSH。

## 说明

- 插件只写状态文件，不读取/记录对话内容。
- 写失败（磁盘/权限）不致命：桌宠会把状态视为 stale 并回退到 Codex。
- 桌宠侧规则：`heartbeatAt` 30 秒内新鲜 = DSH 在线；DSH 与 Codex 按
  「最近活动」抢占；都离线时回退到会话日志。

## 状态语义（v2）

- `running`：`turn/start` / 工具活动。
- `needs`：`approval/asked`，**粘住**直到 `approval/decided`（或会话 30 分钟无活动）。
- `ready`：`turn/end completed`，**时间制**，默认停留 60s（`config.readyWindowMs` 可改）后回 idle。
- `blocked`：`turn/end` 的 error/aborted/interrupted/halted/failed/rejected/blocked/cancelled/max-tokens，
  **粘住**：不因时间过期，直到恢复事件（同会话新 `turn/start`、`approval/asked` 或新 `session`）才切换。
- 插件 mjs 是代码，补丁 yml 只负责挂载并传 `config`（重启 DSH 生效）；改 yml 的值不会改写 mjs。
- **停机标记**：插件监听 `SIGINT`/`SIGTERM`/`exit`，DSH 进程退出前同步把
  `heartbeatAt` 置 0，桌宠下一次轮询（≤1 秒）即判定 DSH 离线并丢弃其状态——
  因此 Ctrl+C 退出不会被显示成 blocked（点 Stop 时进程未死，blocked 照常显示）。
