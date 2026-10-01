# 网页音频端点与增益实验

本实验验证两个网页能否由当前 Mac Process Tap 分别选择，以及扩展能否在浏览器内执行逐页增益。0.2.1 增加用户启用后的 ChatGPT 输入轨道状态观察，已完成下述真实 Voice 验证；它不是正式浏览器接入，没有连接 Native Messaging 或参与跨设备协同。

在仓库根目录执行：

```sh
mkdir -p local/BrowserAudioProbe
swiftc experiments/BrowserAudioProbe/Snapshot.swift -o local/BrowserAudioProbe/snapshot
python3 -m http.server 18763 --bind 127.0.0.1 --directory experiments/BrowserAudioProbe
```

在普通可见的 Helium 窗口分别打开 `http://127.0.0.1:18763/?source=A` 和 `http://127.0.0.1:18763/?source=B`。两页分别生成 440/660 Hz、幅度 0.002 的合成音，用户点击后开始，180 秒自动停止。按 A 单独、A+B、B 单独、全部停止采样，每阶段执行 `local/BrowserAudioProbe/snapshot 阶段名`。采样器只读取进程、设备和硬件流元数据，不录音。页面显示 running 还不够，必须同时确认浏览器的播放状态与 HAL 活动输出。

2026-10-01 在 Helium 0.15.7.1 的同站点双页实验中，前三阶段均为进程对象 101、PID 82245、设备 78、唯一硬件流 79；每阶段八次采样一致，全部停止后活动输出归零。其他 Helium 进程对象未形成独立输出。结合 CATapDescription 仅提供进程、设备和硬件流选择，这个反例排除了当前浏览器及输出路径上的“只补充网页元数据，再用当前 Process Tap 分别调音”。编号属于本次运行，不是稳定标识。原始 JSONL 位于 `local/BrowserAudioProbe/visible-*.jsonl`。

运行 `python3 experiments/BrowserAudioProbe/analyze.py` 可检查这四组样本的阶段内一致性、端点归属和停止状态；它依赖实际播放状态已由浏览器 UI 独立确认，不能单独排除页面没有发声等实验错误。

首次使用自动化后台标签页时，页面显示 running，但 HAL 没有活动输出；该轮数据不能支持端点归属结论，已与有效样本分开保留。原生 afplay 对照确认了采样器可观察输出；普通可见窗口的网页随后产生了有效 HAL 活动。没有进一步认定后台标签页缺失输出的具体原因。

`extension/` 是最小 Manifest V3 原型，需通过浏览器的“加载已解压的扩展”加载。声明 activeTab、tabCapture、offscreen 和 scripting 权限，没有全站 host permission。增益执行器拒绝非 HTTP、非 localhost/127.0.0.1、非 18763 端口的页面。打开目标实验页后点击扩展，可选择 100% 或 20% 增益，或解除当前页接管。捕获只保留在内存中，90 秒自动释放；导航、关闭标签页也请求释放。该时限不因调整增益而延长。

弹窗显示捕获流在增益节点前后的 RMS 比例，这是浏览器内处理证据。2026-10-01 已在实际扩展中验证 B 的 20%/100% 操作、A 保持 100% 时并发接管 B，以及逐页解除。弹窗可见 JSON 转录保存在 `local/BrowserAudioProbe/extension-visible-results.json`，明确标为人工转录。并发时八次 HAL 采样仍指向同一浏览器进程输出，不能仅凭这些元数据推断增益正确。

`SpectrumMeter.m` 用不静音的 Process Tap 独立测量指定进程输出的两个频点，只保留幅度数值，不保存 PCM，不重放或改变默认设备。它需要系统音频录制权限。先以只播放实验合成音的浏览器进程为目标，并在扩展接管后重新核对实际输出进程，不能沿用旧 PID 作为稳定绑定。

构建独立 App，默认使用本机的 Apple Development 签名身份，也可通过 `SHENGLIN_SIGN_IDENTITY` 指定已有身份：

```sh
python3 experiments/BrowserAudioProbe/build-meter-app.py 浏览器音频PID 120
```

构建会验证签名并运行算法自检，但不会启动或授权。通过 Finder 正常打开生成的 `local/BrowserAudioProbe/SpectrumMeter.app`，按系统提示处理授权。App 具有独立 bundle ID、`NSAudioCaptureUsageDescription` 和主事件循环；音频启动在后台执行，日志写入同目录下的 `spectrum-app.jsonl`、`spectrum-app.stderr`，每次运行覆盖。它不申请麦克风授权，文件位于外置磁盘时还可能出现正常的磁盘访问提示。每次测试须先确认目标 PID 仍属于预期合成音源，只有已授权的实验音在该进程播放。

测量器按半秒窗口输出 440/660 Hz 幅度。先以独立 `afplay` 的已知混合合成音作正向对照，15 个有效窗口中两路中位幅度分别为 0.001999705、0.002000521，符合 0.002 的预期。随后对浏览器目标 PID 82245、进程对象 101 连续测量 120 秒，正常结束且没有无效缓冲。A 保持原播放路径，只通过扩展操作 B，结果如下。

| 阶段 | 稳定半秒窗口数 | A / 基线 | B / 基线 |
| --- | ---: | ---: | ---: |
| 原始播放 | 71 | 1.000000 | 1.000000 |
| B 降至 20% | 15 | 0.999965 | 0.199984 |
| B 恢复 100% | 28 | 0.999978 | 1.000013 |
| B 再次降至 20% | 29 | 0.999958 | 0.200012 |
| 解除 B 接管 | 60 | 0.999941 | 1.000045 |

这证明了该浏览器、默认输出路径、两页 Web Audio 合成音条件下的逐页衰减与正常解除恢复；稳定输出没有叠加一份未衰减的 B 原声。证据位于浏览器进程输出边界，不是扬声器声学测量。尚未验收切换瞬间的连续性、音质、延迟、扩展崩溃/禁用、90 秒到期、导航恢复，以及 WebRTC、iframe 或其他浏览器。

运行 `python3 experiments/BrowserAudioProbe/analyze-spectrum.py` 复核上述独立测量：它校验实际目标、正常退出、采样连续性和增益，排除每次操作前后两秒的窗口；中位增益容差为 2%，每个稳定窗口容差为 3%。`spectrum-markers.jsonl` 中的阶段时间来自扩展 UI 操作后的时间戳转录；原始结果和分析为 `spectrum-app.jsonl`、`spectrum-analysis.json`。结束时两页均已解除并停止，八次 HAL 采样确认浏览器活动输出归零。

早期裸 CLI 在 `AudioDeviceCreateIOProcIDWithBlock` 注册阶段等待 Core Audio 服务，权限检查归属 Codex，未取得有效样本。改用上述独立 App 后，TCC 日志确认主体是 `local.shenglin.experimental.spectrummeter`，实际系统音频权限请求和提示出现，随后取得有效 PCM。没有通过工具点击授权按钮、重置权限、重启音频服务或修改默认设备。由于同时补齐了应用身份、用途说明和主事件循环，不能把早期阻塞唯一归因于其中一项。栈及日志分别保存在 `meter-stall.*`、`meter-app-control.tcc-log.txt`。参数中的秒数只限制成功启动后的测量时间，不限制等待系统授权的时间。

执行 `node experiments/BrowserAudioProbe/check.mjs` 检查触发捕获的消息与目标边界；这项测试使用模拟 Chrome API，实际能力以上述独立测量为准。正式接入仍需处理逐页用户授权、输入参与识别、Mac 策略通信与故障恢复。实验结束应停止音源和测量器、关闭实验页并停止本地 HTTP 服务；扩展与测量 App 在后续验证结束后可移除。

## 输入观察实验（0.2.1）

在已加载的 ChatGPT 页面调用扩展并点击“启用输入观察／保护标记”，再由用户开启 Voice。观察器包装该页后续的 getUserMedia 调用，记录调用和失败次数、音频轨道数量、live、enabled 与 unmuted 数量；每 250 毫秒检查变化，只保存最近 80 个状态，不保存标签、设备 ID、约束或音频。记录保存在该文档的 ISOLATED world，扩展后台休眠不会丢失；终止观察保留记录供复核，刷新文档清空。十分钟后自动解除包装，也可点击结束观察；不会替用户开启或停止真实输入轨道。

开启、静音、解除静音、结束之后点击“读取观察记录”。保护标记在实验中仅用于验证“轨道静音／结束不等于结束保护”这个状态边界，不会控制 Mac 或其他页面。页面刷新会丢弃旧记录并要求重新启用。晚注入无法补获既有轨道，页面缓存原函数、iframe 或页面干预均可能导致漏报；没有观察到轨道时必须标为 unknown。页面消息可被网页伪造，这些记录仅是本页实验信号，不是系统授权的采集事实。

观察只允许 https://chatgpt.com 或本地实验页，观察记录由扩展在目标 tab 的顶层文档隔离环境中读取，返回结果带 document ID；没有新增全站 host 权限。此实验不对 ChatGPT 音频执行 tabCapture，原有调音按钮仍仅允许本地合成音页。对真实 Voice 的验证需要用户操作实际麦克风按钮，模拟轨道测试不能代替。

0.2.0 曾把观察记录放在 service worker 的 Map 中；后台闲置退出会丢失记录，该版本不能据此判断网页漏报。0.2.1 已移到文档隔离环境，并覆盖重复启用及结束后的记录保持。[Chrome 官方生命周期说明](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle) 明确指出后台全局变量会在退出后丢失。

2026-10-01 已在 Helium 的真实 ChatGPT Voice 上完成验证：页面加载后启用扩展，再启动 Voice，观察到一次调用和一条活动音频轨道；静音时 live 保持 1、enabled 变为 0，解除后 enabled 恢复 1，结束 Voice 后 live 变为 0。显式页面保护一直保留。通话已开启后才启用观察则是 unknown、tracked=0、protected=true；完整刷新后 documentId 改变，unknown、protected=false。两轮 Voice 均已结束，实验页已关闭。完整可见 JSON 转录、UI 交叉核对和实验边界位于 `tasks/application-audio-coordination/voice-input-evidence.json`。此结果支持首版使用 activeTab 后注入，不构成任意网页输入可完整观察或自动识别通话生命周期的保证。
