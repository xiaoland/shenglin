import SwiftUI

@MainActor final class NearbyAudioAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    func applicationDidFinishLaunching(_ notification: Notification) { model.start() }
}

@main @MainActor struct NearbyAudioMacApp: App {
    @NSApplicationDelegateAdaptor(NearbyAudioAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: delegate.model)
                .frame(width: 380)
                .onAppear { delegate.model.refreshSources() }
        } label: {
            MenuBarStatus(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarStatus: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Image(systemName: model.iconName)
            .accessibilityLabel("Nearby Audio：\(model.connection)")
    }
}

private struct ControlPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nearby Audio").font(.title2.bold())
                    Text("Mac 录音时协调 iPad 媒体音量")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("退出") { model.quit() }
                    .accessibilityLabel("退出 Nearby Audio 并恢复 iPad 音量")
            }

            HStack(spacing: 8) {
                Circle().fill(model.isConnected ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(model.connection).font(.subheadline)
                Spacer()
                Button(model.paired ? "更换配对" : "开始配对") { model.beginPairing() }
                    .buttonStyle(.link)
            }

            if model.showPairing {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.paired ? "更换配对的 iPad" : "与 iPad 配对").font(.headline)
                    Text("在 iPad App 点按“开始 2 分钟配对”，然后选择下方的 iPad。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.paired {
                        Text("新配对生效后，旧 Mac 将无法再控制这台 iPad。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.pairingStatus).font(.caption)
                    if model.pairingAwaitingCode {
                        Text(model.pairingPadName).font(.subheadline)
                        TextField("iPad 上的 6 位验证码", text: $model.pairingCodeInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.submitPairingCode(model.pairingCodeInput) }
                        Text("输入 iPad 显示的数字，一次完成验证。")
                            .font(.caption)
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

            Divider()

            Toggle("自动协同", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                .font(.headline)
            Text("参与协同的录音进程：\(model.inputCount) 个。默认所有录音应用参与，排除项不参与。")
                .font(.caption).foregroundStyle(.secondary)
            if let inputError = model.inputError {
                Text("输入状态未知，已停止降音量请求：\(inputError)")
                    .font(.caption).foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("排除应用").font(.headline)
                    Spacer()
                    Button("刷新") { model.refreshSources() }
                        .buttonStyle(.link)
                    Button("添加排除…") { model.chooseApp() }
                        .buttonStyle(.link)
                }
                Text("开关打开表示该应用录音时不改变 iPad 音量。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
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
                .frame(height: 150)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("录音时 iPad 媒体音量").font(.headline)
                    Spacer()
                    Text(model.targetKnown ? "\(Int((model.target * 100).rounded()))%" : "连接后读取")
                        .monospacedDigit()
                }
                Slider(value: $model.target, in: 0...0.5, step: 0.05,
                       onEditingChanged: model.targetEditChanged)
                    .disabled(!model.targetKnown || !model.paired)
                    .accessibilityLabel("录音时 iPad 媒体音量目标")
                Text("录音期间更改目标将在下次录音开始时生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("登录后自动启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled))

            Text(model.lastAction).font(.caption).foregroundStyle(.secondary)
            if !model.errorMessage.isEmpty {
                Text(model.errorMessage).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
    }
}
