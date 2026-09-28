# 单个虚拟麦克风的逐应用输入控制：技术支持材料

这是一份历史单设备路线的技术支持草稿，尚未向 Apple 发送。用户随后改为按需分配专用设备，本请求暂不推进；其源码快照保留在本地 `local/AppleSupport/2026-09-27/nearby-coreaudio-repro.zip`，以下路径描述的是该快照。它询问受支持的实现方式，不将当前观察认定为系统缺陷。材料仅包含输入隔离问题及其复现条件。

## 请求确认的问题

我们正在开发一个 macOS 音频控制应用。产品只发布一个虚拟输入设备，用户让多个第三方应用选择该设备，再从控制应用分别静音其中任意一个。目标应用不需要修改代码，其余应用应继续收到完整输入；静音不应停止目标应用的 I/O。

使用 Audio Server Driver Plug-in 时，输入回调带有客户端标识。我们的实现按客户端 PID 在 `kAudioServerPlugInIOOperationProcessInput` 对样本清零，但两个独立 AUHAL 客户端都收到受影响的数据。反之，其中一个客户端调用 `kAudioHardwarePropertyProcessInputMute` 能只静音自身。

请确认：

1. 单个 AudioDevice 的输入能否在 Audio Server Driver Plug-in 中按客户端独立处理？如果可以，应使用哪个 I/O 阶段和缓冲约定，如何避免结果被其他客户端复用？
2. 如果驱动输入回调不能提供此隔离，是否有受支持的接口，让独立控制应用在获得用户授权后静音另一个进程的输入，而不需要目标应用配合？
3. 如果该能力需要特殊 entitlement，是否对第三方开发者开放申请？如果不存在受支持的入口，请确认平台限制，以便我们据此处理产品需求。

## 复现环境与实现

实测系统为 Apple Silicon、macOS 15.4.1（24E263），构建工具为 Xcode 26.2。SDK 版本不代表测试系统版本；尚未在其他 macOS 版本重测。

驱动使用 libASPL 3.1.2，固定提交 `47f688ed6bb637ab8b7f4b36864734b2b1f69b6b`。发布一个 48 kHz、双声道 Float32 输入设备，UID 为 `local.nearbyaudio.virtual-microphone`，不发布输出流。

控制进程每 20 ms 经自定义 `NAMP` 属性送入 960 帧常量 0.25，`NAMM` 属性承载目标 PID 和静音值。`Driver/Driver.cpp` 的 `Microphone::OnProcessClientInput` 按 PID 清零；libASPL 将该方法接到 `kAudioServerPlugInIOOperationProcessInput`。

`experiments/VirtualMicrophoneProbe.cpp` 使用 AUHAL 读取设备。`scripts/test-driver-isolation.py` 构建两个不同 bundle ID 的应用，检查两者选择相同 AudioDeviceID，并统计有效样本、非零样本和渲染错误。测试仅使用合成输入，不采集物理麦克风，也不需要 Nearby GUI、iPad、配对密钥或网络控制服务。

## 独立复现步骤

附件包含驱动、测试、构建脚本和所需许可证，不包含已签名二进制。需要 Xcode Command Line Tools、CMake、Python 3 和 Git；首次构建从 GitHub 下载固定版本 libASPL。请在无实时音频任务的测试 Mac 上执行，安装及卸载会重启系统音频服务。

1. 解压附件，在其根目录执行以下命令。将签名身份替换为测试机上的开发签名身份。

   ```sh
   export NEARBY_AUDIO_SIGN_IDENTITY='Apple Development: YOUR SIGNING IDENTITY'
   sh scripts/build-driver.sh
   ```

2. 确认 `/Library/Audio/Plug-Ins/HAL/NearbyAudioDriver.driver` 尚不存在，避免覆盖已安装版本。安装本次构建：

   ```sh
   sudo ditto local/DriverBuild/NearbyAudioDriver.driver /Library/Audio/Plug-Ins/HAL/NearbyAudioDriver.driver
   sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/NearbyAudioDriver.driver
   sudo chmod -R go-w /Library/Audio/Plug-Ins/HAL/NearbyAudioDriver.driver
   sudo killall coreaudiod
   ```

3. 等待设备出现，运行 `python3 scripts/test-driver-isolation.py`。默认输入设备无需更改。输出文件为 `local/HALIsolationTests/results.json`。成功退出码为 0；当前观察到的退出码为 1，包含四项隔离失败。测试会结束自有进程并清除它设置的驱动静音项。
4. 完成后卸载本次安装的驱动：

   ```sh
   sudo rm -rf /Library/Audio/Plug-Ins/HAL/NearbyAudioDriver.driver
   sudo killall coreaudiod
   ```

## 期望与实测

每项统计的顺序为“非零样本 / 总样本”；所有阶段均无渲染错误。附件 `evidence/results.json` 是 2026-09-27 已完成的真机测试结果，不是打包时重新运行的结果。

| 阶段 | A 实测 | B 实测 | 期望 |
| --- | --- | --- | --- |
| 基线 | 48128 / 48128 | 48128 / 48128 | 两端完整供音 |
| A 自行设置系统进程静音 | 0 / 48128 | 48128 / 48128 | 仅 A 静音，通过 |
| 解除系统静音 | 48128 / 48128 | 48128 / 48128 | 两端恢复，通过 |
| 驱动静音 A | 19968 / 49152 | 19552 / 48128 | A 应全零，B 应完整供音；均失败 |
| 驱动静音 B | 29184 / 49152 | 28576 / 48128 | B 应全零，A 应完整供音；均失败 |
| 停止供音 | 0 / 49152 | 0 / 48128 | 两端归零，通过 |

解除每次驱动静音后，两端均恢复为全部非零。测试窗口内样本数略有不同，因为两端独立启动和统计。

此前的诊断原型确认了两个不同 bundle ID 和 PID 都到达驱动回调，目标 PID 命中清零逻辑。按 PID 写入不同标记样本时，两个客户端仍读到相同的标记组合。这里没有附带这些改动较多的诊断原型；附件复现聚焦正式驱动中仍然失败的最小链路。

## 已查阅的公开接口

`kAudioHardwarePropertyProcessInputMute` 控制调用进程自身，不能直接指定目标 PID。Apple 的 [WWDC23 示例](https://developer.apple.com/videos/play/wwdc2023/10233/)也将它用于本应用的输入静音。

[`AVAudioApplication.setInputMuteStateChangeHandler`](https://developer.apple.com/documentation/avfaudio/avaudioapplication/setinputmutestatechangehandler(_:)) 要求 macOS 应用处理自身静音逻辑。因此，收到静音状态通知不能等同于 HAL 已替未适配应用清零。

[AudioDriverKit 示例](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver)说明虚拟设备应采用 Audio Server Driver Plug-in。其设备级缓冲和回调未提供目标应用标识，尚未发现迁移能解决本问题的依据。

本地另外观察到一个私有 AVAudioApplication 代理入口，但现有开发签名因缺少授权无法创建代理；这不属于附件依赖，也不作为产品方案。本请求重点是确认受支持的接口和约束，而非要求解释 Apple 私有实现。

Apple 的[代码级支持说明](https://developer.apple.com/support/technical/)要求英文提交，并建议准备聚焦的复现项目。此文是中文审核稿；对外提交时应翻译正文，并按支持渠道要求提供附件。私有权限尚未找到公开申请渠道，不能承诺申请后即可实现产品目标。
