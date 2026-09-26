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
    @Published private(set) var nearbyPads = [NearbyPad]()
    @Published private(set) var pairingStatus = ""
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingPadName = ""
    @Published private(set) var pairingActive = false
    @Published private(set) var pairingConfirmed = false
    @Published var target = 0.0
    @Published var showPairing = false
    @Published var errorMessage = ""
    @Published private(set) var enabled: Bool

    private let preferences = MacPreferences.defaults
    private let runLock = RunLock()
    private var client: BLEClient?
    private var pairClient: PairClient?
    private var currentKey: Data?
    private var pendingKey: Data?
    private var pendingExpiresAt: Date?
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
            self?.expirePendingPairing()
        }
        connection = "正在读取本机配对信息"
        Task.detached { [weak self] in
            do {
                let key = try MacCredentials.read("pairingKey")
                var pending: (key: Data, expiresAt: Date)?
                var pendingError: String?
                do { pending = try MacCredentials.pendingPairing() }
                catch { pendingError = "无法读取待激活配对：\(error.localizedDescription)" }
                await MainActor.run {
                    guard let self else { return }
                    self.currentKey = key
                    if let pending {
                        self.pendingKey = pending.key
                        self.pendingExpiresAt = pending.expiresAt
                        self.useKey(pending.key)
                    } else if let key { self.useKey(key) }
                    else { self.beginPairing() }
                    if let pendingError { self.errorMessage = pendingError }
                }
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
            Task { @MainActor [weak self] in self?.accept(ack, key: key) }
        })
        client?.setDesired(enabled && inputCount > 0)
    }

    private func accept(_ ack: ControlAck, key: Data) {
        if pendingKey == key {
            do {
                try MacCredentials.promotePairing(key)
                currentKey = key
                pendingKey = nil
                pendingExpiresAt = nil
            } catch { errorMessage = "iPad 已接受新配对，但 Mac 保存失败：\(error.localizedDescription)" }
        }
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

    func beginPairing() {
        if pendingKey != nil {
            do { try MacCredentials.clearPendingPairing() }
            catch { errorMessage = "无法清除上次待激活配对：\(error.localizedDescription)"; return }
            pendingKey = nil
            pendingExpiresAt = nil
        }
        pairClient?.stop()
        client?.setDesired(false)
        client?.stop()
        client = nil
        connection = "正在配对"
        showPairing = true
        nearbyPads = []
        pairingCode = nil
        pairingPadName = ""
        pairingActive = true
        pairingConfirmed = false
        pairingStatus = "正在查找附近的 iPad"
        errorMessage = ""
        pairClient = PairClient(onDevices: { [weak self] devices in
            self?.nearbyPads = devices
        }, onStatus: { [weak self] status in
            self?.pairingStatus = status
        }, onCode: { [weak self] code, name in
            self?.pairingCode = code
            self?.pairingPadName = name
        }, onComplete: { [weak self] key in
            guard let self else { return }
            self.pairClient = nil
            self.pairingActive = false
            do {
                let deadline = try MacCredentials.stagePairing(key)
                self.pendingKey = key
                self.pendingExpiresAt = deadline
                self.useKey(key)
            } catch {
                self.restorePreviousPairing()
                self.errorMessage = "无法保存新配对：\(error.localizedDescription)"
            }
        }, onFailure: { [weak self] message in
            guard let self else { return }
            self.pairClient = nil
            self.pairingActive = false
            self.pairingStatus = message
            self.pairingCode = nil
            self.restorePreviousPairing()
            self.errorMessage = message
        })
    }

    func choosePad(_ id: UUID) { pairClient?.choose(id) }
    func confirmPairing() {
        guard !pairingConfirmed, let pairClient else { return }
        pairingConfirmed = true
        pairClient.confirm()
    }

    func cancelPairing() {
        pairClient?.reject()
        pairClient = nil
        pairingActive = false
        showPairing = false
        pairingCode = nil
        restorePreviousPairing()
    }

    private func restorePreviousPairing() {
        if let currentKey { useKey(currentKey) }
        else { paired = false; connection = "尚未配对" }
    }

    private func expirePendingPairing() {
        guard let pendingExpiresAt, Date() >= pendingExpiresAt else { return }
        do { try MacCredentials.clearPendingPairing() }
        catch { errorMessage = "无法清除过期配对：\(error.localizedDescription)"; return }
        pendingKey = nil
        self.pendingExpiresAt = nil
        restorePreviousPairing()
        errorMessage = "新配对未能连接 iPad，旧配对已保留；请重新配对。"
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
        pairClient?.stop()
        client?.setDesired(false)
        connection = "正在恢复音量并退出"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.client?.stop()
            NSApp.terminate(nil)
        }
    }
}
