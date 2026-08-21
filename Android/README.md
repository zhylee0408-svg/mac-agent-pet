# Discipline for Android — 同步预览版

这是可直接安装的轻量同步预览包。它保留已经在 OnePlus 13T / ColorOS 15 上验证过的状态灯和通知效果，并加入 Mac 配对、安全存储、端到端状态解密以及 Firebase 后台消息入口。

Android 应用已注册到 Firebase 项目 `discipline-mobile`，并通过 `google-services.json` 与 Google Services Gradle 插件获得 FCM 配置。公网中继已经部署并通过健康检查；真实 Mac → Relay → Android 状态同步只差下一检查点的首次配对和六状态实机验证。

## 已实现

- 五枚横向状态灯：Blocked 红、Needs input 黄、Running 蓝、Ready 绿、Idle 灰。
- 应用使用白色浅色界面；进入应用后，状态栏与导航栏切换为深色图标，确保时间、网络和电量信息清晰可见。
- Offline 是独立的传输状态：五盏灯全部熄灭，图标显示断环。
- 六种状态栏图形：叉号、感叹号、实心圆、对勾、空心圆、断环。
- 与 macOS Discipline 菜单栏桌宠同源的自适应启动图标。
- 折叠通知排版：

  ```text
  ●  Discipline
  Source: Codex    Status: Running
  Updated: 14:32:18    2026-08-20
  ```

- 展开通知额外显示 `Codex: …` 与 `DSH: …`。
- Ready、Needs input、Blocked 在状态转入时响一声，不振动。
- Running、Idle、Offline、恢复至 Running/Idle，以及仅来源变化但状态不变时保持静默。
- `Preview State` 横向状态选择器，可逐一检查六种显示。
- 通知可以滑走；切换预览状态后会重新出现，不强制置顶或设为不可清除。
- 未配对时只显示一个配对码输入框和 `Connect` 按钮；配对码采用 Mac 生成的五分钟一次性 `discipline://pair?...` URI。
- Android 生成独立的 X25519 设备密钥和访问令牌；配对配置使用 Android Keystore AES-GCM 加密后保存。
- 手机与 Mac 通过 X25519 + HKDF-SHA256 派生状态密钥；每个状态载荷再以 AES-256-GCM 加密，并按递增序号拒绝重放。
- Relay 离线事件使用 Ed25519 签名验证，不能伪造普通状态消息。
- FCM data-only 消息由后台 `FirebaseMessagingService` 接收，无需打开 App；新版 FCM installation ID 会在轮换时回传 Relay。
- `Unpair` 会删除 Relay 端设备登记和手机本地密钥；重新连接必须使用新的配对码。

Android 13 及以上版本首次启动时会请求通知权限。

## ColorOS 15 状态栏图标兼容

该实现已在 OnePlus PKX110、ColorOS 15.0.2 / Android 15 上实机验证。

ColorOS 会在应用声明 `<application android:icon="…">` 时，把通知的动态 `smallIcon` 强制替换成应用图标。为保留六种状态图形，本项目有意采用以下结构：

- `<application>` 不设置 `android:icon` 或 `android:roundIcon`，使运行时 `ApplicationInfo.icon` 保持为 `0`；
- 启动图标仅声明在 `activity-alias .LauncherAlias` 上，因此桌面入口仍然正常显示；
- 通知继续使用 Android 标准 `Notification.smallIcon`，不依赖 root、私有 OPlus API 或私有通知 extras。

请勿把启动图标重新加回 `<application>`，否则 ColorOS 可能再次把所有状态栏图形固定成 Pet 应用图标。其他标准 Android 系统也能正常使用这种 launcher alias 结构。

## 构建与校验

在仓库根目录运行：

```bash
./Android/build.sh
```

脚本会依次执行 JVM 单元测试、Android Lint 和 Debug APK 构建，正式输出为：

```text
Android/Discipline-local-preview.apk
```

当前包使用本机 Debug 签名，不是 Play 商店发布包。版本为 `1.1-sync-preview`（versionCode 3）。

## USB 覆盖安装

在手机上启用开发者选项和 USB 调试，连接 Mac 并接受 RSA 授权，然后运行：

```bash
./Android/install.sh
```

脚本使用 `adb install -r` 覆盖安装并保留现有应用数据与通知权限。也可以把 `Discipline-local-preview.apk` 复制到手机后手动打开安装；届时可能需要允许文件管理器安装未知应用。

## 本检查点验收清单

1. 覆盖安装并启动后，未配对设备只显示 `Pairing code` 输入框和 `Connect` 按钮。
2. 升级前本地预览遗留的状态通知应自动消失；尚未配对时不会发布虚假状态。
3. 空配对码时 `Connect` 不可点击；无效或过期的配对码会在输入框下方显示错误，不会保存任何配置。
4. 不要使用手工拼写的配对码；下一检查点由 Mac 通过已部署中继生成五分钟有效的真实配对码。
5. 覆盖安装仍保留 ColorOS 的 launcher alias 结构；状态栏动态图标兼容逻辑没有改变。

协议单元测试包含 Mac 格式配对码、X25519/HKDF 固定向量、AES-GCM 解密及篡改拒绝、Ed25519 离线签名及重放拒绝。`Android/build.sh` 会在每次打包时运行这些测试和 Android Lint。

配对成功后才会出现完整状态面板、`Notification Settings`、本地预览控制以及可确认的 `Unpair` 操作。
