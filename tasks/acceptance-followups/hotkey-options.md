# 同一快捷键同时控制 声邻与前台应用：机制调查

目标是用户按一次已配置组合时，声邻切换专用麦克风静音，前台 Codex App 仍收到原始 `keyDown` 并执行自己的应用内静音命令。用户关注的是系统实际向 声邻交付哪些键盘输入；回调里只匹配目标组合、不记录其他按键，并不等于系统只交付目标组合。用户已选择 session listen-only 作为**可选、默认关闭**的共享模式；用户随后在签名版启用并亲自按已配置组合，确认 声邻与 Codex App 均响应；下表保留决策依据和长期未验证边界。

## 已有实测与当前状态

- 先前关闭共享模式的运行版使用 Carbon `RegisterEventHotKey` 的非独占选项。用户实测 ⌃⌘M 只有 声邻响应；二进制反汇编确认选项为 0。Codex App 包内把 `realtimeVoice.toggleMicrophoneMute` 标为应用内命令。隔离的 ⌃⌥⇧9 测试中，两个非独占 Carbon 注册者都收到通知，但聚焦的普通 AppKit 窗口未收到 `keyDown`；Carbon 回调返回 `eventNotHandledErr` 也未让它恢复。本机 macOS SDK 的 `CarbonEvents.h`（`HIToolbox.framework/Headers`）对“非独占”只保证同组合的热键注册者可同时收通知，没有保证普通窗口继续收到按键。完整记录见 [验收记录](../../docs/validation.md)。
- 隔离的 listen-only session tap 测试使用临时组合 ⌃⌥⇧9：tap 收到按键，聚焦的 AppKit 窗口也收到一次 `keyDown`。这项隔离短测本身只证明临时进程与窗口的透传；后续签名版的真实双端手动验收已通过。当前 [开发源码](../../Mac/Selection.swift) 和[主窗口开关](../../MacGUI/App.swift)已按需接入并签名部署；默认仍为 Carbon，显式启用时先注销 Carbon 再请求授权，未授权则 声邻快捷键暂不可用。真实双端验收及范围见[验收记录](../../docs/validation.md)。
- 目前没有找到公开 API 同时承诺“系统只交付一个完整的修饰键组合给 声邻”且“前台应用仍收到原始按键”。这是现有文档与实验范围内的结论，不是对所有可能实现的不可能性证明。

## 候选比较

| 机制 | 系统交付给 声邻的输入范围 | 前台原始按键 | 权限与运行代价 | 当前证据和缺口 |
| --- | --- | --- | --- | --- |
| Carbon 非独占热键 | 只交付注册组合的热键通知，不交付普通键流。 | 对另一个 Carbon 非独占注册者可共享；对 Codex 的应用内 `keyDown`，本机实验为**否**。 | 当前签名版无需新的键盘监控授权；回调仅在命中组合时发生。 | 真实 ⌃⌘M 验收失败，不能靠把独占改为非独占解决。系统 SDK 只说明热键注册者之间的共享。 |
| `CGEventTap` session listen-only | `eventsOfInterest` 只能选事件类型；选 `keyDown`/`keyUp` 后，这两类事件的**全部按键**都会进回调，再由 声邻自行匹配。 | Apple 规定被动 tap 不能改写或丢弃；临时组合透传实测成功。 | 监听键盘需要“输入监控”授权；每次按键都会触发回调。CPU、延迟、长时稳定和超时恢复尚无产品测量。 | 有默认关闭的候选实现和隔离短测；观察范围与用户当前偏好不符。[事件类型掩码](https://developer.apple.com/documentation/coregraphics/cgeventmask)、[被动选项](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions/listenonly)、[Apple DTS 权限说明](https://developer.apple.com/forums/thread/724608)。 |
| `CGEventTap` session active | 同样按事件类型交付全部所选键流；回调返回原事件可放行，返回 `NULL` 可吞掉。 | API 支持原样返回，但尚未针对同键需求做实测；主动链上的延迟或故障可能影响前台输入。 | 键盘过滤涉及辅助功能/事件控制授权，实际签名版权限路径需核对；存在系统因回调超时禁用 tap 的机制。 | 它解决不了“只向 声邻交付目标组合”的范围要求，暂不推荐。[回调返回语义](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback)、[主动选项](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions/defaulttap)、[超时事件](https://developer.apple.com/documentation/coregraphics/cgeventtype/tapdisabledbytimeout)。 |
| `CGEvent.tapCreateForPid` 被动监听 | Apple 提供按进程建 tap 的公开入口，可望缩小到目标进程的键事件；**仍是该进程的全部所选事件类型，不是单个组合**。 | 被动 tap 理论上透传；该 API 在目标 Codex 进程上尚未实验。 | 预计仍需键盘监听授权；需跟踪 Codex 前台进程及重启，UI/WebView 是否同一 PID 未核实。 | 比 session tap 范围小，但仍观察 Codex 内的其他输入；只能在 Codex 获得事件时响应，可能不满足“任意前台应用”场景。[Apple 进程 tap API](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreateforpid%28pid%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29)。 |
| `NSEvent` global monitor | 只能按事件**类型**选，例如其他应用的全部 `keyDown`；不能按完整组合在系统投递前过滤，也不收 声邻自己的事件。 | Apple 规定它只能观察，不能阻断或修改，故前台继续收事件。 | Apple 文档要求键盘监控有辅助功能信任；回调异步送到主线程，实际性能和授权行为未在产品测量。 | 比被动 event tap 更高层，但观察范围没有本质改善。[Apple `NSEvent` 文档](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)。 |
| IOKit `IOHIDManagerSetInputValueMatchingMultiple` / CoreHID 元素更新 | 可按少数 HID **物理元素**（目标键和相关修饰键）筛选输入值，理论上比整个键流窄；不是按完整逻辑组合由系统过滤。 | 非独占打开设备应保留系统正常处理，但尚未在本机验证；不能使用 `SeizeDevice`，它明确阻止系统收事件。 | 键盘 HID 访问需要用户允许输入监控。要覆盖内建、USB、蓝牙键盘及设备热插拔；需测回调数量、CPU 和延迟。 | **最值得下一步做隔离实验**。物理 HID usage 与经系统重映射、输入法、软件生成的 Codex 快捷键可能不一致；CoreHID 的可用系统版本也需核对。[元素匹配](https://developer.apple.com/documentation/iokit/1438379-iohidmanagersetinputvaluematchin)、[CoreHID 元素示例](https://developer.apple.com/documentation/corehid/communicatingwithhiddevices)、[独占打开的后果](https://developer.apple.com/documentation/iokit/1556660-anonymous/kiohidoptionstypeseizedevice)、[Apple DTS 对键盘 HID 授权的说明](https://developer.apple.com/forums/thread/804793)。 |

性能不能只用“回调逻辑很短”推断：需要量实际 callback 次数、每次处理时长、声邻CPU、聚焦应用 `keyDown` 延迟，以及休眠/唤醒、权限变更、键盘热插拔后的恢复。尤其对主动 tap，Apple 明确提供超时禁用事件；[重新启用 API](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable%28tap%3Aenable%3A%29) 也不能代替失效检测与恢复测试。

## 未选 HID 路线的区分性实验（暂缓）

若共享模式的手动验收不满足需求，可在隔离测试程序中用 `IOHIDManagerSetInputValueMatchingMultiple` 只订阅临时组合的目标物理键和修饰键元素，并以**非独占**方式打开键盘。分别在内建键盘和可用的外接键盘上输入临时组合及普通文本，同时让一个聚焦的测试窗口计数 `keyDown`；仅记录事件**计数、usage、耗时和 CPU**，不保存字符内容，不触碰用户真实 ⌃⌘M 或 Codex 通话。若回调只收到指定元素、聚焦窗口仍收到原键，再测试系统重映射和设备切换；若匹配无效、透传失败或无法覆盖常见键盘，就排除这条路线。实验前不需要部署 声邻，也不修改安全设置；如测试进程需要系统授权，应停在授权边界并记录结果。
