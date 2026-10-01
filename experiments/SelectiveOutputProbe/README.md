# 原生进程增益重放实验

本实验只接管明确指定的 `/usr/bin/afplay` 进程，在默认输出设备上创建 `CATapMutedWhenTapped` Tap，将取得的音频乘以指定增益并重放。它不读取麦克风、不保存 PCM、不写系统音量、不修改默认路由，也不接入正式应用。

先分别用两个 `afplay` 进程播放幅度 0.002 的 440 Hz（A）和 660 Hz（B）合成音，再构建只针对 B 的实验 App：

```sh
python3 experiments/SelectiveOutputProbe/build.py B的PID 60 0.2
```

构建器验证签名和增益算法；使用本机已有 Apple Development 签名，可用 `SHENGLIN_SIGN_IDENTITY` 覆盖。通过 Finder 打开 `local/SelectiveOutputProbe/SelectiveOutputProbe.app`，正常处理系统授权。日志为同目录 `relay.jsonl`，每次启动覆盖。时长限制从音频成功启动开始计算，不包括等待系统授权的时间。只允许没有物理输入流的默认输出设备，以及双声道交错 Float32；格式不符或默认设备变化即结束。这些限制只服务于能力验证，不是正式兼容范围。

独立测量复用 `experiments/BrowserAudioProbe/SpectrumMeter.m`：从 `ready` 日志取得重放进程 PID，构建并启动测量 App。目标是重放进程，不是原始 B。测量前保存旧测量记录，结束后将 JSONL 和 stderr 复制到本实验目录。

2026-10-01，macOS 15.4.1 内置扬声器路径上，60 秒运行得到 5624 次回调、0 个无效缓冲，正常停止。默认输出一直为 `BuiltInSpeakerDevice`，系统音量前后均为 0.5625。独立测量的 21 个稳定半秒窗口中，B 幅度中位数为 0.000399772（相对名义输入增益 0.199886），A 为 0.000000016。测量器正常退出。

这是重放幅度和正常清理证据，不能证明扬声器端未同时播放 B 原声。Process Tap 的采集边界与硬件静音边界不同，不能将多个 Tap 的读数相加冒充最终混音。正式启用前仍须通过受控听测或经过确认的最终输出测量验证原声抑制、保护 A、异常退出恢复；延迟、设备切换、格式兼容和长期稳定性进入实现验收。

运行 `python3 experiments/SelectiveOutputProbe/analyze.py` 检查本机记录。日志不包含音频内容，原始结果保存在忽略目录 `local/SelectiveOutputProbe/`。
