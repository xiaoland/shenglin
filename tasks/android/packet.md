# 安卓版实现

用户于 2026-10-15 授权实现安卓版和使用 USB 闲置 Android 真机，并在本轮后续明确允许自主提交；提交只包含当前任务相关改动。实现及本轮真机缺陷修复已完成，三端最终包已安装。iPad 保留数据覆盖后实际 UI 确认两台设备可协同、自动协同开启、本机未录音，临时 runner 已退出并卸载；本轮收尾完成。正式证据与未覆盖边界见 docs/validation.md；本文件下方为调查与阶段记录，历史“待验收”描述不代表最新状态。保留其他任务未提交修改。

最新结果：Mac QQ 音乐反复降量/恢复根因已修复，真实手机录音约41秒、Mac80秒522样本无输入错误，QQ音乐只有一个降量周期并恢复。最终Mac重启两peer自动恢复，开码无旧错误/本机候选；手机3/15、iPad32%，自动协同开启，三端每对关系保留，测试录音及runner按owner清理。Android20单测与lint/runtime、Swift28项、相关输入/配对/展示边界及Apple构建均已通过。未覆盖长期锁屏/OEM/Android双真机/双WiFi拓扑，后台心跳曾短暂不可读且原因未定位；没有正式发布或提交。

## 已确认范围

Android 与 Mac、iPad、Android 都是直接对等节点，不经 Mac 中转。配对信任与空间证据分开：用户明确保留独立可选的 Wi-Fi 与局域网范围，并保留各自与蓝牙的 OR/AND 组合。局域网含 Wi-Fi/网线；任何代理均不保证物理同室。旧配置值与旧配对关系保持兼容。模拟器数据必须位于 Work SSD。

## 独立 Wi-Fi 条件修正

用户于本轮明确“不要丢掉同一WiFi这个可选的协同条件”。此前将原WiFi选项直接改为LAN不满足要求：须保留WiFi和LAN两个可选网络范围，并保留蓝牙OR/AND组合。已定契约：新增 networkScope=wifi|lan，缺字段默认wifi，旧SpaceMode raw只表达OR/AND。双方实际WiFi路径及签名medium证明才有WiFi证据；proof追加medium与mediumSignature，签名用途串network-medium|1|role|nonce|medium，旧identity proof不变。缺/无效medium仅不提供WiFi资格，旧端LAN仍兼容；路径变化撤销证据重认证。Apple owner负责Shared/Mac/iPad，Android transport owner负责实际证据/选路，protocol owner负责Java helper与跨语言检查，app owner负责UI/安装验收。验证须区分有线LAN与WiFi路径、模式立即切换和持久设置恢复；不把文案变化当作实现。

Android transport 已接入独立 `verifiedWifi` 与 `verifiedLan`：Wi-Fi资格要求当前绑定Network为Wi-Fi且对端本次 nonce/role 的签名 medium 为 Wi-Fi；缺失或无效字段仍允许旧身份 proof 建立 LAN 认证。`networkScope` 与 OR/AND 变化均 reset SpaceGate，并依据切换后的原始证据保留/结束每个来源租约。LAN Network、介质或本地地址改变会关闭旧状态链路、撤销两种 LAN 证据并重认证；蓝牙证据仍独立参与 OR/AND。新增单测覆盖介质资格与组合选择；API28 真机的 Wi-Fi/LAN scope、持久化、切换及真实对端验证已通过，见下文。

## 当前实现

通用局域网配对采用 SPAKE2 v4（平台/名称入 transcript），服务 `_shenglin-pair4._tcp`，新记录 `transport=wifiDirect` 标记通用关系而非只允许 LAN。新边的状态监听方为配对 initiator。旧 v3 BLE 与既有记录继续兼容。pending 密钥需双向认证激活，五分钟过期。状态共用 HMAC、来源、递增序号与租约；5 秒续期、20 秒租约及空间宽限，切模式或暂停立即 reset。

Android BLE 对 Mac 为 peripheral，对 iPad 为 central，Android 双端由配对 initiator 为 central；签名 origin 始终来自配对角色。LAN 与 BLE 共用 ledger/revision/SpaceGate，不重复降音量；只有签名状态/匹配 ACK 才形成 BLE 证据。空间内录音 unknown 不续期；独立链路可支撑 OR，AND 必须双条件。Mac↔Mac 未增加 BLE 能力。

Android 使用匿名全局录音配置，无 RECORD_AUDIO、不采音。用户可见 connectedDevice 前台服务；STREAM_MUSIC 上限与整轮快照，外部音量/路由变化让权。密钥经 Keystore 保护、AtomicFile 私有持久化、禁止备份；恢复失败保留快照重试。

网络修复包括 Android 有序后台 socket 写入、状态停止排空、干净 name/type 的串行 NSD 重新解析、代次保护；Apple Bonjour 服务解析和连接均绑定发现的物理 Wi-Fi/以太网接口，避免 VPN 解析路由。蓝牙支持长读快照、prepared writes、真实 MTU 和运行期权限变化。

## 分工及交付

- android_protocol：core/JNI、ble 模块和协议/边界测试，已完成。
- android_feasibility：Android transport、LAN/BLE 聚合和 NSD 修复，已完成。
- android_app：工程/UI/权限/录音/音量/存储、构建与独占真机测试，已完成。
- apple_peer_integration：Apple v4/角色/LAN/BLE接入、GATT边界及隔离peripheral探针，已完成。
- android_transport_decision：跨平台角色与物理网络绑定的判断建议，已采用并有实测支持。
- 主 agent：跨语言探针、文档、证据整合。

## 验证与交付状态

Swift25项、Mac Release/iPad Debug无签名构建、展示/输出/GATT边界检查通过。真实Swift/Java/JNI五个方向握手与签名、CoreSelfTest/BleProtocolTest通过。Android APK/AndroidTest、17项单元测试、lint通过；API34模拟器和Huawei JKM-AL00a Android9/API28实际RuntimeChecks通过。

真机完成两个LAN配对角色、音量8→3→8、手动6保持、本机录音保护和签名状态往返。Mac central→Android peripheral（MTU185）完成BLE认证；AND在断LAN后约20秒恢复，OR在仅BLE时仍降量/恢复并传递真实录音状态。Android central→Mac模拟iPad peripheral（MTU517）也完成LAN认证与纯BLE8→3→8。probe不等同完整Apple音频App验收。

最终APK在 `Android/app/build/outputs/apk/debug/app-debug.apk` 并已安装；手机音量恢复3/15、自动协同开启、所有临时配对和生成的录音已删除。证据汇总 `local/AndroidValidation/validation-notes.txt`，正式范围见 `docs/validation.md`。模拟器已关闭，AVD在 `/Volumes/WorkSSD/Android/avd/shenglin-test-api34.avd`；内置盘仅有索引，SDK也在Work SSD。

剩余验证边界：首次Mac central ATT14后自动重连，未复现、未定位原因；真实iPad新版BLE、Android双真机、三端并发、锁屏/OEM回收和任意录音应用未验收。正式签名分发未发布，Mac/iPad跨端使用需运行本次更新的版本。无须用户追加实现授权；这些边界不能被现有证据覆盖。

本轮修正收口证据：Swift28项、Android18项单测、Mac/iPad及Android构建/lint、真实默认与保存instrumentation通过；跨语言介质签名比对通过。Mac网线/手机WiFi且无BLE的条件下，WiFi scope拒绝quiet保持8，LAN scope允许8→3，切回WiFi立即恢复8。证据为local/AndroidValidation/scope-*与network-scope-*。尚未实测双端都走WiFi的拓扑；默认值wifi已验证，手机最终按此前用户认可的有线Mac场景显式选LAN，保留WiFi可选。

## 配对 UI 自发现修正

真机显示本机配对码时，NSD discovery曾把本机的配对 listener 作为待配对候选；Bonjour会规范化服务显示名大小写，因此设备名大小写比较不是身份判据，也会误删同名真设备。Android现在在服务解析后比较本机登记 listener 的端口及当前Network全部本地IP（含IPv6），并把解析发起时的本机端点快照带到异步回调；取消后保留10秒端点身份以过滤迟到回调。取消窗口同时精确清除自候选。不同本地IP或端口的同名设备仍可配对。

配对码及生命周期状态来自运行中的 PeerTransport snapshot，Activity重建后可恢复仍有效的码；状态区分 waiting、verifying、verified、activated、cancelled、expired、failed。取消按钮走 transport.cancelPairing，错误码/连接失败归为 failed，成功待状态链路认证时为 verified，认证激活后为 activated。运行期快照不跨进程恢复，服务进程重启时旧socket/code本就失效。

验证：API28真机显示本机码时候选列表不出现本机；销毁并重入Activity仍显示同一码；取消后无候选残留。`TransportLifecycleTest` 增加同端点、同IP不同端口、异IP同端口及IPv6本地地址匹配断言，并覆盖配对快照到期/成功状态。待最终单测重跑及真机同名合法peer回归；platform TXT未形成跨端契约，未配对候选显示名不能可靠区分Mac/iPad，UI应保持中性设备标签并明确说明支持平台。

## 既有 logo 复用修正

用户指出 Android 启动图标未使用既有 logo。已确认 drawable/ic_shenglin.xml 为临时扬声器，正式图源是 Design/AppIcon-iPad.svg（与 Mac 的 Design/AppIcon.svg 使用同一图形及 #065e6e 配色）。android_app owner 负责精确复用图源并适配 Android 启动图标、构建覆盖安装和真机桌面截图；不改变业务行为，不卸载，不提交。主 agent 负责采用视觉证据并收口。

## 完整 App 流程补验

用户报告“配对本设备名称”与缺少 iPad 配对提示。Android 真机已复现：显示本机码后发现列表出现自身（Bonjour 改变了名称大小写）。android_feasibility 负责发现身份与生命周期修复，android_app 负责真实界面、安装及手机独占操作，apple_peer_integration 负责实际 Apple 设备版本与配对流程。不得以名称相等排除真实同名设备，不得以模拟 iPad 探针作为真实 iPad App 证据。

完成判据为真实 App 的设备发现不包含本机、显示远端配对码后可发现、双向发起配对并激活、取消/错误码/重开不遗留误导状态、实际录音触发与结束恢复、取消配对后停止协同。每项须标明实际端点及版本；无法连接的硬件须保留未验收状态。既有 logo 已在覆盖安装后的手机桌面确认，证据 local/AndroidValidation/launcher-logo.png。

## 音量往复故障调查记录

用户报告并通过真实 Huawei Android 设备确认：Mac AUHAL Reader 输入运行期间，手机在约 0.15–0.3 秒内反复执行 STREAM_MUSIC 3↔8；每个音量命令都来自 `local.shenglin`。证据保留于 `local/AndroidValidation/volume-oscillation-audio.txt` 与 `volume-oscillation-logcat.txt`，此前单次 8→3→8 的音量验收不能覆盖该故障，已撤回为完整流程通过的依据。

当前证据指向 Mac 输入状态发布时序，而非 Android 音量层去抖：Mac `AppModel` 的 250ms timer 同步调用 `InputActivity.poll()` 后立刻计算并发布状态，但 `InputActivity.changed` 通过另一个 MainActor Task 异步更新 `inputState.error`。查询失败先清除参与 PID；同一轮仍可能以旧的无错误状态组合出签名 `known=true, quiet=false`。查询恢复时参与 PID 已更新，而旧 error 尚未更新，`needsQuiet` 又使状态成为签名 quiet。Mac 同一时段统一日志记录了 Core Audio 查询失败及 AUHAL 输入设备切换，手机音量命令频率与该轮询节奏相符。Android 现有日志没有记录状态帧 origin/revision，无法从手机侧日志证明具体远端 update 序列；Android ledger 按配对 peer 接受严格递增 revision，重复/旧 revision不更新租约。当前由 Apple owner 修复并验证输入状态快照一致性；Android transport 暂无证据支持另行改变签名状态语义。不得重新执行主动音量测试，直到设备 owner 另行协调。

当前部署纠正：真实 iPad 旧包的 Bonjour 声明只有 `_shenglin._tcp`，不含 `_shenglin-pair4._tcp`；新签名包已保留数据覆盖安装并启动。Mac 已使用 scripts/build-mac-app.sh 更新唯一 /Applications/Shenglin.app，真实窗口确认原 iPad 配对仍可协同。iPad owner 正使用独立 XCTest runner 操作实际 App，Android owner 独占手机；主 agent 负责实际 Mac 窗口。

补验阶段结果：手机本机发现已消失，Activity 重建仍显示有效码、取消后无候选残留。真实 iPad 先错码再正确码重试，与 Android 双端激活；iPad VoiceMemos 实际录音使手机音量 8→3，停止恢复 8，新增测试录音已删除。Mac 最终签名安装的添加设备界面确认已配 iPad 不再重复列为待配 BLE 候选（按 peripheralID，非名称过滤）。反向录音、iPad 发起配对和 Mac↔Android 流程仍在执行。

## 严重音量抖动调查与修复记录

用户实际观察 Mac QQ 音乐约每秒静音/恢复。手机系统日志也证实19:58:13–23约0.15–0.3秒重复3↔8；因此撤回本轮Mac→Android稳定通过结论。所有主动录音/调音/配对测试暂停，关系与日志保留；手机当前8/15，iPad32%，原Mac-iPad和新Mac-Android关系保留，iPad-Android测试关系已移除。

证据：local/AndroidValidation/volume-oscillation-{audio,logcat,services}.txt、volume-oscillation-mac-status.json、volume-oscillation-mac-unified.log。Mac日志同周期报Core Audio输入查询失败并停止GUI音频IO。Appleowner确认InputActivity同步清PID集合、AppModel异步更新error期间会发布known=true/quiet=false伪idle；正在修一致快照，另查输出tap/aggregate重建环。transportowner查收到的双链路状态，appowner查实际volume事件，advisor提供独立判断。完整验收必须看连续状态/音量事件，不能仅比较开始、中间、结束三个采样值。

根因硬件闭环：主agent正常退出Mac GUI后，用正式`--output-validation`仅对低幅合成afplay做gain=1、4秒重放，不打开麦克风、不控制QQ音乐。原activeInputDevices仅在空devices处加日志，重放PID5375/object136持续runningInput但input设备数组空→全局nil；释放后回到空输入集合。证据tap-input-query.log/tap-unity-relay.log。因此GUI重放自身引发unknown→拆重放→查询恢复→重建的循环已证实。修复owner正提前排除本产品同可执行文件音频进程，并改用同一次poll的lastObservation；不忽略外部错误。

修复代码与边界回归已通过：activeInputDevices仍先跳过空闲进程，再取得PID并提前排除本PID/显式忽略PID/同可执行文件内部进程，最后查询输入设备；外部失败保持unknown。AppModel两处known判断读取同次poll的lastObservation。修后同unity硬件检查使用真实修后查询、显式排除独立relayPID，60次样本0unknown（修前39次失败）；生产同exe路径仍需实际App复验。Mac Release构建及输入/快照/展示回归通过，主agent正在唯一签名安装，之后以150ms持续采样Mac状态和Android完整AudioService事件复验。

已安装修复版并完成Mac本机真实复验：60秒392个约150ms状态样本，0查询错误，inputCount只有0→1（持续30秒）→0。实际诊断显示QQ音乐降量后恢复；Mac unified GUI仅20:11:25启动一次重放、20:11:55停止一次，没有反复IO。Android连续60秒400样本和额外15秒100样本全8、无新的调音事件：不是通过，而是Mac重启后Android BLE没有重连，当前WiFi scope不接受有线LAN。transportowner正在处理重连，手机GATT服务存在但连接0；原iPadMacBLE已恢复。

BLE恢复修复已安装并实测：Android当前新UUID81823…从旧缓存1CDF…恢复，两端以签名ACK确认，原iPad保持连接。之后连续phone534样本仅8→3→8，AudioService ring恰两次调用（20:21:44.211降、20:22:14.358恢复，30.147秒）；主/尾段采样有11.49秒调度空档但系统事件覆盖该空档，恢复后35秒仍稳定。Mac522样本inputCount仅0→1→0；有6条“后台麦克风服务未运行”诊断，owner核验agent runs=1、从未退出，属于短暂心跳不可用而非CoreAudio输入query失败，具体写入延迟原因尚未证实，不声称0诊断错误。

剩余产品流程：Mac也缺单peer取消入口，Appleowner正补（原iPad关系保留），之后Android发起Mac错码/正确重试及真实录音→Mac输出恢复；iPad逆向可与此并行，由phone/app与Appleowner协调，最终保留三端每对一条真实有效关系。


当前收口（覆盖以上历史待办）：真实 iPad→Android 反向配对已成功，iPad 与手机都显示激活，原 Mac 关系保留；临时 iPad UI runner 已退出并卸载。Mac 单台取消实际确认仅移除 Android，原 iPad 继续协同。随后 Android→Mac 实际错码被拒绝，正确码后 Mac 显示“已添加 JKM-AL00a”，LAN+BLE 双认证，最终两条手机关系均保留。正在执行手机真实录音→Mac QQ 音乐连续复验。Mac 开码发现旧超时状态残留及返回查找时本机候选，Apple owner 正修复并测试；主 agent 随后统一最终部署。媒体最终仍需恢复3/15，文档需收口，不提交。


## Rust 共享核心提议（2026-10-15）

用户提出通过 Rust lib + UniFFI 抽离跨端共同逻辑。目前进行架构边界调查，尚未修改应用源码。已确认 Swift Shared 与 Android Java core 重复实现配对、签名消息、网络介质证明、SpaceGate 和 PeerDemandLedger；native 音频、BLE/NSD、权限与密钥存储仍有系统依赖。UniFFI 官方资料确认 Swift/Kotlin 绑定，Android 现有纯 Java 工程需新增 Kotlin 编译接入。advisor 正独立核对迁移边界与兼容路径。迁移要求保留现有 v3/v4 配对、签名字节格式、已保存关系、WiFi/LAN 与 OR/AND 配置及未知输入/手动接管语义；当前 BoringSSL PAKE 不随语言迁移贸然更换实现。

调查结论：建议先将 wire 编解码、签名/校验、Ledger 和 SpaceGate 作为完整共同语义迁移至 Rust，通过同步显式事件/时间输入返回决策；native 保留网络与蓝牙I/O、输入观察、音量执行、系统密钥存储及UI。随后迁移配对状态机/transcript，继续使用当前固定 BoringSSL PAKE，避免同时更换密码实现。跨端音量机制不同，不强行共享音量数值算法。迁移验收应包括旧/新混合互通、u64 revision与既有存储恢复、unknown不续期/重放拒绝/手动接管，以及实际三端持续录音降量恢复。此为建议，尚未开始源码迁移或提交。

当前接续：用户已授权 Rust / UniFFI 与 Android Kotlin / Compose 实施，迁移及最终三端验收由 [共同核心任务包](../rust-core/packet.md) 维护；以上提议和待办为历史过程，不再代表当前实施状态。
