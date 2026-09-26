# Nearby Audio

Nearby Audio 是 Mac 菜单栏应用。选中的 Mac 应用开始录音时，它通过蓝牙请求 iPad 降低媒体音量；最后一个选中应用结束录音后恢复。两端都不采集或传输声音内容。

## 日常使用

在装有 Xcode 的 Mac 上运行一次 `scripts/build-mac-app.sh`，得到可双击的签名应用 `dist/Nearby Audio.app`。也可以在 Spotlight 搜索“Nearby Audio”。首次打开时允许蓝牙访问；如果 macOS 要求新应用访问已有配对密钥，只需按系统提示授权一次。菜单栏波形图标是主入口，无须打开终端；它在未配对、暂停、选中应用录音时显示不同状态。当前没有开启登录后自动启动，可在弹窗中自行打开。

首次配对时，在 iPad App 点按“开始 2 分钟配对”；iPad 会显示一次性 6 位验证码。在 Mac 菜单弹窗选择这台 iPad，再输入验证码并点按“验证并配对”。验证码最多尝试 3 次，超时或取消后需在 iPad 重新开启。更换 Mac 或 iPad 时，从菜单点按“更换配对”，并在 iPad 明确开启配对模式；旧密钥保留到新 Mac 用新密钥成功连接。iPad 工程在 `iPad/NearbyAudioPad.xcodeproj`，需先运行 `scripts/build-pake.sh ios`，再用自己的开发团队签名安装。Mac 弹窗可勾选正在运行的应用，或通过“添加应用…”选择 `.app`；选择按稳定 bundle ID 保存，进程重启后仍有效。目前这台 Mac 已选 Koe，程序本身没有预置应用名单。未选中的录音活动不影响 iPad；空选择集保持空闲。

弹窗显示 iPad 连接状态、当前已选录音进程数和上次音量操作。可随时暂停协同、调整录音时的目标媒体音量（0%～50%），或选择登录后自动启动。音量目标会与 iPad App 同步；录音中更改目标从下一次录音开始生效。“退出”会先发送恢复请求再关闭程序。iPad App 也保留“立即恢复音量”按钮。

## 行为与限制

Mac 用公开 Core Audio 接口每 250 毫秒观察各进程是否有活动输入流，不根据应用内“静音”状态或是否有人说话作判断。同一 `.app` 内的辅助进程可匹配外层应用。用户手动改动 iPad 音量或切换输出设备后，恢复步骤会保留新状态；如果调走后又调回程序设置的完全相同数值，现有检查无法辨别。

当前触发条件是“已选应用有活动输入流”。应用排除列表与按应用独立静音尚未进入此版本；未来若加入虚拟麦克风，仍需明确区分本产品控制的静音状态与其他应用内部的静音状态，不能从前者推断后者。

蓝牙命令带过期时间、递增序号和 HMAC；Mac 等待 iPad 签名的应用执行回执，而不把蓝牙写入确认当作音量已改变。配对使用固定版本的 [BoringSSL SPAKE2](https://github.com/google/boringssl/blob/main/include/openssl/curve25519.h)：六位码参与密码认证密钥交换，双方再以独立方向的证明确认同一密钥。验证码不在蓝牙上传输，也不存为长期控制密钥。它是 App 自身的配对流程，并非系统蓝牙配对认证。控制密钥留在两端 Keychain，新密钥在首次认证控制命令得到 iPad 回执后才取代旧密钥；非秘密的序号存本机偏好。Mac `.app` 使用稳定 Apple Development 签名，构建脚本可通过 `NEARBY_AUDIO_SIGN_IDENTITY` 指定证书。iPad 音量控制使用在目标设备上实测的私有 `AVSystemController` 媒体接口，系统更新后可能需要重新验证。

iPad 不用静音播放保活、不打开麦克风，也不伪造通话。蓝牙断线时尝试恢复并自动重连，但系统回收 App、用户强制退出、设备重启后第一次解锁和长时间断线不能保证无条件自动恢复。蓝牙可达也不等于同房间。只验证了媒体音量，没有验证铃声、通知或通话音量。真机证据和待验边界见 `docs/validation.md`，此前可行性实验见 `docs/feasibility.md`。

## 开发工具

先运行 `scripts/build-pake.sh macos`，再运行 `swift test`，可检查配对握手、命令认证、恢复规则和所选输入进程过滤。构建脚本从固定的 BoringSSL revision 下载源码，在 `local/` 编译静态库；源码和库不提交，许可证见 `third_party/BoringSSL-LICENSE.txt`。`scripts/build-mac-app.sh` 会自动完成 Mac 端依赖构建。SwiftPM 的 `.build/release/nearby-audio` 是调试用 CLI，支持 `control status|pair start|pair choose <UUID>|pair code|pair cancel` 等本机控制命令，运行中的 GUI 通过用户私有 Unix socket 执行它们；`pair code` 从标准输入读取验证码，不从命令参数读取。CLI 还保留 `sources`、`select list|add|remove`、旧版密钥导入 `pair` 和 `run`。GUI 与独立运行的 CLI 共用选择配置和同一运行锁，不能同时控制蓝牙。日常使用请打开 `.app`。仓库不包含配对密钥、设备标识、开发证书或本机日志。

代码入口：`MacGUI/AppModel.swift` 持有菜单栏状态、配对切换和本机控制命令；`Mac/InputActivity.swift` 只报告已选应用的活动输入，`Mac/BLEClient.swift` 负责发送当前期望状态并等待认证回执。`iPad/BLEServer.swift` 校验命令、管理配对激活，`iPad/Volume.swift` 保存及恢复媒体音量。两端共用 `Shared/Protocol.swift` 中的 BLE 标识、命令认证和音量规则，以及 `Shared/PairingProtocol.swift` 中的 SPAKE2 握手。修改 BLE 标识或签名字段会改变设备间协议，需同时验证两个 App 工程。
