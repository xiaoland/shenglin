# 产品联动验证

2026-09-26，在 macOS 15.4.1 与 iPadOS 27.0 真机上使用普通开发签名测试。Mac `swift test` 的两项测试、Release 构建与 Apple Development 签名通过；iPad 工程签名构建并安装成功。以下音量均为系统 `Audio/Video` 分类的实际读数，单位为千分比；Mac 收到的是 iPad 按配对密钥签名的应用执行回执，不只是蓝牙写入确认。

| 场景 | 观察 |
| --- | --- |
| 当前 Mac 语音会话作为输入，旧“所有输入”诊断 | iPad 338‰→0‰；Mac 停止客户端发送恢复后 0‰→338‰。开始和结束均收到应用回执。 |
| 排除既有语音会话后，Koe 两次开始/停止录音 | 两次均依次为 `applied 0‰`、`restored 338‰`，Mac 活动输入数 0→1→0，iPad 执行日志与回执一致。用户另在 iPad 休眠/锁屏播放音乐时亲自确认 Koe 录音开始降低、结束恢复。 |
| iPad 降音量时强制结束 Mac 客户端 | 重新连接时 iPad 对恢复指令返回 `alreadyRestored 338‰`，表明断开订阅后已自行恢复。 |
| 正式的应用选择模式 | Koe 为唯一已选应用时，Mac 当前语音聊天输入仍活动，判定 `active=false`，iPad 保持 338‰。运行中暂时选中聊天 App，立即 `applied 0‰`；移除后立即 `restored 338‰`。配置随后核对为仅 Koe。 |
| Mac 稳定签名 Release，配对密钥只在启动读取 | 读取后正常连接并收到 `alreadyRestored 338‰` 回执；命令序号已移至普通偏好，状态变化不再访问密钥链。 |

菜单栏版本新增了独立 `local.nearbyaudio.mac` 应用身份、图标和签名。`dist/Nearby Audio.app` 的 Xcode Release 构建与 `codesign --verify --strict --deep` 通过，Spotlight 将其识别为应用程序，Finder 的 `open` 可启动菜单栏进程。SwiftPM 的两项测试通过；新协议与更新后的 iPad App 已由签名 CLI 实测连接和应用回执。两个控制进程同时运行时，第二个会因共享运行锁退出。

后续已检查菜单栏弹窗：Mac 以稳定签名读到原有 Keychain 密钥，状态为 iPad 已连接，Koe 是唯一选中来源，登录自启关闭；调节目标音量得到 iPad 签名回执。旧版双方核对六位码的真机尝试中，Mac 曾在握手后报告已配对，但 iPad 配对栏显示“未配对”，另一状态栏显示“Mac 已连接”。因此不能把旧版握手视作通过；新版验收需同时检查两端配对状态及新密钥的控制回执。

现行流程已改为 iPad 显示一次性六位码、Mac 输入一次。采用 BoringSSL SPAKE2 并对会话、设备名和双向消息做密钥确认。`swift test` 的五项测试通过，其中配对测试覆盖正确码、错码、身份修改、会话重放、超时和确认前不得取得控制密钥。Mac Release 与 iPad 签名构建通过，新 iPad 包已安装。尚未完成新版真机输入、错误码重试、超时、取消以及旧密钥替换的交互验收；构建和协议单元测试不能代替这些观察。

验证没有覆盖 iPad 被系统回收后自动重启、设备重启后首次解锁、长时间蓝牙中断或输出路由切换。旧可行性探针的原始方法和边界见 [feasibility.md](feasibility.md)。
