# Rust 共同核心与 Android Kotlin / Compose 迁移

状态：实现、兼容检查和三端实机验收完成，按用户授权提交。用户要求保留协议与既有配对、完成三端真机验收后提交；不推送、不发布。当前任务包括必要的 Android 前置实现与音量抖动修复，其他任务的 Mac 唯一安装脚本改动留在工作区。

## 实施边界

Rust 负责 wire 编解码、签名与验证、租约/去重账本、空间条件、BLE 签名证据及配对状态机。同步 API 接受显式时间，不创建网络、线程或定时器。Swift/Kotlin 保留原生传输、输入观察、实际音量执行、权限、生命周期及系统密钥存储。PAKE 继续使用原 NativePAKE 和固定 BoringSSL，不改变 v3/v4 transcript、已存密钥、签名或 ledger 语义。Apple 保留同次观察的 known/quiet 组合，Android 使用原有组合规则。

Android 生产代码已全部迁为 Kotlin，Compose Material 3 提供首页、设备、设置三个入口，实际空间资格来自已有 Rust gate。Wi-Fi/LAN 和蓝牙 OR/AND 均保留，仍是对等设备。图标沿用既有 logo。构建缓存和产物在 Work SSD；没有新增模拟器。Android Studio 曾用于尝试 Java→Kotlin 转换器，但未信任/导入工程，已退出；不是构建依赖。

## 验收与修复

Rust 8 项、Swift 29 项、Android 23 项测试通过，Android lint、APK/AndroidTest、Mac Release 与 iPad 真机签名构建通过。完整互操作入口验证新旧 Swift/Java/Kotlin、v3/v4 等 16 个组合；Android API28 RuntimeChecks覆盖真实 UniFFI PAKE、Keystore/AtomicFile、录音查询、媒体音量、前台服务与 Compose 网络设置保存。Android 四 ABI 均打包，32 位没有实机。

独立审查发现并修复 InvalidMessage 未映射旧 JSONException、i64 targetMilli 缩窄回绕两项回归；真实绑定复验 12 个非法输入拒绝和 6 个合法边界往返。UniFFI 绑定使用 JNA Cleaner 兼容 API26。新 UI 用不可变 peer 快照防止 StateFlow 漏更新。

三端均保留数据覆盖安装，原配对自动恢复。全新版实际方向验收：Mac 30秒输入→phone 534样本仅8→3→8、iPad仅32→5→32；phone系统录音→iPad仅32→5→32、Mac QQ音乐降低并恢复；iPad VoiceMemos33秒→phone534样本仅8→3→8、Mac QQ音乐降低并恢复。三轮Mac分别556/555/551样本无输入错误，GUI各只有一个输出IO周期。phone手动接管只有8→3→6，Reader结束后约19秒仍保持6。iPad UI采样约4–5秒，不能排除该间隔内瞬时变化。

Mac重开时phone保持同PID，断开触发广告恢复后以原密钥重新认证；无需重启phone。先前旧手机广告不可见的具体系统原因未被证明。Compose实际配对覆盖无自发现、取消清码、发现iPad、错码拒绝和正确码激活；只重建Android–iPad一条关系，Mac关系保留，最终各端各两条唯一关系。

## 最终现场与证据

手机媒体恢复3/15、LAN+OR、自动协同和前台服务开启；iPad实际32%、自动开启、本机未录音；Mac两台可协同且无本机输入。只清理本轮测试录音，原录音保留。独立iPad runner已退出并仅卸载runner，采样与日志监听停止。

详见[验收记录](../../docs/validation.md)。本机原始证据在 `local/RustMigration/` 与 `local/AndroidValidation/`；迁移前源、补丁及互操作基线在 `local/RustMigration/baseline/`，应用快照在其中 `apps.noindex/`，避免成为另一份索引安装。最终Android截图为 `kotlin-final-home.png`、`kotlin-final-devices.png`，iPad状态为 `ipad-final-main.txt`、`ipad-final-details.txt`。

未覆盖长期锁屏/OEM回收、Android双真机、双方Wi-Fi拓扑、32位硬件和任意录音应用。iPad私有接口及既有短暂后台心跳不可读仍是已知边界。没有未完成的当前验收动作。

## 追加锁屏与后台实机验收（用户接受结果，停止补验）

用户在419a24c提交后要求补锁屏、后台与双Android实机；明确本轮两台Android和iPad验锁屏，Mac只验后台，不锁工作Mac。新Android b45097d7为24069RA21C、API36，原媒体40/150且未装声邻；旧Huawei HYJ4C19524006587为API28、原媒体3/15。保留全部已有关系与偏好，新增双Android关系，结束恢复音量。不得以强制Doze/停服务替代正常锁屏，不更改电池优化或系统网络。

android_app继续拥有两台Android安装、配对、录音及音量证据，计划每端Home后台和真正锁屏至少5分钟后接收另一端实际录音，源录音期间也锁屏至少30秒。apple_peer_integration拥有iPad与独立runner，先准备后台/锁屏可操作入口，未经统一通知不主动录音。root拥有Mac后台与整体音频时段协调、证据收口。所有原始证据写local/BackgroundValidation，明确USB供电对自然深休眠的限制；遇失败保留现场并修复/复验，不以构建通过替代。

2026-10-16恢复：中断时Android诊断APK覆盖尚未启动，新机package stopped=true，现无录音/排程；两Android均醒且未锁。Huawei仍测试8（原3），新机现30/150，与昨晚原40不同且无产品恢复快照，不擅自覆回40，按本轮可信基线30恢复。iPad昨晚runner已正常到期，目前屏幕亮、无需密码；继续核对音量和录音。root停止跨夜遗留Mac日志监听，30分钟状态/窗口采样已自然结束。

已证实的新增结果：双Android Home后台双向均降复；Mac无窗口/非前台仍响应Huawei，只有单次输出IO起止；iPad明确Settings前台、声邻state3时420个样本32%→5%→原值通过。新Android锁屏>5分钟接收失败（音量40不变），源Huawei同轮Mac/iPad正常收到；新机FGS/PID未死、网络仍有，锁后peers.enc停写，用户解锁后恢复。已增加只读service/transport诊断与tick长间隔统计，尚未认定根因或修复。iPadPower HID未实际锁定，锁屏5分钟尚未开始，不计通过。

Mac既有7条心跳暂不可读未定位：随后8分钟生产Swift解码条件8916次读取均成功、最大age1.867秒，同窗3128GUI状态无inputError；不放宽阈值或凭猜测改代码。证据local/BackgroundValidation/heartbeat-audit。

2026-10-16上午追加证据：新机仅Wi-Fi链路的90秒锁屏诊断定位到HyperOS冻结UID。系统确认前台服务存在，但Greeze在屏灭后冻结UID10307，cgroup frozen=1并销毁TCP；这不证明FGS配置缺失，尚未更改厂商电池策略，也不把当前未知策略称为默认。等用户再次解锁后读取实际策略，必要时做单变量配置实验；原配置失败保留。

iPad以系统安全状态passcodeRequired=true及背光off确认09:45:39已锁定；09:50:55–09:51:27 Mac实际输入后，仍锁定且声邻state3的系统音量0.31514084→0.05→0.31514084，锁屏接收降复通过。Darwin锁定字段有延迟，起点不依赖它；最终完整样本由Apple owner汇总。源录音锁屏仍待验。

新机实际系统策略已读到“Battery saver (recommended)”。用户明确选择保持当前省电设置并记录限制，因此不做No restrictions对照、不改变电池优化，也不宣称任何后台配置可解决该机问题；其余已授权验收继续。

用户最终要求“不必继续验证，收尾，认为算通过”。据此停止所有补验，不再请求解锁或修改设置。已完成项与HyperOS实测失败写入docs/validation.md；Huawei锁屏接收、各移动端作为锁屏录音源未完成，不伪记为通过。Android本轮只增加只读诊断，最终单元测试/构建/lint已通过；不再扩大代码范围。iPad独立runner已退出并卸载，正式App、原配对和原1条录音保留，最后只读音量0.31514084。

最终收尾：Android采样/排程/logcat均停止，两端无录音；Huawei3/15、新机30/150，三项临时撤销的蓝牙权限恢复。电池/scope/配对不变。Huawei锁屏下留存两条本轮测试录音，路径见验收记录，不再请求解锁。全部本轮必需清理已完成，剩余未测项按用户决定关闭；仅提交两处Android诊断、验收记录与本任务包，其他安装任务改动留在工作区。

## 0.2 beta.3 发布（进行中）

用户授权 push & release，Android 交付 ARM APK。沿用预发布序列 v0.2.0-beta.3，Android 为0.2.0-beta.3 (2)，Apple为0.2.0 (7)。Android owner负责独立持久发布签名、仅arm64/armv7的release APK与产物检查；Apple owner负责隔离已提交源码的Mac开发签名DMG和iPad无签名IPA；root负责README/安装说明、源提交、推送和Release。签名材料不提交，已有不同签名开发安装不自动卸载。

继续保留其他任务的未提交安装脚本与文档改动，不能带入tag或二进制。发布只做打包与签名/架构/隐私内容/校验值检查，不恢复已停止的硬件验收。发布完成条件为main正常快进推送、tag明确指向已提交源、三个安装包及SHA256SUMS上传并核对远端内容；HyperOS锁屏限制随Release说明。
