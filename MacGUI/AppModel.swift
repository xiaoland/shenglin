import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var connection = "正在启动"
    @Published private(set) var lastAction = "尚无音量操作"
    @Published private(set) var sources = [SourceCandidate]()
    @Published private(set) var inputCount = 0
    @Published private(set) var paired = false
    @Published private(set) var targetKnown = false
    @Published private(set) var loginEnabled = false
    @Published var target = 0.0
    @Published var pairingInput = ""
    @Published var showPairing = false
    @Published var errorMessage = ""
    @Published private(set) var enabled: Bool

    private let preferences = MacPreferences.defaults
    private let runLock = RunLock()
    private var client: BLEClient?
    private var input: InputActivity?
    private var timer: Timer?
    private var started = false
    private var targetEditing = false

    var iconName: String {
        if runLock == nil || !paired { return "exclamationmark.triangle.fill" }
        if !enabled { return "waveform.slash" }
        if connection != "iPad 已连接" { return "exclamationmark.circle" }
        return inputCount > 0 ? "waveform.circle.fill" : "waveform"
    }

    init() {
        enabled = preferences.object(forKey: "coordinationEnabled") as? Bool ?? true
        loginEnabled = SMAppService.mainApp.status == .enabled
        if runLock == nil { connection = "另一个 Nearby Audio 控制程序正在运行" }
        Task { @MainActor [weak self] in self?.start() }
    }

    func start() {
        guard !started, runLock != nil else { return }
        started = true
        refreshSources()
        input = InputActivity { [weak self] active, count in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inputCount = count
                self.client?.setDesired(self.enabled && active)
            }
        }
        input?.poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.input?.poll()
        }
        connection = "正在读取本机配对信息"
        Task.detached { [weak self] in
            do {
                let key = try MacCredentials.read("pairingKey")
                await MainActor.run { self?.useKey(key) }
            } catch {
                await MainActor.run { self?.connection = "无法读取配对信息"; self?.errorMessage = error.localizedDescription }
            }
        }
    }

    private func useKey(_ key: Data?) {
        client?.stop()
        client = nil
        guard let key, key.count == 32 else {
            paired = false
            connection = "尚未配对"
            showPairing = true
            return
        }
        paired = true
        showPairing = false
        errorMessage = ""
        connection = "正在连接 iPad"
        client = BLEClient(key: key, onStatus: { [weak self] status in
            Task { @MainActor [weak self] in self?.connection = status }
        }, onAck: { [weak self] ack in
            Task { @MainActor [weak self] in self?.accept(ack) }
        })
        client?.setDesired(enabled && inputCount > 0)
    }

    private func accept(_ ack: ControlAck) {
        if !targetEditing, (0...500).contains(ack.targetMilli) {
            target = Double(ack.targetMilli) / 1000
            targetKnown = true
        }
        switch ack.result {
        case "applied": lastAction = "iPad 媒体音量已降低至 \(ack.volumeMilli)‰"
        case "restored": lastAction = "iPad 媒体音量已恢复至 \(ack.volumeMilli)‰"
        case "preservedManualOrRoute": lastAction = "保留了你手动调整的音量或新输出设备"
        case "alreadyRestored": lastAction = "iPad 音量保持原状"
        default: lastAction = "iPad 回执：\(ack.result)"
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        preferences.set(value, forKey: "coordinationEnabled")
        client?.setDesired(value && inputCount > 0)
    }

    func refreshSources() {
        do { sources = try availableSources() }
        catch { errorMessage = "无法列出应用：\(error.localizedDescription)" }
    }

    func toggleSource(_ source: SourceCandidate) {
        do {
            try SelectionStore.change(source.selector, add: !source.isSelected)
            refreshSources()
            input?.poll()
        } catch { errorMessage = "无法保存应用选择：\(error.localizedDescription)" }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.message = "选择要触发 iPad 音量协同的 Mac 应用"
        panel.prompt = "选择应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let bundle = Bundle(url: url)?.bundleIdentifier else {
                    self.errorMessage = "所选应用没有可用的 bundle ID"
                    return
                }
                do {
                    try SelectionStore.change("bundle:\(bundle)", add: true)
                    self.refreshSources()
                    self.input?.poll()
                } catch { self.errorMessage = "无法保存应用选择：\(error.localizedDescription)" }
            }
        }
    }

    func pair() {
        let code = pairingInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = Data(base64Encoded: code), key.count == 32 else {
            errorMessage = "配对码无效，请复制 iPad App 首页显示的完整配对码。"
            return
        }
        do {
            try MacCredentials.save(key, account: "pairingKey")
            pairingInput = ""
            useKey(key)
        } catch { errorMessage = "无法保存配对信息：\(error.localizedDescription)" }
    }

    func targetEditChanged(_ editing: Bool) {
        targetEditing = editing
        if !editing { client?.setTargetMilli(Int((target * 1000).rounded())) }
    }

    func setLoginEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if value && !loginEnabled { errorMessage = "登录启动需要在系统设置的“登录项”中批准。" }
        } catch { errorMessage = "无法更改登录启动：\(error.localizedDescription)" }
    }

    func quit() {
        client?.setDesired(false)
        connection = "正在恢复音量并退出"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.client?.stop()
            NSApp.terminate(nil)
        }
    }
}
