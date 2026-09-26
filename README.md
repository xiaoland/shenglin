# Nearby Audio

Nearby Audio 是 Mac 菜单栏应用。未排除的 Mac 应用开始录音时，它通过蓝牙请求 iPad 降低媒体音量；最后一个参与协同的应用结束录音后恢复。当前版本不采集或传输声音内容。

## 日常使用

在装有 Xcode 的 Mac 上运行一次 `scripts/build-mac-app.sh`，得到可双击的签名应用 `dist/Nearby Audio.app`。也可以在 Spotlight 搜索“Nearby Audio”。首次打开时允许蓝牙访问；如果 macOS 要求新应用访问已有配对密钥，只需按系统提示授权一次。菜单栏波形图标是主入口，无须打开终端；它在未配对、暂停、选中应用录音时显示不同状态。当前没有开启登录后自动启动，可在弹窗中自行打开。

首次配对时，在 iPad App 点按“开始 2 分钟配对”；iPad 会显示一次性 6 位验证码。在 Mac 菜单弹窗选择这台 iPad，再输入验证码并点按“验证并配对”。验证码最多尝试 3 次，超时或取消后需在 iPad 重新开启。更换 Mac 或 iPad 时，从菜单点按“更换配对”，并在 iPad 明确开启配对模式；旧密钥保留到新 Mac 用新密钥成功连接。iPad 工程在 `iPad/NearbyAudioPad.xcodeproj`，需先运行 `scripts/build-pake.sh ios`，再用自己的开发团队签名安装。Mac 弹窗默认让所有活动录音应用参与协同；在“排除应用”中打开开关，或用“添加排除…”选择 `.app`，即可让该应用录音时不影响 iPad。排除项按 bundle ID 保存，应用重启后仍有效。旧版 `selection.json` 的已选应用不会被误当成排除项。

弹窗显示 iPad 连接状态、当前参与协同的录音进程数和上次音量操作。可随时暂停协同、调整录音时的目标媒体音量（0%～50%），或选择登录后自动启动。音量目标会与 iPad App 同步；录音中更改目标从下一次录音开始生效。“退出”会先发送恢复请求再关闭程序。iPad App 也保留“立即恢复音量”按钮。

## 行为与限制

Mac 用公开 Core Audio 接口每 250 毫秒观察各进程是否有活动输入流，不根据应用内“静音”状态或是否有人说话作判断。同一 `.app` 内的辅助进程可匹配外层应用。用户手动改动 iPad 音量或切换输出设备后，恢复步骤会保留新状态；如果调走后又调回程序设置的完全相同数值，现有检查无法辨别。

如果 Core Audio 或排除配置暂时无法读取，Mac 会显示输入状态不可用并停止降音量请求；恢复读取后自动按实际输入状态继续。故障期间正在录音的应用可能使 iPad 恢复正常音量。菜单栏的绿色连接状态以收到 iPad 认证的控制回执为准，蓝牙订阅成功但尚未得到回执时显示为等待确认。

当前触发条件是“未排除的应用有活动输入流”。按应用独立静音尚未进入此版本；未来的虚拟麦克风仍需明确区分本产品控制的静音状态与其他应用内部的静音状态，不能从前者推断后者。

蓝牙命令带过期时间、递增序号和 HMAC；Mac 等待 iPad 签名的应用执行回执，而不把蓝牙写入确认当作音量已改变。配对使用固定版本的 [BoringSSL SPAKE2](https://github.com/google/boringssl/blob/main/include/openssl/curve25519.h)：六位码参与密码认证密钥交换，双方再以独立方向的证明确认同一密钥。验证码不在蓝牙上传输，也不存为长期控制密钥。它是 App 自身的配对流程，并非系统蓝牙配对认证。控制密钥留在两端 Keychain；iPad 收到新密钥认证的控制命令时替换旧密钥，Mac 验证该命令的 iPad 回执后才替换。非秘密的序号存本机偏好。iPad 音量控制使用在目标设备上实测的私有 `AVSystemController` 媒体接口，系统更新后可能需要重新验证。

iPad 不用静音播放保活、不打开麦克风，也不伪造通话。蓝牙断线时尝试恢复并自动重连，但系统回收 App、用户强制退出、设备重启后第一次解锁和长时间断线不能保证无条件自动恢复。蓝牙可达也不等于同房间。只验证了媒体音量，没有验证铃声、通知或通话音量。真机证据和待验边界见 `docs/validation.md`，此前可行性实验见 `docs/feasibility.md`。

## 开发工具

在 Apple Silicon Mac 上用 Xcode、命令行工具和 CMake 开发；缺少 CMake 时，`build-pake.sh` 会在忽略版本控制的 `local/` 中通过 Python/pip 安装。脚本从固定的 BoringSSL revision 下载源码，版本变更时重建 Mac 与 iPad 静态库；源码、产物及本机签名信息不提交，许可证见 `third_party/BoringSSL-LICENSE.txt`。项目面向 arm64 Mac 与 iPad 真机；未验证 Intel Mac 或模拟器。当前构建验证使用 Xcode 26.2。

```sh
scripts/build-pake.sh both
swift test
swift build -c release  # 仅构建调试用 CLI，不生成菜单栏 .app
xcodebuild -project MacGUI/NearbyAudioMac.xcodeproj -scheme NearbyAudioMac -configuration Release -sdk macosx -destination 'generic/platform=macOS' -derivedDataPath local/MacDerived CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPad/NearbyAudioPad.xcodeproj -scheme NearbyAudioPad -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath local/iPadDerived CODE_SIGNING_ALLOWED=NO build
```

需要可运行的 Mac 应用时，确保本机已有 Apple Development 证书，再运行 `scripts/build-mac-app.sh`；脚本默认使用该签名身份，也可设置 `NEARBY_AUDIO_SIGN_IDENTITY` 指定证书。脚本先签名并验证暂存 App，成功后才替换 `dist/` 中的旧构建。iPad 工程只有 Debug 配置：先构建 iOS BoringSSL，然后在 Xcode 中选择自己的开发团队与 iPad 真机，签名并安装。无签名构建仅验证编译，不安装或替换设备上的应用。安装新构建后需另外验证蓝牙连接、配对状态及音量回执。

SwiftPM 的 `.build/release/nearby-audio` 支持 `control status|pair start|pair choose <UUID>|pair code|pair cancel` 等本机诊断命令；运行中的 GUI 通过同一用户的 Unix socket 执行它们。`pair code` 从标准输入读取验证码，不从命令参数读取。CLI 还保留 `sources`、`exclude list|add|remove`、旧版密钥导入 `pair` 和独立 `run`。GUI 与独立运行的 CLI 共用排除配置和运行锁，不能同时控制蓝牙。`control status` 返回连接状态、排除项、活动进程数、最后一次认证回执及错误；超时或连接失败先检查菜单栏 App 是否运行。分享诊断输出前应删去设备名、UUID 和应用列表。仓库不包含配对密钥、设备标识、开发证书或本机日志；不要用会输出 Keychain 密钥内容的命令排障。

代码入口：`MacGUI/AppModel.swift` 持有菜单栏状态、配对切换和本机控制命令；`Mac/InputActivity.swift` 报告未排除应用的活动输入，`Mac/BLEClient.swift` 负责发送当前期望状态并等待认证回执。`iPad/BLEServer.swift` 校验命令、管理配对激活，`iPad/Volume.swift` 保存及恢复媒体音量。两端共用 `Shared/Protocol.swift` 中的 BLE 标识、命令认证和音量规则，以及 `Shared/PairingProtocol.swift` 中的 SPAKE2 握手。修改 BLE 标识或签名字段会改变设备间协议，需同时验证两个 App 工程。
