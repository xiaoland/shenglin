# 声邻共同核心

`shenglin_core` 是三端协议和协同规则的唯一实现。Swift/Kotlin 通过 UniFFI 生成绑定调用它；网络、蓝牙回调、录音观察、实际音量操作和持久化仍由原生应用负责。核心不创建线程、计时器或网络连接，所有期限判断都使用调用方传入的时间。

配对继续调用 `NativePAKE/NativePAKE.c` 和仓库锁定版本的 BoringSSL。角色标识、v3/v4 transcript、HMAC/HKDF、wire 字段及旧关系密钥保持兼容。`RustPairingInitiator`、`RustPairingResponder` 和 `DemandLedger` 的内部可变状态由互斥锁保护；单个 PAKE context 仍只消费一次。

`DemandLedger` 保存每个来源的修订号、租约期限和手动接管标志。`load_snapshot` 原样加载，适合 Swift 值语义薄包装；`restore` 用当前时间处理过期，适合应用启动。未知录音状态推进修订号，但不续租也不清除仍有效需求。停止响应保留修订号，防止旧包重新触发。

`local_update` 保留 Android 原有的观察状态组合规则；它不是强制三端采用相同观察政策的接口。Apple 原生端仍从同一次观察快照确定 `known`/`quiet` 后交给 Rust 签名，尤其不改变 iPad 在空间条件不满足时的未知状态语义。

`LinkProof` 只处理已签名消息的验证与有效期。ACK 路径要求匹配待确认的修订号、quiet 和未过期请求；旧 iPad 接收有效 update 的路径保持兼容。原生调用方仍必须检查连接及回调代次，不能将另一个连接的晚到回调交给当前证据对象。

## 构建与验证

在仓库根目录运行 `scripts/build-rust-core.sh macos|ios|both|android|all|test`。脚本固定 Cargo 缓存和产物在仓库的 `local/`（本项目位于 Work SSD），使用锁文件，先生成绑定再构建应用使用的无 CLI feature 库。`ios` 当前仅指 arm64 真机；脚本不构建 iOS 模拟器。

`android` 保留原应用的 arm64-v8a、armeabi-v7a、x86、x86_64 四种 ABI；`android-libs` 只重建这些原生库，适用于绑定接口不变的打包修正，不会重生成绑定或触及 Apple 产物。构建前需安装对应 Rust target：`aarch64-linux-android`、`armv7-linux-androideabi`、`i686-linux-android`、`x86_64-linux-android`。

生成的 Swift 源码、头文件与 module map 位于 `local/rust-bindings/swift`，Kotlin 源码位于 `local/rust-bindings/kotlin`。原生库位于 `local/rust-target/<target>/release`。这些都是可重建产物，不提交到版本库。Android 默认使用 `/Volumes/WorkSSD/Android/sdk/ndk/30.0.14904198`，可用 `ANDROID_NDK_HOME` 指定其他已安装的 NDK。

`tests/fixtures/legacy-vectors.json` 来自迁移前真实 Swift 实现。兼容测试覆盖其签名和 Unicode 名称、UInt64 高位、unknown/手动接管/租约恢复、配对双方成功与拒绝，以及链路 ACK 的重放和过期。三端安装、已有关系恢复和真实音量验收由仓库的集成流程完成，Rust 单测不能替代这些检查。
