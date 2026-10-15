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
