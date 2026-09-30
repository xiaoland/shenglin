import MediaPlayer
import SwiftUI

struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView(frame: .zero) }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

@main struct ShenglinPadApp: App {
    @StateObject private var server = BLEServer()

    var body: some Scene {
        WindowGroup { MainView(server: server).tint(.teal) }
    }
}

private enum PresentedSheet: String, Identifiable {
    case settings, pairing
    var id: String { rawValue }
}

private struct MainView: View {
    @ObservedObject var server: BLEServer
    @AppStorage("targetVolume") private var targetVolume = 0.0
    @State private var presentedSheet: PresentedSheet?

    private var coordinationStatus: (title: String, symbol: String) {
        guard server.enabled else { return ("已暂停", "pause.circle") }
        guard server.startupIssue == nil else { return ("协同暂不可用", "exclamationmark.circle") }
        guard server.isPaired else { return ("尚未添加设备", "link") }
        let available = server.pairedPeerDisplays.filter(\.allowsCoordination).count
        if available > 0 { return ("\(available) 台设备可协同", "checkmark.circle") }
        let title = server.pairedPeerDisplays.contains(where: \.connected) ? "等待空间条件" : "等待设备连接"
        return (title, "clock")
    }

    var body: some View {
        let status = coordinationStatus
        NavigationStack {
            Form {
                Section {
                    Toggle("自动协同", isOn: Binding(get: { server.enabled }, set: server.setEnabled))
                    Label(status.title, systemImage: status.symbol)
                        .foregroundStyle(.secondary)
                    Label(server.recordingStatus, systemImage: "mic")
                        .foregroundStyle(.secondary)
                    if let issue = server.startupIssue ?? server.bluetoothIssue ?? (server.spaceAllowed ? nil : server.wifiIssue) {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    HStack {
                        Text("媒体音量降至")
                        Spacer()
                        Text(targetVolume, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $targetVolume, in: 0...0.5, step: 0.05)
                        .accessibilityLabel("其他设备录音时的媒体音量")
                        .accessibilityValue(Text(targetVolume, format: .percent.precision(.fractionLength(0))))
                    Button("立即恢复音量", systemImage: "speaker.wave.2") { server.restoreNow() }
                        .disabled(server.startupIssue != nil)
                } header: {
                    Text("其他设备录音时")
                } footer: {
                    Text("仅降低音量；更改目标从下一次协同生效。")
                }

                Section("设备") {
                    if server.pairingPendingActivation {
                        Button { presentedSheet = .pairing } label: {
                            Label("新设备等待连接", systemImage: "hourglass")
                        }
                    }
                    ForEach(server.pairedPeerDisplays) { peer in
                        DisclosureGroup {
                            LabeledContent("连接", value: peer.link)
                            LabeledContent("空间条件", value: server.enabled ? peer.space : "已暂停")
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(peer.name).foregroundStyle(.primary)
                                Text(server.enabled ? peer.summary : "已暂停")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if !server.isPaired && !server.pairingPendingActivation {
                        Text("尚未添加设备").foregroundStyle(.secondary)
                    }
                    Button("添加设备", systemImage: "plus") { presentedSheet = .pairing }
                }
            }
            .navigationTitle("声邻")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "gearshape") { presentedSheet = .settings }
                }
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .settings: SettingsView(server: server)
                case .pairing: PairingView(server: server)
                }
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var server: BLEServer
    @Environment(\.dismiss) private var dismiss
    @State private var deviceNameInput = ""

    private var trimmedName: String { deviceNameInput.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 32 && !server.pairingMode && trimmedName != server.deviceName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("设备名称", text: $deviceNameInput)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                        .disabled(server.pairingMode)
                    Button("保存名称", action: saveName).disabled(!canSave)
                } header: {
                    Text("设备名称")
                } footer: {
                    if server.pairingMode {
                        Text("配对期间不能修改名称。")
                    } else if trimmedName.isEmpty || trimmedName.count > 32 {
                        Text("请输入 1～32 个字符。").foregroundStyle(.red)
                    }
                }
                Section {
                    Picker("空间条件", selection: Binding(get: { server.spaceMode }, set: server.setSpaceMode)) {
                        Text("蓝牙或 Wi-Fi").tag(SpaceMode.nearbyOrWiFi)
                        Text("蓝牙且 Wi-Fi").tag(SpaceMode.nearbyAndWiFi)
                    }
                } footer: {
                    Text("Wi-Fi 条件指已配对设备通过局域网认证互通，不代表一定在同一房间。")
                }
                Section {
                    NavigationLink("运行详情") { DiagnosticsView(server: server) }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .onAppear { deviceNameInput = server.deviceName }
        }
    }

    private func saveName() {
        guard canSave else { return }
        server.setDeviceName(deviceNameInput)
        deviceNameInput = server.deviceName
    }
}

private struct PairingView: View {
    @ObservedObject var server: BLEServer
    @Environment(\.dismiss) private var dismiss
    @State private var completed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("本机", value: server.deviceName)
                    if let code = server.shortCode {
                        Text(code)
                            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                            .tracking(6)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .accessibilityLabel("配对验证码 \(code)")
                            .textSelection(.enabled)
                    }
                } footer: {
                    if server.shortCode != nil {
                        Text("在另一台设备的声邻中添加「\(server.deviceName)」，输入此验证码。2 分钟内有效。")
                    }
                }
                Section {
                    HStack {
                        if server.pairingPendingActivation { ProgressView() }
                        else if completed { Image(systemName: "checkmark.circle") }
                        Text(server.pairingStatus).foregroundStyle(.secondary)
                    }
                    if !server.pairingMode && !server.pairingPendingActivation && !completed {
                        Button("重新显示配对码") { server.beginPairing() }
                            .disabled(!server.enabled)
                    }
                } footer: {
                    if !server.enabled { Text("请先在主界面开启自动协同。") }
                }
            }
            .navigationTitle("添加设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(server.pairingMode ? "取消" : "完成") { dismiss() }
                }
            }
            .onAppear {
                if !server.pairingMode && !server.pairingPendingActivation { server.beginPairing() }
            }
            .onChange(of: server.pairedCount) { previous, current in
                if current > previous { completed = true }
            }
            .onDisappear {
                // An unseen code must not keep accepting new pairing attempts.
                if server.pairingMode { server.rejectPairing() }
            }
        }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var server: BLEServer

    var body: some View {
        Form {
            Section("运行状态") {
                Text(server.status)
                Text(server.recordingStatus)
                Text(server.spaceStatus)
            }
            Section("最近一次音量操作") { Text(server.lastAction) }
            Section("当前媒体音量") { SystemVolumeView().frame(height: 44) }
            Section {
                Text("声邻只协调录音状态，不采集或传输麦克风音频。")
            }
        }
        .navigationTitle("运行详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}
