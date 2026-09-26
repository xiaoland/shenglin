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

现行流程已改为 iPad 显示一次性六位码、Mac 输入一次。采用 BoringSSL SPAKE2 并对会话、设备名和双向消息做密钥确认。`swift test` 的配对测试覆盖正确码、错码、身份修改、会话重放、超时和确认前不得取得控制密钥。Mac Release 与 iPad 签名构建通过，新 iPad 包已安装。用户随后确认新版真机配对验收通过；目前没有记录逐项的错误码重试、超时、取消及旧密钥替换观察，因此不把这些边界计为已验证。

2026-09-26 的可维护性整理在独立 worktree 验证：`swift test` 原有五项通过，Mac Release 与 iPad Debug 的无签名设备构建通过。此次没有启动或替换正在运行的 App，也没有重新执行真机配对；验证范围是现有代码路径的编译和原有行为测试。

同日的工程维护检查使用 Xcode 26.2：原有五项 `swift test` 再次通过，Mac Release 和 iPad Debug 均完成无签名设备构建；两个构建脚本通过 `sh -n`。在隔离目录用替身命令检查了 BoringSSL 脚本的首次构建、同版本复用和版本变更后重建，以及 Mac App 签名失败保留旧构建、签名成功替换旧构建。临时 Unix socket 接受请求后不响应，客户端约 3 秒返回读取超时，错误保留系统原因。替身检查不等于重新下载或编译真实 BoringSSL，也不等于真实代码签名；本轮未安装、调用运行中的 IPC 或重新验证真机音量行为。

随后针对状态失效路径做了隔离检查：模拟已选输入活动→Core Audio 查询失败→同一进程输入恢复→输入结束，观察到降音量请求依次为开启、关闭、开启、关闭，错误状态在恢复时清除。Mac Release 无签名构建与原有五项测试通过。连接状态改由认证回执驱动，配对及 BLE 旧实例回调由当前会话代次过滤；这些异步边界尚未在真机上逐项复验。

验证没有覆盖 iPad 被系统回收后自动重启、设备重启后首次解锁、长时间蓝牙中断或输出路由切换。旧可行性探针的原始方法和边界见 [feasibility.md](feasibility.md)。

2026-09-26 夜间新增排除列表和虚拟麦克风代码，未替换正在运行的 Mac App，也未安装 HAL 驱动。排除列表的旧 `selection.json` 迁移、默认全参与及应用身份匹配已有 Swift 测试；Mac GUI 无签名构建通过。虚拟麦克风 `scripts/build-driver.sh` 构建出 macOS 14 起可加载的输入设备包，进程内测试验证两个客户端读取同一批样本时只静音指定 PID、取消静音恢复、断供归零、恢复供源和无输出流。测试不经过系统 HAL，不证明实际逐客户端回调、物理输入权限、Core Audio 自定义属性跨进程传输或音频连续性。

下一轮真机验收先在新 App 首次启动前把 `bundle:com.openai.codex` 写入 `exclusions.json`，避免当前正在录音的聊天 App 因新策略默认全参与而立刻降低 iPad 音量。之后签名安装驱动并确认系统只出现一个输入设备，再分别让 ChatGPT 和 Koe 选择该设备同时录音：单独切换一方静音、核对另一方样本不变，核对静音方不触发 iPad 降音量；ChatGPT 虽被排除仍能收到麦克风样本，Koe 保持协同。还需测物理输入断开及切换、菜单退出、驱动供源暂停、并发开始/结束和 iPad 音量恢复。此前的六位码配对已真机通过，无需为这轮再次配对。

2026-09-27 的多设备实现检查使用隔离的 iPad (A16) iOS 26.3 模拟器，不接触真实 iPad，也未安装 HAL 驱动或更改系统音频服务。新协议的 Swift 测试覆盖多来源、重复/旧状态、认证、续期、过期、整轮手动接管及持久化重读；本轮 `swift test` 8 项全过。Mac Release 无签名构建和 iPad 模拟器 arm64 无签名构建通过，iPad App 在模拟器安装、启动成功。这些结果不证明两台设备之间的 BLE 实际互通、系统音量变化、三端全连接或后台/锁屏交付。

Mac 端只做了只读 Core Audio 探针：当前默认输出提供可读且可设置的主音量属性，读数为 0.5625；没有调用设置器。iPad 录音探针把独立观察 App 配成 `.playback + .voicePrompt + mixWithOthers`，基线 `promptStyle` 为 `.normal`，`isOtherAudioPlaying=false`。拟作为对照组的录音 App 因模拟器输入格式为 0 Hz，在安装录音 tap 时崩溃；`simctl io enumerate` 显示其宿主默认音频设备没有输入。因此没有得到“另一个 App 正在录音”的有效对照，不从基线推断检测能力。Apple 将 [`promptStyle == .none`](https://developer.apple.com/documentation/avfaudio/avaudiosession/promptstyle-swift.enum/none) 描述为其他音频会话正在使用麦克风的语音提示建议，但 [`promptStyle`](https://developer.apple.com/documentation/avfaudio/avaudiosession/promptstyle-swift.property) 本身是提示样式；[`isOtherAudioPlaying`](https://developer.apple.com/documentation/avfaudio/avaudiosession/isotheraudioplaying) 判断的是其他 App 播放音频。它们尚不能证明任意录音 App 的开始/结束、后台持续性或来源身份。iPad 新代码因此只发布 `quiet=false`，不把该提示直接当作自动调低 Mac 音量的触发器。

当前实现值为每 5 秒续期、接收后最多 20 秒租约、约 0.8 秒八步恢复；这些尚未在真机校准。iPad 使用一秒采样观察手动音量变化，短于采样间隔的往返操作可能漏检。iPad App 被系统挂起或回收时，租约计时器是否及时运行尚无证据；不可把超时恢复承诺为确定的后台行为。

随后增设了 Network.framework 的 Bonjour/TCP 传输（Mac 监听、iPad 浏览），只在本地 Wi-Fi 接口上连接，连接双方须通过配对密钥的随机挑战认证，再承载已有签名状态与回执；同一来源的 BLE/Wi-Fi 消息共用版本和账本。UI 可选择 BLE 或 Wi-Fi、BLE 且 Wi-Fi；已满足的空间证据短暂消失时沿用最多 20 秒。iPad 的 BLE 依据绑定已认证的 central 并设置证据失效期，Wi-Fi 候选从开始连接起设置超时。`swift test` 10 项、Mac Release 与 iPad 模拟器 arm64 无签名构建通过。为避免触发尚不可用的用户权限选择，本轮没有启动新增局域网发现代码或进行两机实网互通检查；构建成功不证明 Bonjour 广播、权限取得、TCP 认证或后台收发成功。Wi-Fi 证据是已配对端经本地 Wi-Fi 路径认证互通，不证明同一 SSID、接入点或物理同室，且可能受局域网隔离影响。三来源账本测试只证明聚合规则；实际三端全连接仍未实现。

随后完成两台 Mac 与一台 iPad 的三条边的源码连接：iPad 的新配对写入多密钥列表，原单密钥只在尚无列表时读取以供迁移；BLE ACK 和反向状态按已认证 central 的密钥分别读取或发送，空间判定及撤销也按来源进行。Mac↔Mac 使用独立的 6 位码 SPAKE2 握手，保存双方角色和配对密钥，经该密钥筛选 Bonjour 服务并双向认证 TCP 链路；两台 Mac 不依赖 iPad 转发。Mac 当前只保留一台 iPad 的活动连接，但可同时保留多条 Mac 直连。严格 AND 模式对 Mac↔Mac 缺少 BLE 证据，代码保持关闭。`swift test` 12 项通过，其中离线测试运行了两次 Mac 身份的实际 SPAKE2 双向握手，覆盖错误码、过期和重放；另以两把独立密钥验证 Wi-Fi 角色证明、回执隔离及断开一个来源后另一个仍有效。Mac Release 与 iPad 模拟器无签名构建通过。未启动 Bonjour/Network.framework 的新链路，因为该路径可能触发当前未授权的本地网络权限；因此不把握手类测试或构建等同于真实 TCP 会话。没有运行或替换系统音频程序，也没有真实 iPad。三设备互通、交错 GATT 收发、局域网发现与权限、后台恢复和实际音量仍待设备验收。
