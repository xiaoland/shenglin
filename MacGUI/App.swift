import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class NearbyAudioAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    func applicationDidFinishLaunching(_ notification: Notification) { model.start() }
}

@main @MainActor struct NearbyAudioMacApp: App {
    @NSApplicationDelegateAdaptor(NearbyAudioAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            QuickPanel(model: delegate.model)
                .frame(width: 340)
                .onAppear { delegate.model.refreshSources() }
        } label: {
            MenuBarStatus(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("Nearby Audio", id: "main") {
            MainPanel(model: delegate.model)
                .frame(minWidth: 500, minHeight: 300)
                .onAppear { delegate.model.refreshSources() }
        }
        .defaultSize(width: 560, height: 340)

        Settings {
            TabView {
                ControlPanel(model: delegate.model, page: .devices)
                    .frame(width: 620, height: 210)
                    .tabItem { Label("设备", systemImage: "ipad.and.iphone") }
                ControlPanel(model: delegate.model, page: .apps)
                    .frame(width: 620, height: 320)
                    .tabItem { Label("应用", systemImage: "app.badge") }
                ControlPanel(model: delegate.model, page: .coordination)
                    .frame(width: 620, height: 290)
                    .tabItem { Label("协同", systemImage: "slider.horizontal.3") }
            }
            .onAppear { delegate.model.refreshSources() }
        }

        Window("诊断", id: "diagnostics") {
            ControlPanel(model: delegate.model, page: .diagnostics)
                .frame(minWidth: 500, minHeight: 200)
        }
        .defaultSize(width: 560, height: 240)
    }
}

private struct MenuBarStatus: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Image(systemName: model.iconName)
            .accessibilityLabel("Nearby Audio：\(model.connection)")
    }
}

private struct QuickPanel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Nearby Audio").font(.headline)
                Spacer()
                Button("打开主窗口…") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            Text(model.ipadStatus).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if model.macPeerCount > 0 {
                Text(model.macStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Toggle("自动协同", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
            Text("参与协同的录音进程：\(model.inputCount) 个 · \(model.spaceAllowed ? "空间条件已满足" : "等待空间条件")")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.inputError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            let microphones = model.sources.filter { $0.microphoneName != nil }
            if !microphones.isEmpty {
                Divider()
                Text("专用麦克风").font(.headline)
                ForEach(microphones) { source in
                    HStack {
                        Toggle("静音 \(source.name)", isOn: Binding(
                            get: { source.isMuted }, set: { _ in model.toggleMute(source) }))
                        if source.microphoneInUse {
                            Image(systemName: "mic.fill").accessibilityLabel("正在使用")
                        }
                        Button("标记现场（可选）") { model.markForensics(source) }
                            .buttonStyle(.link)
                    }
                }
            }
            if !model.errorMessage.isEmpty {
                Text(model.errorMessage).font(.caption).foregroundStyle(.red)
            }
            if !model.diagnosticMessage.isEmpty {
                Text(model.diagnosticMessage).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text(model.lastAction).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { model.quit() }
            }
        }
        .padding(14)
    }
}

private enum SettingsPage {
    case devices, apps, coordination, diagnostics
}

private struct MainPanel: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle().fill(model.isConnected ? .green : .orange).frame(width: 8, height: 8)
                        Text(model.ipadStatus)
                    }
                    if model.macPeerCount > 0 {
                        Text(model.macStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Toggle("自动协同", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                    Text("参与协同：\(model.inputCount) 个录音进程")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("专用麦克风") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.sources.filter { $0.microphoneName != nil }) { source in
                        HStack {
                            Toggle("静音 \(source.name)", isOn: Binding(
                                get: { source.isMuted }, set: { _ in model.toggleMute(source) }))
                            if source.microphoneInUse {
                                Image(systemName: "mic.fill").accessibilityLabel("正在使用")
                            }
                        }
                    }
                    if !model.sources.contains(where: { $0.microphoneName != nil }) {
                        Text("尚未添加专用麦克风").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.sourceActivityUnknown {
                Text("输入使用状态未知；暂不能更换或移除麦克风")
                    .font(.caption).foregroundStyle(.red)
            }
            if !model.errorMessage.isEmpty {
                Text(model.errorMessage).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            HStack {
                Button("设置…") { openSettings() }
                Button("诊断…") { openWindow(id: "diagnostics") }
                Spacer()
                if model.lastAction != "尚无音量操作" {
                    Text(model.lastAction).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }
}

private struct ControlPanel: View {

    @ObservedObject var model: AppModel
    @State private var showingAppPicker = false
    @State private var addingMicrophone = false
    let page: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if page == .devices {
                        HStack(spacing: 8) {
                            Circle().fill(model.isConnected ? .green : .orange)
                                .frame(width: 8, height: 8)
                            Text(model.ipadStatus).font(.subheadline)
                            Spacer()
                            Button(model.paired ? "更换 iPad 配对" : "与 iPad 配对") { model.beginPairing() }
                                .buttonStyle(.link)
                        }

                        if model.showPairing {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(model.paired ? "更换 iPad 配对" : "与 iPad 配对").font(.headline)
                                Text("在 iPad App 点按“开始 2 分钟配对”，然后选择下方的 iPad。")
                                    .font(.caption).foregroundStyle(.secondary)
                                if model.paired {
                                    Text("此 Mac 会切换到新 iPad；原 iPad 上的其他 Mac 配对不受影响。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(model.pairingStatus).font(.caption)
                                if model.pairingAwaitingCode {
                                    Text(model.pairingPadName).font(.subheadline)
                                    TextField("iPad 上的 6 位验证码", text: $model.pairingCodeInput)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit { model.submitPairingCode(model.pairingCodeInput) }
                                    HStack {
                                        Button("验证并配对") { model.submitPairingCode(model.pairingCodeInput) }
                                            .disabled(model.pairingCodeInput.count != 6)
                                        Button("取消") { model.cancelPairing() }
                                    }
                                } else {
                                    ForEach(model.nearbyPads) { pad in
                                        Button(pad.name) { model.choosePad(pad.id) }
                                            .buttonStyle(.bordered)
                                    }
                                    if model.nearbyPads.isEmpty && model.pairingActive {
                                        Text("正在查找附近的 iPad…").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !model.pairingActive {
                                        Button("重新查找") { model.beginPairing() }
                                    }
                                    Button("取消") { model.cancelPairing() }.buttonStyle(.link)
                                }
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.macPeerCount == 0 ? "其他 Mac：未配对" : "其他 Mac")
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(model.macPeerDisplays) { peer in
                                Text("\(peer.name) · \(peer.authenticated ? "Wi-Fi 已认证" : "未连接") · \(peer.spaceAllowed ? (peer.authenticated ? "允许协同" : "短断连宽限") : "等待空间条件")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("显示配对码") { model.offerMacPairing() }
                                Button("查找另一台 Mac") { model.browseMacPairing() }
                                if model.macPairCode != nil || model.macPairBrowsing {
                                    Button("取消") { model.cancelMacPairing() }.buttonStyle(.link)
                                }
                            }
                            if let code = model.macPairCode {
                                Text(code).font(.title2.monospacedDigit()).textSelection(.enabled)
                            }
                            if model.macPairBrowsing {
                                ForEach(model.nearbyMacs) { mac in
                                    Button(mac.name) { model.chooseMac(mac.id) }.buttonStyle(.bordered)
                                }
                                if model.macPairAwaitingCode {
                                    TextField("另一台 Mac 的 6 位配对码", text: $model.macPairCodeInput)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit { model.submitMacPairCode() }
                                    Button("验证并配对") { model.submitMacPairCode() }
                                        .disabled(model.macPairCodeInput.count != 6)
                                }
                            }
                            if !model.macPairStatus.isEmpty {
                                Text(model.macPairStatus).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if page == .coordination {
                        Picker("空间条件", selection: Binding(get: { model.spaceMode }, set: model.setSpaceMode)) {
                            Text("蓝牙或 Wi-Fi").tag(SpaceMode.nearbyOrWiFi)
                            Text("蓝牙且 Wi-Fi").tag(SpaceMode.nearbyAndWiFi)
                        }
                        .pickerStyle(.segmented)
                        Text(model.spaceStatus).font(.caption).foregroundStyle(.secondary)
                        if model.macPeerCount > 0 && model.spaceMode == .nearbyAndWiFi {
                            Text("Mac 直连目前只有 Wi-Fi 认证；“蓝牙且 Wi-Fi”不会放行 Mac↔Mac。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let inputError = model.inputError {
                            Text("输入状态未知，已停止降音量请求：\(inputError)")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }

                    if page == .apps {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("排除应用").font(.headline)
                                Spacer()
                                Button("刷新") { model.refreshSources() }
                                    .buttonStyle(.link)
                                Button("添加排除…") {
                                    addingMicrophone = false
                                    showingAppPicker = true
                                }
                                    .buttonStyle(.link)
                            }
                            DisclosureGroup("应用列表 · 已排除 \(model.sources.filter(\.isExcluded).count) 个") {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(model.sources) { source in
                                        Toggle(isOn: Binding(get: { source.isExcluded },
                                                             set: { _ in model.toggleExclusion(source) })) {
                                            HStack {
                                                Text(source.name)
                                                if source.isActive {
                                                    Text("正在录音")
                                                        .font(.caption2).foregroundStyle(.orange)
                                                }
                                            }
                                        }
                                        .help(source.selector)
                                        .accessibilityLabel("排除 \(source.name)")
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("专用麦克风").font(.headline)
                                Spacer()
                                if !model.virtualMicrophoneAvailable {
                                    Button("安装驱动…") { model.installDriver() }
                                        .buttonStyle(.link).disabled(model.driverInstalling)
                                }
                                if model.virtualMicrophoneAvailable {
                                    Button("添加应用…") {
                                        addingMicrophone = true
                                        showingAppPicker = true
                                    }
                                    .buttonStyle(.link)
                                    .help("为需要独立静音的应用创建设备；其他应用若选择同一设备，也会一起静音。")
                                }
                            }
                            if !model.driverInstallStatus.isEmpty {
                                Text(model.driverInstallStatus).font(.caption).foregroundStyle(.secondary)
                            }
                            if model.virtualMicrophoneAvailable {
                                DisclosureGroup("驱动维护") {
                                    Button("重新安装驱动…") { model.installDriver() }
                                        .buttonStyle(.link).disabled(model.driverInstalling)
                                }
                            }
                            if model.virtualMicrophoneAvailable {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(model.sources.filter { $0.microphoneName != nil }) { source in
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Toggle("静音 \(source.name)", isOn: Binding(
                                                    get: { source.isMuted }, set: { _ in model.toggleMute(source) }))
                                                Button("移除") { model.removeMicrophone(source) }
                                                    .buttonStyle(.link)
                                                    .disabled(model.sourceActivityUnknown || source.microphoneInUse)
                                            }
                                            DisclosureGroup("设备设置") {
                                                Text("\(source.microphoneName ?? "") · \(model.sourceActivityUnknown ? "使用状态未知" : (source.microphoneInUse ? "正在使用" : "等待应用选择"))")
                                                    .font(.caption2).foregroundStyle(.secondary)
                                                if source.isExcluded {
                                                    Text("已排除音量协同").font(.caption2).foregroundStyle(.orange)
                                                }
                                                HStack {
                                                    Text(model.microphoneSourceDescription(for: source.selector))
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                    Spacer()
                                                    Button("更换上游…") { model.changeMicrophoneSource(source) }
                                                        .buttonStyle(.link).disabled(model.sourceActivityUnknown || source.microphoneInUse)
                                                }
                                                HStack {
                                                    Text("快捷键：\(model.microphoneShortcuts[source.selector]?.title ?? "未设置")")
                                                        .font(.caption2)
                                                    Spacer()
                                                    Button(model.recordingShortcutFor == source.selector ? "取消" : "录入…") {
                                                        if model.recordingShortcutFor == source.selector { model.cancelShortcutRecording() }
                                                        else { model.recordShortcut(for: source) }
                                                    }.buttonStyle(.link)
                                                    if model.microphoneShortcuts[source.selector] != nil {
                                                        Button("清除") { model.clearShortcut(for: source.selector) }.buttonStyle(.link)
                                                    }
                                                }
                                                if let warning = model.microphoneShortcuts[source.selector]?.systemShortcutWarning {
                                                    Text(warning).font(.caption2).foregroundStyle(.orange)
                                                }
                                            }
                                        }
                                    }
                                    if !model.sources.contains(where: { $0.microphoneName != nil }) {
                                        Text("尚未添加专用设备").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if !model.shortcutMessage.isEmpty {
                                    Text(model.shortcutMessage).font(.caption2).foregroundStyle(.orange)
                                }
                                Toggle("让前台应用也响应同一快捷键", isOn: Binding(
                                    get: { model.sharedShortcutEnabled }, set: model.setSharedShortcutEnabled))
                                    .font(.caption)
                                    .help("开启后，系统会向 Nearby 交付所有按键按下事件；Nearby 仅匹配已配置组合，不记录其他按键。")
                                if model.sharedShortcutEnabled && !model.sharedShortcutActive {
                                    Text(model.sharedShortcutStatus)
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if !model.microphoneShortcuts.isEmpty {
                                        Button("重新检查授权") { model.retrySharedShortcutAuthorization() }
                                            .buttonStyle(.link)
                                    }
                                }
                            }
                        }
                    }

                    if page == .diagnostics {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.sources.filter { $0.microphoneName != nil }) { source in
                                HStack {
                                    Text("\(source.name)：\(model.forensicDescription(for: source.selector))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("标记现场") { model.markForensics(source) }.buttonStyle(.link)
                                }
                                if let warning = model.forensicWarning(for: source.selector) {
                                    Text(warning).font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            HStack {
                                Button("取证目录…") { model.chooseForensicLocation() }.buttonStyle(.link)
                                Menu("上限 \(model.forensicLimitGB) GB") {
                                    ForEach([10, 40, 100, 250, 500], id: \.self) { amount in
                                        Button("\(amount) GB") { model.setForensicLimitGB(amount) }
                                    }
                                }
                                Spacer()
                                Button("导出诊断包…") { model.exportForensics() }.buttonStyle(.link)
                            }
                            .help(model.forensicLocation)
                            Text("音频持续保存在本机，按容量上限淘汰。")
                                .font(.caption2).foregroundStyle(.secondary)
                            if !model.diagnosticMessage.isEmpty {
                                Text(model.diagnosticMessage).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if page == .coordination {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(model.pairedPadName) 响应 \(model.localMacName) 安静请求时的音量上限").font(.headline)
                                Spacer()
                                Text(model.targetKnown ? "\(Int((model.target * 100).rounded()))%" : "连接后读取")
                                    .monospacedDigit()
                            }
                            Slider(value: $model.target, in: 0...0.5, step: 0.05,
                                   onEditingChanged: model.targetEditChanged)
                                .disabled(!model.targetKnown || !model.paired)
                                .accessibilityLabel("\(model.pairedPadName) 响应 \(model.localMacName) 安静请求时的媒体音量上限")
                                .help("录音期间更改目标将在下次录音开始时生效。")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(model.localMacName) 响应其他设备安静请求时的音量上限").font(.headline)
                                Spacer()
                                Text("\(Int((model.macTarget * 100).rounded()))%")
                                    .monospacedDigit()
                            }
                            Slider(value: $model.macTarget, in: 0...0.5, step: 0.05,
                                   onEditingChanged: model.macTargetEditChanged)
                                .accessibilityLabel("\(model.localMacName) 响应其他设备安静请求时的媒体音量上限")
                            Text("iPad → Mac 自动触发尚未验证")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Toggle("登录后自动启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled))
                    }

                    if model.sourceActivityUnknown && page == .apps {
                        Text("输入使用状态未知；暂不能更换或移除麦克风")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if !model.errorMessage.isEmpty {
                        Text(model.errorMessage).font(.caption).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .fileImporter(isPresented: $showingAppPicker, allowedContentTypes: [.applicationBundle]) { result in
            if case .success(let url) = result { model.addApp(url, microphone: addingMicrophone) }
            else if case .failure(let error) = result { model.errorMessage = "无法选择应用：\(error.localizedDescription)" }
        }
        .onDisappear { if page == .apps { model.cancelShortcutRecording() } }
        .padding(16)
    }
}
