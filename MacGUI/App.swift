import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class ShenglinAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var mainWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        if NSApp.isActive { showMainWindow() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if mainWindow == nil { showMainWindow() }
    }
    func showMainWindow() {
        model.refreshSources()
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 280, y: 160, width: 600, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "声邻"
            window.minSize = NSSize(width: 540, height: 500)
            window.setFrameAutosaveName("ShenglinMainWindow")
            window.contentView = NSHostingView(rootView: MainPanel(model: model))
            if !window.setFrameUsingName("ShenglinMainWindow") { window.center() }
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }
}

@main @MainActor struct ShenglinMacApp: App {
    @NSApplicationDelegateAdaptor(ShenglinAppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--browser-native-host") { BrowserNativeHost.run() }
        if CommandLine.arguments.contains("--output-validation") { ApplicationOutputValidation.run() }
        if CommandLine.arguments.contains("--microphone-agent") { MicrophoneAgent.run() }
        if CommandLine.arguments.contains("--microphone-agent-stop") {
            do { try MicrophoneAgentStatus.service.unregister(); exit(0) }
            catch { fputs("无法停止后台麦克风服务：\(error)\n", stderr); exit(1) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            QuickPanel(model: delegate.model, showMainWindow: delegate.showMainWindow)
                .frame(width: 340)
                .onAppear { delegate.model.refreshSources() }
        } label: {
            MenuBarStatus(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPanel(model: delegate.model)
                .frame(width: 600, height: 650)
            .onAppear { delegate.model.refreshSources() }
        }

        Window("诊断", id: "diagnostics") {
            DiagnosticsPanel(model: delegate.model)
                .frame(minWidth: 540, minHeight: 400)
        }
        .defaultSize(width: 600, height: 550)
    }
}

private struct MenuBarStatus: View {
    @ObservedObject var model: AppModel
    private static let templateIcon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Group {
            if model.iconName == "waveform" || model.iconName == "waveform.circle.fill" {
                if let icon = Self.templateIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .overlay(alignment: .bottomTrailing) {
                            if model.inputState.localRecording {
                                Circle().fill(.primary).frame(width: 4, height: 4).offset(x: 2, y: 2)
                            }
                        }
                } else {
                    Image(systemName: model.iconName)
                }
            } else {
                Image(systemName: model.iconName)
            }
        }
        .accessibilityLabel("声邻：\(model.coordinationStatus)")
    }
}

private struct QuickPanel: View {
    @ObservedObject var model: AppModel
    let showMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("声邻").font(.headline)
                Spacer()
                Button("打开主窗口…", action: showMainWindow)
            }
            Text(model.coordinationStatus).foregroundStyle(.secondary)
            Divider()
            Toggle(isOn: Binding(get: { model.enabled }, set: model.setEnabled)) {
                Text("自动协同").frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(isOn: Binding(get: { model.localDuckingEnabled }, set: model.setLocalDuckingEnabled)) {
                Text("本机协同").frame(maxWidth: .infinity, alignment: .leading)
            }
                .disabled(!model.enabled)
                .help("保留输入应用的输出，降低其他应用；网页通过扩展逐页参与。")
            if let error = model.inputError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if model.localInputActive {
                Label("本机正在录音", systemImage: "mic.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let microphones = model.sources.filter { $0.microphoneName != nil }
            if !microphones.isEmpty {
                Divider()
                Text("专用麦克风静音").font(.caption).foregroundStyle(.secondary)
                ForEach(microphones) { source in
                    Toggle(isOn: Binding(get: { source.isMuted }, set: { _ in model.toggleMute(source) })) {
                        Text(source.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel("静音 \(source.name)")
                    .help("控制 \(source.name) 的专用麦克风静音")
                }
            }
            if !model.errorMessage.isEmpty {
                Text(model.errorMessage).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Spacer()
                Button("退出") { model.quit() }
            }
        }
        .toggleStyle(.switch)
        .padding(16)
    }
}

private struct VolumeTargetControl: View {
    let title: String
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    var relative = false

    private var sliderRange: ClosedRange<Double> { 0...(relative ? 1 : 0.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(relative ? "保留 \(Int((value * 100).rounded()))%" : "\(Int((value * 100).rounded()))%")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: sliderRange, step: 0.05, onEditingChanged: onEditingChanged)
                .labelsHidden()
                .accessibilityLabel(relative ? "\(title)的背景音量比例" : title)
                .help(relative ? "按应用自己的音量降低；保留 25% 表示降到原来的四分之一，100% 保持原音量。" : "此设备的媒体音量上限。")
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MainPanel: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @State private var showingPairing = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { model.enabled }, set: model.setEnabled)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动协同").font(.headline)
                            Text(model.coordinationStatus).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    if let error = model.inputError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.caption)
                    } else {
                        Label(model.localInputActive ? "检测到录音或通话" : "暂无录音或通话参与协同",
                              systemImage: model.localInputActive ? "mic.fill" : "mic")
                            .foregroundStyle(.secondary)
                            .help("当前有 \(model.inputCount) 个有效输入来源参与设备间协同；排除应用仍可触发本机协同。")
                    }
                }
                Section {
                    VolumeTargetControl(title: "其他设备录音时", value: $model.macTarget,
                                        onEditingChanged: model.macTargetEditChanged, relative: true)
                    Toggle("本机协同", isOn: Binding(
                        get: { model.localDuckingEnabled }, set: model.setLocalDuckingEnabled))
                        .toggleStyle(.switch)
                        .help("保留所有输入应用的输出，只降低其他可控应用。浏览器需通过扩展参与。")
                    if model.localDuckingEnabled {
                        VolumeTargetControl(title: "本机录音时", value: $model.localDuckingTarget,
                                            onEditingChanged: model.localDuckingTargetEditChanged, relative: true)
                    }
                    if let notice = model.outputNotice {
                        Label(notice, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("背景应用音量")
                } footer: {
                    Text("录音和通话应用保留原音量，其他应用按比例降低。")
                }
                Section {
                    if model.peerDisplays.isEmpty {
                        Text("添加附近设备，开始设备间协同。").foregroundStyle(.secondary)
                    }
                    ForEach(model.peerDisplays) { peer in
                        PeerRow(model: model, peer: peer)
                    }
                    Button("添加设备…") {
                        model.beginDeviceDiscovery()
                        showingPairing = true
                    }
                } header: {
                    Text("设备")
                }
                let microphones = model.sources.filter { $0.microphoneName != nil }
                if !microphones.isEmpty {
                    Section("专用麦克风") {
                        ForEach(microphones) { source in
                            Toggle(isOn: Binding(get: { source.isMuted }, set: { _ in model.toggleMute(source) })) {
                                HStack(spacing: 10) {
                                    ApplicationLabel(source: source)
                                    Spacer(minLength: 8)
                                    Text(model.sourceActivityUnknown ? "使用状态未知" :
                                         source.microphoneInUse ? "正在使用" : "未在使用")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("静音").foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            .accessibilityLabel("静音 \(source.name)")
                            .help(model.microphoneShortcuts[source.selector]?.title ?? "在设置中配置快捷键")
                        }
                    }
                }
                if !model.errorMessage.isEmpty {
                    Section {
                        Label(model.errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("设置…") { openSettings() }
                Button("诊断…") { openWindow(id: "diagnostics") }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
        }
        .sheet(isPresented: $showingPairing, onDismiss: model.endDevicePairingPresentation) {
            PairingSheet(model: model)
        }
        .onAppear { showingPairing = model.showPairing || model.macPairCode != nil || model.macPairBrowsing }
        .onChange(of: model.showPairing) { _, visible in
            if visible { showingPairing = true }
        }
    }
}

private struct PeerRow: View {
    @ObservedObject var model: AppModel
    let peer: PeerDisplay

    var body: some View {
        DisclosureGroup {
            LabeledContent("连接", value: peer.link)
            LabeledContent("空间条件", value: peer.spaceAllowed ? "已满足" : "未满足")
            if peer.pending {
                Text("验证码已验证，连接确认后加入协同。").foregroundStyle(.secondary)
            }
            if let target = model.padPeerDisplays.first(where: { $0.id == peer.id }) {
                if target.targetKnown {
                    VolumeTargetControl(title: "此设备的音量上限", value: Binding(
                        get: { model.padPeerDisplays.first(where: { $0.id == peer.id })?.target ?? target.target },
                        set: { model.setPadTarget(peer.id, value: $0) }),
                        onEditingChanged: { model.padTargetEditChanged(peer.id, $0) })
                } else {
                    LabeledContent("此设备的音量上限", value: "连接后读取")
                }
            } else {
                Text("此设备的音量上限在其声邻中调整。").foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                Text(peer.name).lineLimit(2)
                Spacer(minLength: 10)
                Text(peer.summary).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

private struct ApplicationLabel: View {
    let source: SourceCandidate
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app").resizable() }
            }
            .frame(width: 24, height: 24).accessibilityHidden(true)
            Text(source.name).lineLimit(2)
        }
        .onAppear {
            if source.selector.hasPrefix("bundle:"),
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(source.selector.dropFirst(7))) {
                icon = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }
}

private struct SettingsPanel: View {
    @ObservedObject var model: AppModel
    @State private var showingAppPicker = false
    @State private var addingMicrophone = false

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled))
                Picker("空间条件", selection: Binding(get: { model.spaceMode }, set: model.setSpaceMode)) {
                    Text("蓝牙或 Wi-Fi").tag(SpaceMode.nearbyOrWiFi)
                    Text("蓝牙且 Wi-Fi").tag(SpaceMode.nearbyAndWiFi)
                }
                if model.macPeerCount > 0 && model.spaceMode == .nearbyAndWiFi {
                    Text("局域网直连不提供蓝牙认证，无法满足“蓝牙且 Wi-Fi”。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("浏览器协同") {
                Button("设置浏览器扩展…", action: model.installBrowserAdapter)
                Text("每个网页分别调用扩展。通话页先选择“保留通话输出”，再开启 Voice；背景页选择“背景网页，允许调音”。刷新后需要重新参与。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("已排除 \(model.sources.filter(\.isExcluded).count) 个应用") {
                    ForEach(model.sources) { source in
                        Toggle(isOn: Binding(get: { source.isExcluded }, set: { _ in model.toggleExclusion(source) })) {
                            HStack {
                                ApplicationLabel(source: source)
                                Spacer()
                                if source.isActive {
                                    Text("正在录音").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityLabel("排除 \(source.name)")
                        .help(source.selector)
                    }
                }
                HStack {
                    Button("添加排除…") { addingMicrophone = false; showingAppPicker = true }
                    Button("刷新应用") { model.refreshSources() }
                }
            } header: {
                Text("排除应用")
            } footer: {
                Text("这些应用录音时不会降低其他设备音量，本机协同仍然有效。")
            }
            Section {
                if model.virtualMicrophoneAvailable {
                    ForEach(model.sources.filter { $0.microphoneName != nil }) { source in
                        MicrophoneConfiguration(model: model, source: source)
                    }
                    Button("添加应用…") { addingMicrophone = true; showingAppPicker = true }
                } else {
                    Button("安装驱动…") { model.installDriver() }.disabled(model.driverInstalling)
                }
                if !model.driverInstallStatus.isEmpty {
                    Text(model.driverInstallStatus).font(.caption).foregroundStyle(.secondary)
                }
                if model.virtualMicrophoneAvailable {
                    DisclosureGroup("驱动") {
                        Text("驱动已安装").foregroundStyle(.secondary)
                        Button("重新安装驱动…") { model.installDriver() }.disabled(model.driverInstalling)
                    }
                }
            } header: {
                Text("专用麦克风")
            } footer: {
                Text("为需要独立静音的应用添加设备，再在该应用中选择对应输入。")
            }
            if model.virtualMicrophoneAvailable {
                Section("快捷键") {
                    Toggle("让前台应用也响应同一快捷键", isOn: Binding(
                        get: { model.sharedShortcutEnabled }, set: model.setSharedShortcutEnabled))
                    if model.sharedShortcutEnabled {
                        Text(model.sharedShortcutStatus).font(.caption).foregroundStyle(.secondary)
                        if !model.sharedShortcutActive && !model.microphoneShortcuts.isEmpty {
                            Button("重新检查授权") { model.retrySharedShortcutAuthorization() }
                        }
                    }
                    if !model.shortcutMessage.isEmpty {
                        Text(model.shortcutMessage).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if !model.errorMessage.isEmpty {
                Section {
                    Text(model.errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showingAppPicker, allowedContentTypes: [.applicationBundle]) { result in
            switch result {
            case .success(let url): model.addApp(url, microphone: addingMicrophone)
            case .failure(let error): model.errorMessage = "无法选择应用：\(error.localizedDescription)"
            }
        }
        .onDisappear { model.cancelShortcutRecording() }
    }
}

private struct MicrophoneConfiguration: View {
    @ObservedObject var model: AppModel
    let source: SourceCandidate
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LabeledContent("输入设备", value: source.microphoneName ?? "")
            LabeledContent("状态", value: model.sourceActivityUnknown ? "使用状态未知" :
                           source.microphoneInUse ? "正在使用" : "未在使用")
            if source.isExcluded { Text("已排除设备间音量协同").foregroundStyle(.secondary) }
            HStack {
                Text(model.microphoneSourceDescription(for: source.selector)).foregroundStyle(.secondary)
                Spacer()
                Button("更换上游…") { model.changeMicrophoneSource(source) }
                    .disabled(model.sourceActivityUnknown || source.microphoneInUse)
            }
            HStack {
                Text(model.recordingShortcutFor == source.selector ? "请按下快捷键，Esc 取消" :
                     "快捷键：\(model.microphoneShortcuts[source.selector]?.title ?? "未设置")")
                Spacer()
                Button(model.recordingShortcutFor == source.selector ? "取消" : "录入…") {
                    if model.recordingShortcutFor == source.selector { model.cancelShortcutRecording() }
                    else { model.recordShortcut(for: source) }
                }
                if model.microphoneShortcuts[source.selector] != nil {
                    Button("清除") { model.clearShortcut(for: source.selector) }
                }
            }
            if let warning = model.microphoneShortcuts[source.selector]?.systemShortcutWarning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            Button("移除专用麦克风", role: .destructive) { model.removeMicrophone(source) }
                .disabled(model.sourceActivityUnknown || source.microphoneInUse)
        } label: {
            ApplicationLabel(source: source)
        }
        .onChange(of: expanded) { _, visible in
            if !visible && model.recordingShortcutFor == source.selector { model.cancelShortcutRecording() }
        }
    }
}

private struct DiagnosticsPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("运行状态") {
                    LabeledContent("自动协同", value: model.coordinationStatus)
                    LabeledContent("参与协同的有效输入来源", value: "\(model.inputCount)")
                    LabeledContent("空间条件", value: model.spaceStatus)
                    LabeledContent("上次音量操作", value: model.lastAction)
                    ForEach(model.peerDisplays) { peer in
                        LabeledContent(peer.name, value: "\(peer.link) · \(peer.summary)")
                    }
                    if let error = model.inputError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("音频协同") {
                    LabeledContent("本机输出", value: model.outputStatus)
                    LabeledContent("输出保护", value: model.protectedOutputStatus)
                    LabeledContent("浏览器网页", value: model.browserStatus)
                }
                .textSelection(.enabled)
                Section("音频记录") {
                    ForEach(model.sources.filter { $0.microphoneName != nil }) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ApplicationLabel(source: source)
                                Spacer()
                                Button("标记现场") { model.markForensics(source) }
                            }
                            Text(model.forensicDescription(for: source.selector)).foregroundStyle(.secondary)
                            if let warning = model.forensicWarning(for: source.selector) {
                                Text(warning).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    LabeledContent("取证目录") {
                        Button("更改…") { model.chooseForensicLocation() }
                    }
                    Picker("容量上限", selection: Binding(
                        get: { model.forensicLimitGB }, set: model.setForensicLimitGB)) {
                        ForEach([10, 40, 100, 250, 500], id: \.self) { amount in
                            Text("\(amount) GB").tag(amount)
                        }
                    }
                    Text(model.forensicLocation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("音频持续保存在本机，按容量上限淘汰；可能包含私人谈话，不会自动上传。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.diagnosticMessage.isEmpty || !model.errorMessage.isEmpty {
                    Section {
                        Text(model.diagnosticMessage).foregroundStyle(.secondary)
                        Text(model.errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("导出诊断包…") { model.exportForensics() }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
        }
    }
}

private struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var selectedName: String?
    @State private var initialPeerIDs: Set<String>
    @FocusState private var codeFocused: Bool

    init(model: AppModel) {
        self.model = model
        _initialPeerIDs = State(initialValue: Set(model.peerDisplays.map(\.id)))
    }

    private var completedPeer: PeerDisplay? {
        model.peerDisplays.first { !$0.pending && !initialPeerIDs.contains($0.id) }
    }
    private var pendingPeer: PeerDisplay? {
        model.peerDisplays.first { $0.pending && !initialPeerIDs.contains($0.id) }
    }
    private var code: String {
        (model.pairingAwaitingCode ? model.pairingCodeInput : model.macPairCodeInput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var validCode: Bool { code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) } }

    private func findDevices() {
        selectedName = nil
        model.beginDeviceDiscovery()
    }
    private func submitCode() {
        guard validCode else { return }
        if model.pairingAwaitingCode { model.submitPairingCode(code) }
        else { model.submitMacPairCode() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加设备").font(.title2).fontWeight(.semibold)
            Group {
                if let peer = completedPeer {
                    Label("已添加 \(peer.name)", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                } else if let peer = pendingPeer {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("验证码已验证", systemImage: "checkmark.circle")
                        Text("等待 \(peer.name) 连接确认。关闭此窗口后仍会继续。")
                            .foregroundStyle(.secondary)
                    }
                } else if let code = model.macPairCode {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.localMacName).font(.headline)
                        Text(code).font(.system(size: 34, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                        Text("在能查找附近设备的声邻中选择此设备，输入验证码。两分钟内有效。")
                            .foregroundStyle(.secondary)
                        Text(model.macPairStatus).font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.pairingAwaitingCode || model.macPairAwaitingCode {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.pairingAwaitingCode ? model.pairingPadName : selectedName ?? "所选设备")
                            .font(.headline)
                        TextField("设备上的 6 位验证码", text: model.pairingAwaitingCode ?
                                  $model.pairingCodeInput : $model.macPairCodeInput)
                            .textFieldStyle(.roundedBorder).focused($codeFocused)
                            .onSubmit(submitCode)
                        Text(model.pairingAwaitingCode ? model.pairingStatus : model.macPairStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if selectedName != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        if (model.pairingActive || model.macPairBrowsing) && model.errorMessage.isEmpty {
                            HStack { ProgressView().controlSize(.small); Text("正在配对 \(selectedName ?? "")") }
                        } else {
                            Label("未完成配对", systemImage: "exclamationmark.circle")
                        }
                        let status = model.showPairing ? model.pairingStatus : model.macPairStatus
                        if status != model.errorMessage {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("在待添加设备的声邻中开启配对，然后选择它。")
                            .foregroundStyle(.secondary)
                        if model.nearbyPads.isEmpty && model.nearbyMacs.isEmpty {
                            if model.pairingActive || model.macPairBrowsing {
                                HStack { ProgressView().controlSize(.small); Text("正在查找附近设备…") }
                            } else {
                                Text("配对已结束，请重新查找。").foregroundStyle(.secondary)
                            }
                        } else {
                            ScrollView {
                                VStack(spacing: 8) {
                                    ForEach(model.nearbyPads) { peer in
                                        Button {
                                            selectedName = peer.name
                                            model.choosePad(peer.id)
                                        } label: {
                                            HStack { Text(peer.name); Spacer(); Text("蓝牙").foregroundStyle(.secondary) }
                                                .frame(maxWidth: .infinity)
                                        }
                                    }
                                    ForEach(model.nearbyMacs) { peer in
                                        Button {
                                            selectedName = peer.name
                                            model.chooseMac(peer.id)
                                        } label: {
                                            HStack { Text(peer.name); Spacer(); Text("局域网").foregroundStyle(.secondary) }
                                                .frame(maxWidth: .infinity)
                                        }
                                    }
                                }.buttonStyle(.bordered)
                            }
                            .frame(maxHeight: 180)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            if !model.errorMessage.isEmpty {
                Text(model.errorMessage).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                if completedPeer == nil && pendingPeer == nil {
                    if selectedName == nil && model.macPairCode == nil && !model.pairingAwaitingCode && !model.macPairAwaitingCode {
                        Button("显示本机配对码") { model.offerDevicePairingCode() }
                        Button("重新查找", action: findDevices)
                    } else {
                        Button("返回查找", action: findDevices)
                    }
                }
                Spacer()
                Button(completedPeer != nil || pendingPeer != nil ? "完成" : "取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if model.pairingAwaitingCode || model.macPairAwaitingCode {
                    Button("验证并配对", action: submitCode)
                        .keyboardShortcut(.defaultAction).disabled(!validCode)
                }
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { codeFocused = model.pairingAwaitingCode || model.macPairAwaitingCode }
        .onChange(of: model.pairingAwaitingCode || model.macPairAwaitingCode) { _, awaiting in
            codeFocused = awaiting
        }
    }
}
