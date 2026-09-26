# iPad 音频控制：真机可行性实验

> 本文记录工程建立前的可行性实验及当时的结论。当前产品实现与使用方式以仓库根目录的 README 为准。

更新于 2026-09-26。最新范围允许 AVAudioSession 协调/duckOthers；不把录音状态同步等同于伪造电话，不采集 iPad 麦克风。本轮设备操作、普通开发签名安装与小幅音量变化均已获授权。最终连接不依赖 USB。

**已证实：普通开发签名 App 可在 iPadOS 27 改变系统媒体音量值；纯局域网前台控制成功。新实验中，Core Bluetooth 写入唤醒了已挂起的后台 App，并让它完成同样的音量降低与恢复。用户已接受蓝牙作为产品的无线控制/唤醒通道；纯局域网后台及时唤醒尚未证实。**

## 真机结果

| 实验 | 观察 | 能支持的结论 |
|---|---|---|
| 私有符号探测 | MediaPlayer、MediaExperience、MediaRemote 都加载成功；`AVSystemController`、`MPVolumeController` 及媒体音量/静音函数存在。 | 不是只依赖旧 SDK 或旧网页判断。符号存在本身不证明 setter 有权限。 |
| 私有分类音量写入 | `Audio/Video` 原值 0.3375，写入 0.275 返回 true；回读 0.275；条件恢复 0.3375，返回和回读成功。 | 当前普通开发签名可调用这个分类 getter/setter，没有添加私有音量 entitlement。 |
| 系统控件对照 | 内嵌 Apple `MPVolumeView` 的滑块同步为 0.3375 → 0.275 → 0.3375。 | 有超过函数返回值的系统控件观察；仍不应扩大为“所有提醒、铃声、通话等声音域都静音”。 |
| 公开音量读数对照 | 未激活音频会话时，`AVAudioSession.outputVolume` 始终报 0.35。 | 本次实验不能用这个读数判断私有写入是否成功；未把读取会话当作激活/保活。 |
| USB 插着时局域网控制 | iPad UDP 监听强制 Wi-Fi，Mac 发送路由为 Ethernet，前台命令成功。 | 数据命令没有走 USB 隧道；此阶段尚不算完全脱线。 |
| 用户拔掉 USB 后 | 前台 ping 成功，约 199ms；无线 volume 命令完成上述降低与恢复，约 3.11 秒，包含 2 秒保持和 1 秒恢复观察。`devicectl` 也报告 `localNetwork`。 | 完全脱线的前台局域网控制已实测。 |
| 普通后台 | 切到“设置”后过渡态 ping 成功；约 30 秒后 5 秒超时；重新前台后数毫秒回复。 | 前台 Wi-Fi 成功不能外推到长期后台。 |
| 3 秒 duck | 外部音源由用户准备；`.playback + .duckOthers` 的激活成功，约 3 秒后停用成功。没有播放测试声音，没有采集麦克风。 | API 执行已测；真实外部音频是否变小及恢复仍待用户听感反馈，不能只凭 `setActive` 成功判定。 |
| 激活 duck 后进入后台 | 已声明 `UIBackgroundModes=audio`，没有实际音频 I/O。20 秒会话激活后切“设置”，第 8 秒、第 22 秒的 ping 均 5 秒超时。20 秒停用代码直到约 32 秒重新前台才运行。回到前台后确认会话已停用。 | 会话激活与后台 audio 声明不足以维持本实验的命令接收。App 内计时器也不能保证挂起后按时执行恢复。 |
| 普通锁屏 | 用户确认锁屏、USB已拔；设备报告 passcodeRequired=true；LAN ping 5秒超时。 | 当前普通监听不能在锁屏状态及时响应。 |
| 锁屏按需开发启动 | `launch --no-activate` 无线调用10秒超时，之后第0/8/25秒ping均5秒超时；测试后passcodeRequired仍true。 | 本次按需启动未唤醒监听，没有“锁屏开发连接控制成功”的证据。 |
| 锁屏新建调试连接 | LLDB `device select` 明确返回需要解锁，未进入attach。 | 当前冷建立调试连接需先解锁；解锁后经减少符号加载，已真实attach并continue，前台ping约6ms；已连接后解锁后台仍失联，见下项；没有继续索取锁屏操作。 |

| 无线 LLDB 附加后的后台 | 两轮均真实 attach 并明确 continue；前台 ping 成功。第二轮切设置后约 4 秒，独立 global utility 队列每秒心跳停止；后台两次 ping 超时，LLDB 仍显示 running。回前台心跳恢复，时间戳间隔 34.275 秒。 | 受影响的不只是 UDP 接收，应用执行也受限；此配置的普通 LLDB 附加不足以维持后台执行。running 不等于线程持续获得执行。 |
| 调试重连 | 正常 detach、更新 App 后，复用同一 LLDB 进程两次附加出现 handshake ack 失败；新建 LLDB 进程成功，但需等符号加载并明确 continue。 | 当前流程还不具备已验证的自动重连可靠性；不能外推为所有无线重连均失败。 |
| 蓝牙后台写入 | iPad 声明 `bluetooth-peripheral`，Mac 先连接自定义 GATT 特征。切“设置”后独立心跳停止 32.608 秒，同期纯 LAN ping 5 秒超时。Mac 写入 ping 后约 0.49 秒，iPad 日志记录 `state=2`（后台）收到命令，心跳恢复；随后后台收到 volume，分类回读及系统滑块观察值完成 0.3375 → 0.275 → 0.3375。未播放静音、未用麦克风。 | 这台设备上，蓝牙事件能唤醒挂起 App 并执行已验证的媒体音量写入与条件恢复。蓝牙链路的 GATT 写入 ACK 早于 App 处理日志，不能单独当作命令完成确认。 |
| Mac 蓝牙客户端重启 | Mac 中央设备进程退出，iPad 仍在后台。新 Mac 进程再次扫描、连接，后台第二次 ping 和 volume 均成功，音量再次恢复原值。 | 此次断开重连无需手动打开 iPad App；不证明 iPad 重启、用户强制退出或所有蓝牙断线情况都能恢复。 |
| 锁屏首次蓝牙命令 | 两次设备锁定状态查询均为 `passcodeRequired=true`。iPad 已切到后台且 LAN ping 超时、心跳停止。Mac 蓝牙 ping 写入 ACK 后，iPad `state=2` 回调确实收到 ping，独立心跳恢复。 | 在这台已于本次开机解锁过的 iPad 上，蓝牙可以唤醒锁屏且挂起的探针；单独的 GATT ACK 不足以支持此结论，关键证据是 iPad 回调日志。 |
| 锁屏音量与 Mac 重连 | 锁屏首轮 volume 回调后，私有分类回读与系统滑块观察值为 0.3375 → 0.275 → 0.3375，写入/恢复返回 true。Mac 客户端退出后，iPad 未解锁；新 Mac 进程再次发现、连接，第二轮 ping 和相同的短时音量操作均在 `state=2` 完成。末次锁定状态仍为 `passcodeRequired=true`。 | 锁屏第一条命令、音量执行与 Mac 进程重连均通过本次真机验证；这不覆盖 iPad 重启后首次解锁前或用户强制退出后的行为。 |
| 锁屏安装更新后的凭据与关闭 | 测试令牌改存 iPad Keychain，访问级别为本机首次解锁后可用。锁屏时更新自身 App，新版本进程通过旧令牌接收 `stop`；读取实验 App 自有偏好文件，`BLEProbeEnabled` 由 true 变为 false。随后终止探针进程。 | 本次进程替换后令牌可用，实验广播可通过认证命令关闭。安装更新不是系统因内存压力回收，不能据此声称已验证系统自动重启恢复。 |
| 解锁时开发命令按需启动 | 用户此前已解锁，iPad 显示“设置”；Mac 经无线 `devicectl launch --no-activate --terminate-existing` 启动探针，后台执行 `--test-volume` 并完成相同的写入与恢复。 | 开发通道在解锁状态下可按需执行；锁屏同命令此前超时，因此不能单独满足锁屏场景。 |

无线证据见 `实测记录.json`。这是工具实测记录，不包括用户听感、外部音源内容或声压测量；没有启动麦克风做声学采样。

## 当前最重要的设计判断

Mac 的录音开始/结束可以同步为应用自己的状态。iPad 收到开始后选择直接调系统媒体音量，或激活 `.duckOthers`；收到结束后解除影响。两种执行器都不必假冒 CallKit 电话。**但状态同步协议不赋予网络唤醒能力。** 当前纯 LAN 监听在 App 空闲挂起后收不到及时命令，持续录音时结束消息和租约计时器也可能延后。

新验证的蓝牙写入提供了另一种明确的唤醒事件：Mac 在录音状态变化时写入 iPad 的 GATT 特征，iPad 在回调中执行音量操作；结束时再写入恢复指令。它可在两机仍连着同一局域网的同时使用，但控制触发需要蓝牙开启和可达，不能称为“纯 LAN”方案。探针只验证了短时 ping、音量降低及立即恢复；还没有实现长时间录音的状态对账、用户手动改音量后的恢复规则、应用层完成确认或超时后安全恢复。下一轮已把测试令牌存入 iPad Keychain，供进程重启后读取；Mac 仍从开发控制台取令牌，产品还需真正的配对与令牌更新机制。

Apple 说明 duck 在会话激活时开始、停用时结束，并建议只用于数秒。它是压低其他音频会话，未保证让所有设备声音完全安静；停用通知也不是“强制任意 App 恢复播放”的命令。20 秒测试只用于观察后台行为，不作为长时间录音的可靠方案。[duckOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/duckothers)、[notifyOthersOnDeactivation](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactiveoptions/notifyothersondeactivation)。

短时私有音量实验只在分类回读仍等于本次测试值时恢复已知原值。这不等于完成产品级用户意图处理：用户调节后又回到同一数值、路由切换、重连、进程退出等情形仍需设计。不能简单按“减 N 次再加 N 次”恢复。

## Mac 录音活动检测

本机 macOS 15.4.1 上，公开 Core Audio HAL 可列出已连接的音频进程，并读取每个进程的 `kAudioProcessPropertyIsRunningInput`。Apple 将它定义为“该进程正在运行音频 I/O，且至少有一个活动输入流”。这提供跨应用的**输入活动**信号，不需要观察器自己打开麦克风，也不提供音频样本、文字内容或“正在语音输入”的语义判断。[进程输入状态](https://developer.apple.com/documentation/coreaudio/audiohardwareprocess/isrunninginput)、[系统音频进程列表](https://developer.apple.com/documentation/coreaudio/audiohardwaresystem/processes)。

已编译并运行同目录的只读 `MacInputActivityProbe.swift`；验证脚本以每 250 毫秒读取一次进程状态。当前语音会话已占用一个输入进程，KOE 1.0.17 进程虽存在但初始未运行输入。用户正常使用 KOE 说话时，活动输入进程从 1 个变为 2 个，KOE 对应进程状态变为活动；约 3.394 秒后回到 1 个，KOE 结束。默认输入设备的 `DeviceIsRunningSomewhere` 全程为 1。没有读取声音、转写历史或其他私人内容，也没有由探针请求麦克风权限。

因此只看设备是否运行、麦克风权限或系统橙点，不能在已有语音会话占用输入时检测第二个应用的开始/结束；要比较**活动输入进程集合**。最小系统级策略可把集合非空视为“Mac 有输入采集活动”，集合变化用于并发对账，持续非空时不重复降低 iPad 音量，直到最后一个输入进程结束才考虑恢复。此策略也会覆盖会议、录音等非语音输入 App；如果产品要只针对语音转写，就必须增加用户选择的应用范围或该类应用提供的专用状态信号。HAL 输入流活动不保证用户正在说话，也未验证虚拟音频设备、进程异常退出及长时间运行时的所有变化。

## 开发通道与系统后台机制

Mac 开发通道曾是绕开 iPad App 常驻的候选。当前 pymobiledevice3 的源码能通过 `com.apple.coredevice.hid.indigo` 发系统音量键，但本机现有 DDI 没有暴露该服务；实际 volume-down 请求失败，未改变音量。`--native` 工具在此 Mac 上异常退出，用户态 RemoteXPC 通道成功，但也没有 HID 服务。开发镜像兼容且可用，不等于具备新源码用到的所有服务。[HID 实现](https://github.com/doronz88/pymobiledevice3/blob/480b8a3eccec31ac41c1bf80b479d1d0cdb9ba00/pymobiledevice3/remote/core_device/hid_service.py)。

拔线后的 Apple `devicectl` 本身可以无线连接并更新我们的 App。锁屏时 `launch --no-activate` 超时；解锁状态下相同模式成功按需启动探针并运行音量测试。这给出一个“解锁时可用”的开发通道分支，但不满足锁屏第一条命令。无线 LLDB 真实附加后，App 后台心跳仍停止。对个人工具不能仅因开发工具依赖就判定不适合，仍需测首次连接、断线重连与日常手动频率；也不能把开发启动结果冒充普通 App 的 LAN 后台能力。

已核查的后台候选：

- **BGContinuedProcessingTask**：要求前台用户动作启动真实工作、报告进度，系统可终止；不是无限等待网络指令的许可。[Apple 任务契约](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)。
- **NEAppPushProvider**：可以在匹配局域网维持连接，但需要 Apple 审批 `app-push-provider` entitlement，官方用途是本地通知/通话消息。本次 profile 没有它，未申请，也未把它当作普通 App 的现成音量控制入口。[Local Push Connectivity](https://developer.apple.com/documentation/networkextension/local-push-connectivity)。
- **静音输出诊断**：本轮只测试了会话激活，没有循环静音播放、录音或伪造通话。用户允许静音输出最多作为限时实验，明确不接受它作为产品的后台保活手段。即使限时实验能维持接收，也不能据此判定日常方案可行。

候选按“第一条命令如何到达挂起 App”排序：

| 路径 | 首条命令、执行与恢复链条 | 当前判断 |
|---|---|---|
| Core Bluetooth 后台外设 | Mac 以写入请求唤醒 App；回调已实测可以调用媒体音量 setter。停止/恢复需要第二次写入及应用层确认，断线后必须重连并按 Mac 当前录音状态对账。 | **最强实测候选，蓝牙条件已获用户接受**；锁屏已验证，系统回收及重启后的恢复尚未真机验证。Apple 允许后台外设处理写入，并支持状态保存/恢复；用户强制退出、蓝牙电源关闭等有系统限制。[后台处理](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)、[重启规则](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)。 |
| 无线 `devicectl` 按需启动 | Mac 在录音变化时启动 App，App 自行读取 Mac 的当前状态再设置或恢复音量；Mac 端可重试并对账。 | 解锁真机成功、锁屏失败；只能作为条件可用的辅助路径。需要开发镜像、签名持续有效和可靠无线连接。 |
| LAN Local Push 扩展 | 扩展可按 Wi-Fi SSID 维持服务器连接；官方支持向用户发本地通知或报告真实来电，并要求获批 `app-push-provider` entitlement。 | 当前 profile 无此权限，尚无“收到消息后无提示地唤醒宿主并改音量”的官方链条；不把通知或假来电当作自动控制。[Apple 用途与权限](https://developer.apple.com/documentation/networkextension/local-push-connectivity)。 |
| APNs 后台推送/定时后台任务 | 系统择时唤醒，App 获有限执行时间。 | APNs 依赖外网且低优先级送达不保证；定时任务不响应 Mac 当下录音变化，不适合作为即时主链路。[Apple 后台策略](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)、[推送限制](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)。 |
| 真正音频路由工作 | 若未来产品确实采集或传输用户声音，可按真实音频会话生命周期运行；收到开始/结束命令的因果链仍需单独设计。 | 长期扩展方向，不能为了当前控制需求虚构音频流或采用静音输出保活。 |

## 新版接口与权限证据

本机编译工具是 Xcode/SDK 26.2，实际安装运行的设备为 iPadOS 27。还核查了 Apple 当前的 AVAudioSession、MediaPlayer、AudioToolbox、MediaAccessibility、AudioAccessoryKit、BackgroundTasks API 文档与更新页。该范围内没有找到新增的公开整体音量写入接口；这不是完整 27 SDK 的二进制差异审计，更不能否定本轮已经成功的私有调用。

`AVSystemController` 的方法签名由当前 27 运行时获得，写入前逐项检查 ABI。MediaRemote 的 set/mute 导出也存在，但尚未调用：没有按旧 C 签名猜测调用。没有证据把 MediaRemote 的权限或所有声音域覆盖面外推自 AVSystemController。

应用第一次启动遇到设备端开发者信任要求，用户已完成；随后运行成功。本机签名校验通过，描述文件包含目标设备并有效，实际 entitlement 是普通开发签名配置，没有私有音量权限。未越狱、未提权、未改系统安全策略、未下载大型新版 Xcode、未提交 git commit。

## 交付与当前状态

`experiments/MetadataProbe` 为 Swift/Xcode 实验源代码，包含默认符号扫描、`--test-volume` 私有写入对照、`--listen` Wi-Fi 命令、短时 duck，以及 `--ble` 蓝牙后台事件探针。同目录 `MacBLEClient.swift` 是 Mac 中央设备实验客户端；`experiments/MacInputActivityProbe.swift` 是独立的 Mac 只读输入活动观察器。已通过本机存在/缺失与协议边界检查、两份 Mac 源码编译、真机编译签名和上述设备实验。它们不是成品，不应作为长期后台守护程序使用。

最新协议加入四秒命令有效期，并拒绝过期命令，避免后台积压的开始指令在恢复前台后才执行；这只是减少迟到副作用，不会提供唤醒。duck 的20秒租约实测证明计时器会被挂起，因此没有承诺租约能在后台准时恢复。

实验已清理：最后 stop 返回 DUCK_ALREADY_INACTIVE；LLDB 已正常 detach 并退出。锁屏对照结束后，新版蓝牙探针通过已认证的 `stop` 命令清除启用标记、停止广播并移除服务；从自身 App 偏好文件读取到 `BLEProbeEnabled=false`，最终测试进程已终止。Mac 客户端也已退出。最后一次私有分类音量测试确认恢复到实验前值。没有留下持续音频、录音或调试暂停进程。Mac 在关闭后仍出现一次缓存发现与连接，但没有发现可写特征，不能仅凭扫描结果判断仍在提供服务。

当前已分别验证 Mac 跨应用输入活动观察、蓝牙后台/锁屏唤醒，以及 iPad 媒体音量短时降低与恢复；尚未把三者接成自动链路。用户已接受蓝牙作为产品通道；仍要求无线、日常尽量自动、无需常插 USB。最小实验状态保存在 Keychain 与 App 偏好中，本次锁屏安装更新后认证命令仍可处理。下一阶段需要实现 Mac 录音状态到蓝牙开始/结束指令的对账、应用层完成确认和尊重用户手调音量的恢复规则，再验证 iPad 进程被系统回收、重启后首次解锁及长时间断线。Apple 的[蓝牙恢复规则](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)指出用户强制退出等情况有例外，不能承诺无条件自动恢复。蓝牙可达和 RSSI 不能保证设备在同一房间。纯 LAN 目前只证明前台控制；`devicectl` 只证明解锁按需启动。其他声音域尚未验证。持续静音输出已被用户排除为产品手段，本轮没有实施。

当前普通开发描述文件到期日为2026-10-03（本机实际profile）。日常自动运行还需验证到期前重新签名/安装、连接丢失后恢复，以及Mac/iPad重启后的重新建立条件；本轮没有为测试重启设备，也没有把开发依赖本身判定为不适合自用。
