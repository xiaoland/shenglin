# 声邻

声邻是 Mac 应用，也提供菜单栏快捷入口。未排除的 Mac 应用开始录音时，它通过蓝牙或已认证的 Wi-Fi 链路请求已配对设备降低媒体音量；Mac 本机录音也可降低本机默认输出设备的音量。最后一个安静请求结束后恢复。链路只传控制状态。启用可选的 Mac 虚拟麦克风后，受系统监管的本机后台进程转发物理麦克风样本，并为诊断在本机滚动保存音频；不会自动上传或向 iPad 传输声音。

图标的可编辑矢量稿在 `Design/`：`AppIcon.svg` 用于 Mac，`AppIcon-iPad.svg` 为 iPad 的方形底图；`Mark-White.svg` 和 `Mark-Monochrome.svg` 提供透明背景标记。菜单栏使用独立的单色 `MenuBarIcon.svg`，缩小后不依赖波形细节辨认，暂停、断连和异常状态仍分别显示状态符号。

## 日常使用

在装有 Xcode 的 Mac 上运行一次 `scripts/build-mac-app.sh`，得到签名应用 `dist/Shenglin.app`。将它复制到 `/Applications/Shenglin.app` 后打开；应用显示名仍为“声邻”。应用包的磁盘文件名保持 `Shenglin.app`，以便 macOS 正确注册随包附带的后台麦克风服务。也可以在 Spotlight 搜索“声邻”。首次打开时允许蓝牙访问；使用 Wi-Fi 协同时，如系统询问局域网访问，也需要允许。从 Dock 或 Spotlight 打开应用会显示主窗口；菜单栏弹窗也可查看连接和录音状态、暂停协同、静音专用设备或保留现场。主窗口左下角可打开“设置…”或“诊断…”；也可按 ⌘, 打开标准设置窗口，在设备、应用、协同三个分区中配置配对、排除列表、麦克风上游、快捷键与音量。登录后自动启动默认关闭，可在“协同”中设置。

这版使用新的 peer 配对格式；旧开发版的配对不会被读取，Mac 与 iPad 都更新后须重新配对。

iPad App 的“本机”可设置设备名称，留空或超过 32 个字符不会保存；Mac 在认证连接后会读取并显示已配对 iPad 的新名称，无需重新配对。首次配对时，在 iPad App 点按“开始 2 分钟配对”；iPad 会显示一次性 6 位验证码。在 Mac“设置”→“设备”点“添加设备…”，从蓝牙与局域网合并的发现列表中选择这台设备，再输入验证码并点按“验证并配对”。验证码最多尝试 3 次，超时或取消后需在 iPad 重新开启。iPad 可先后配对多台 Mac，添加新 Mac 不撤销原有密钥；Mac 可同时连接多台 iPad；新增设备经新密钥确认后加入现有设备列表，已配对设备继续各自维持连接、空间条件和音量目标。两台 Mac 需要直接协同时，在一台点按“显示本机配对码”，另一台点按“添加设备…”并从局域网发现列表选择它、输入验证码，建立两者自己的密钥与 Wi-Fi 链路。iPad 工程在 `iPad/ShenglinPad.xcodeproj`，需先运行 `scripts/build-pake.sh ios`，再用自己的开发团队签名安装。Mac 默认让所有活动录音应用参与协同；在“设置”→“应用”的“排除应用”中打开开关，或用“添加排除…”选择 `.app`，即可让该应用录音时不影响已配对端。排除项按 bundle ID 保存，应用重启后仍有效。旧版 `selection.json` 的已选应用不会被误当成排除项。

菜单栏弹窗显示 iPad/Mac 连接状态、当前参与协同的录音进程数和上次音量操作，可随时暂停协同或静音专用设备。主窗口和菜单栏弹窗的“自动协同”下方都有“本机协同”开关及输出音量上限；“设置”→“协同”仍管理其他设备的目标音量（0%～50%）和登录启动。Mac 本机录音降音量默认开启，音量上限为 25%；它改变默认输出设备的整体音量，通话声音也会一起变小。远端设备请求与本机录音重叠时采用较低的目标值，并在两种请求都结束后恢复；期间若你手动调音量或切换输出设备，声邻保留你的选择。已降低的音量不会在仍有请求时自动调高。iPad 音量目标会与 iPad App 同步；录音中更改目标从下一次录音开始生效。“退出”会先发送恢复请求再关闭程序。iPad App 也保留“立即恢复音量”按钮。

专用麦克风需要单独构建、签名并安装 HAL 驱动；普通 `build-mac-app.sh` 不会安装它。“设置”→“应用”中的“安装驱动…”会安装应用内已签名的驱动，并按 macOS 要求请求管理员认证、重启音频服务。在“设置”→“应用”的“专用麦克风”中点“添加应用…”，选择应用及其物理上游输入，仅为需要独立控制输入的应用创建设备，例如 **声邻· Koe**。每台虚拟设备在创建时采用所选上游的采样率与声道数；更换上游时应先结束该设备的录音，若格式变化，设备会重建，目标应用可能需要重新选择输入。然后在该应用的音频设置中选择这个设备；系统默认输入可继续使用物理麦克风。首次使用时允许 声邻访问麦克风；如果拒绝，菜单会显示原因，需在系统的麦克风隐私设置中重新允许。打开 声邻后，系统会注册后台麦克风服务；关闭或退出 GUI 不会中断专用设备的声音，后台进程异常退出时由 macOS 重启。设备按需创建，应用重启和取消静音都不会删除它；停止使用后可点“移除”。其他应用继续使用原有输入，不会自动生成虚拟设备。

声邻中的静音开关控制整台专用设备，并让仅使用已静音设备的进程停止触发音量协同。每台专用设备还可在“设置”→“应用”中录入一个全局快捷键，用至少两个 ⌃、⌥、⌘ 修饰键配合字母或数字，按 Esc 取消录入；快捷键切换该设备现有的静音状态，仅在关闭“让前台应用也响应同一快捷键”时成功切换后播放系统 `Ping` 提示音，重启后保留，移除设备时清除。组合若无法注册，设置窗口会提示换一个；对已知的 macOS 窗口快捷键，设置窗口会显示冲突警告。默认使用非独占 Carbon 热键：其他全局热键注册者可共享组合，但应用内快捷键可能收不到原始按键；Codex App 的 ⌃⌘M 已实测只有 声邻响应。设置窗口可显式开启“让前台应用也响应同一快捷键”：声邻先注销 Carbon 热键，再申请 macOS“输入监控”授权并使用只读事件监听，不阻断前台按键；关闭后销毁监听并恢复 Carbon。此监听由系统交付所有按键按下事件，声邻仅对已配置组合切换静音、忽略自动重复且不记录其他按键。授权未完成时 声邻快捷键暂不可用，可在系统设置授权后点“重新检查授权”；用户已在签名版手动确认：启用共享模式后按已配置组合，声邻与 Codex App 均响应；长期稳定性仍需观察。不要让两个需独立控制的应用共用同一台专用设备；其他应用若选了同一设备，也会一起静音。每台设备的静音与样本缓冲独立，排除项仍只控制音量协同。如果物理供源断开、样本过期或后台服务尚未恢复，设备将归零；音频服务重启后的设备默认静音，等待 声邻恢复状态。最多配置 32 台专用设备，未添加应用时不发布输入设备。

诊断功能自动把每台专用设备送入 HAL 前的 Float32 音频、HAL 实际返回给客户端的 Float32 音频、事件及每 5 秒的采集和驱动性能计数保存在本机，按时间和进程标识记录。音频与事件按分钟分段，默认总容量上限为 40 GB；仅当诊断目录超过设置的上限时，从最旧证据开始淘汰。设备菜单可手动标记现场时间；持续取证不依赖标记，标记也不免除容量淘汰。独立的“诊断”窗口显示覆盖时长、丢块和写盘错误，可选择外置存储目录、设置容量上限并导出 ZIP。外置诊断盘断开或目录换盘时会停止写入并显示错误；重新接入后请重新选择取证目录。音频可能包含私人谈话，不会自动上传；分享诊断包前请自行检查内容。上游记录来自 AVAudioEngine 格式转换之后，并非 USB 原始数据。

导出后可用 `python3 scripts/audio-forensics.py <设备目录>/rolling --stream hal-output` 查看各客户端 PID 的帧数与时间戳；指定 `--pid <PID> --wav /tmp/hal.wav` 可提取某客户端的音频。将 `--stream upstream` 用于同目录的上游记录；`rolling/*-events.jsonl` 包含事件和性能快照。两路 hostTime 使用同一 Mach 时钟，换算系数见 `manifest.json`；各自的 sampleTime 属于不同音频时钟，不能直接相减。WAV 按收到的块顺序拼接，不能从拼接后的 WAV 推断真实停顿长度。

## 行为与限制

Mac 用公开 Core Audio 接口每 250 毫秒观察各进程是否有活动输入流，不根据应用内“静音”状态或是否有人说话作判断。同一 `.app` 内的辅助进程可匹配外层应用。排除应用只阻止向其他设备发出安静请求；它在 Mac 本机录音时仍会触发本机降音量。用户手动改动 iPad 音量或切换输出设备后，恢复步骤会保留新状态；如果调走后又调回程序设置的完全相同数值，现有检查无法辨别。

如果 Core Audio 或排除配置暂时无法读取，Mac 会显示输入状态不可用并停止降音量请求；恢复读取后自动按实际输入状态继续。故障期间正在录音的应用可能使远端恢复正常音量。菜单栏的绿色连接状态表示已收到 iPad 认证回执或已有完成双向认证的 Mac 直连；蓝牙订阅成功但尚未得到回执时显示为等待确认。

当前触发条件是“未排除的应用有活动输入流”；通过本产品静音的虚拟麦克风客户端不触发降音量。直接使用其他输入设备的应用不受本产品静音开关影响，但仍可参与 iPad 音量协同。应用内部的静音状态不会由本产品推断或控制。

蓝牙 peer 状态带有效期、递增版本和 HMAC；Mac 等待 iPad 签名的应用执行回执，而不把蓝牙写入确认当作音量已改变。配对使用固定版本的 [BoringSSL SPAKE2](https://github.com/google/boringssl/blob/main/include/openssl/curve25519.h)：六位码参与密码认证密钥交换，双方再以独立方向的证明确认同一密钥。验证码不存为长期控制密钥。它是 App 自身的配对流程，并非系统蓝牙配对认证。控制密钥留在各端 Keychain；iPad 仅在收到新密钥认证的控制状态时添加该 Mac，Mac 验证该状态的 iPad 回执后才将其加入设备列表。Mac↔Mac 双方在新的 Wi-Fi 认证链路建立后才正式保存配对。Mac↔Mac 配对在局域网传输握手消息，验证码本身不发送。非秘密的序号存本机偏好。iPad 音量控制使用在目标设备上实测的私有 `AVSystemController` 媒体接口，系统更新后可能需要重新验证。

iPad 不用静音播放保活、不打开麦克风，也不伪造通话。蓝牙断线时尝试恢复并自动重连，但系统回收 App、用户强制退出、设备重启后第一次解锁和长时间断线不能保证无条件自动恢复。蓝牙可达也不等于同房间。Mac↔Mac 当前只有 Wi-Fi 认证证据，因此空间条件选“蓝牙且 Wi-Fi”时两台 Mac 不互相降音量。只验证了媒体音量，没有验证铃声、通知或通话音量。真机证据和待验边界见 `docs/validation.md`，此前可行性实验见 `docs/feasibility.md`。多端剩余验收见[任务包](tasks/multi-device-volume/packet.md)。

## 开发工具

在 Apple Silicon Mac 上用 Xcode、命令行工具和 CMake 开发；缺少 CMake 时，`build-pake.sh` 会在忽略版本控制的 `local/` 中通过 Python/pip 安装。脚本从固定的 BoringSSL revision 下载源码，版本变更时重建 Mac 与 iPad 静态库；源码、产物及本机签名信息不提交，许可证见 `third_party/BoringSSL-LICENSE.txt`。项目面向 arm64 Mac 与 iPad 真机；未验证 Intel Mac 或模拟器。当前构建验证使用 Xcode 26.2。

```sh
scripts/build-pake.sh both
swift test
swift build -c release  # 仅构建调试用 CLI，不生成菜单栏 .app
xcodebuild -project MacGUI/ShenglinMac.xcodeproj -scheme ShenglinMac -configuration Release -sdk macosx -destination 'generic/platform=macOS' -derivedDataPath local/MacDerived CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPad/ShenglinPad.xcodeproj -scheme ShenglinPad -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath local/iPadDerived CODE_SIGNING_ALLOWED=NO build
scripts/build-driver.sh  # 构建并离线测试虚拟麦克风驱动，默认不签名、不安装
```

需要可运行的 Mac 应用时，确保本机已有 Apple Development 证书，再从主仓库运行 `scripts/build-mac-app.sh`；脚本默认使用该签名身份，也可设置 `SHENGLIN_SIGN_IDENTITY` 指定证书。脚本先签名并验证暂存 App，确认 GUI 已退出后停止旧后台服务，再替换 `dist/` 中的旧构建；重新打开 GUI 会注册新版服务。开发时运行 `scripts/run-mac-app.sh` 会在后台打开主仓库的签名包，不抢占正在使用的窗口，并检查是否已有其他路径的 声邻GUI。不要从工作树的 Xcode 构建目录启动第二份 App。iPad 工程只有 Debug 配置：先构建 iOS BoringSSL，然后在 Xcode 中选择自己的开发团队与 iPad 真机，签名并安装。无签名构建仅验证编译，不安装或替换设备上的应用。安装新构建后需另外验证蓝牙连接、配对状态及音量回执。

虚拟麦克风驱动位于 `Driver/`，基于固定版本的 [libASPL](https://github.com/gavv/libASPL/tree/v3.1.2)；`scripts/build-driver.sh` 将依赖放在忽略版本控制的 `local/`，生成 `local/DriverBuild/ShenglinDriver.driver`，许可证见 `third_party/libASPL-LICENSE.txt` 及相邻的 Apple 示例许可证。设置 `SHENGLIN_SIGN_IDENTITY` 可在构建后用指定身份签名并验证驱动；安装仍需管理员把驱动放入 `/Library/Audio/Plug-Ins/HAL`，随后重启音频服务或 Mac。构建脚本不执行安装。专用设备列表由 HAL 存储，应用选择按 bundle ID 存在 `microphones.json`；旧版 `muted.json` 不会自动批量创建设备。两次 120 秒真实 USB 输入到虚拟设备的双客户端闭环已通过，长时通话、拔插和睡眠唤醒仍待验证，详见[验收记录](docs/validation.md)。

先退出 声邻GUI，再用 `python3 scripts/test-driver-isolation.py` 检验已安装驱动。它临时添加两台专用设备和两个不同 bundle ID 的测试 App，验证各设备独立静音、恢复和断源归零，再恢复原设备列表。脚本只供给合成音频，不安装驱动或改变默认输入；不要与运行中的 声邻同时修改设备列表。签名身份读取 `SHENGLIN_SIGN_IDENTITY`，未设置时使用临时签名，统计在 `local/HALIsolationTests/results.json`。旧单设备隔离失败的复现快照保留在本地 Apple 支持附件中，不是当前产品路线。


SwiftPM 的 `.build/release/shenglin` 支持 `control status|pair start|pair choose <UUID>|pair code|pair cancel` 等本机诊断命令；运行中的 GUI 通过同一用户的 Unix socket 执行它们。`pair code` 从标准输入读取验证码，不从命令参数读取。CLI 还保留 `sources`、`exclude list|add|remove`、`mute list|add|remove`。CLI 与 GUI 共用排除及静音配置；蓝牙控制由 GUI 统一持有。`control microphone add|remove <bundle ID>` 可添加或移除专用设备，`control mute add|remove <bundle ID>` 控制已分配设备。`control status` 按已配对设备返回各自链路、空间条件及目标音量，并返回应用设置、活动进程数、最后一次认证回执及错误；`control target <设备 ID> <0...0.5>` 只更改指定 iPad 的目标音量；超时或连接失败先检查菜单栏 App 是否运行。分享诊断输出前应删去设备名、UUID 和应用列表。仓库不包含配对密钥、设备标识、开发证书或本机日志；不要用会输出 Keychain 密钥内容的命令排障。

代码入口：`MacGUI/AppModel.swift` 持有菜单栏状态、各 peer 会话和本机控制命令；`Mac/MicrophoneAgent.swift` 在独立的 launchd 进程中持有专用设备的采集与驱动写入；`Mac/MacPairing.swift` 管理 Mac 直连配对；`Mac/InputActivity.swift` 报告未排除、未由虚拟麦克风静音的活动输入，`Mac/VirtualMicrophone.swift` 按需采集物理输入并供给 `Driver/Driver.cpp`，`Mac/BLEClient.swift` 负责 BLE 双向状态及回执，`Mac/OutputVolume.swift` 控制本机默认输出音量。`iPad/BLEServer.swift` 校验状态、管理配对激活，`iPad/Volume.swift` 保存及恢复媒体音量。各端共用 `Shared/Protocol.swift` 的 BLE 标识与认证工具、`Shared/PeerState.swift` 的来源租约和空间规则、`Shared/WiFiPeer.swift` 的 Bonjour/TCP 认证通信，以及 `Shared/PairingProtocol.swift` 的 SPAKE2 握手。iPad 目前没有可靠的其他 App 录音检测，因此尚不能从 iPad 真实录音反向触发 Mac 音量变化；Wi-Fi 及三端全连接也未完成真机验证，详见[多设备任务包](tasks/multi-device-volume/packet.md)。修改 BLE 标识或签名字段会改变设备间协议，需同时验证两个 App 工程。

## 许可证

项目代码以 [MIT 许可证](LICENSE)发布。BoringSSL 与 libASPL 的第三方许可证分别保留在 `third_party/` 中；构建产物也会附带适用的许可证文本。
