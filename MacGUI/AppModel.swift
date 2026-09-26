import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var connectionState = BLEConnectionState.message("正在启动")
    @Published private(set) var lastAction = "尚无音量操作"
    @Published private(set) var lastAckSequence: UInt64?
    @Published private(set) var sources = [SourceCandidate]()
    @Published private(set) var virtualMicrophoneAvailable = false
    @Published private(set) var inputState = InputObservation.active(0)
    @Published private(set) var paired = false
    @Published private(set) var targetKnown = false
    @Published private(set) var loginEnabled = false
    @Published private(set) var nearbyPads = [NearbyPad]()
    @Published private(set) var pairingStatus = ""
    @Published var pairingCodeInput = ""
    @Published private(set) var pairingAwaitingCode = false
    @Published private(set) var pairingPadName = ""
    @Published private(set) var pairingActive = false
    @Published var target = 0.0
    @Published var macTarget = 0.0
    @Published private(set) var spaceMode: SpaceMode
    @Published private(set) var bleReachable = false
    @Published private(set) var wifiVerified = false
    @Published private(set) var wifiIssue: String?
    @Published private(set) var spaceAllowed = false
    @Published private(set) var nearbyMacs = [NearbyMac]()
    @Published private(set) var macPairCode: String?
    @Published private(set) var macPairStatus = ""
    @Published private(set) var macPairAwaitingCode = false
    @Published private(set) var macPairBrowsing = false
    @Published private(set) var macPeerCount = 0
    @Published private(set) var directMacCount = 0
    @Published var macPairCodeInput = ""
    @Published var showPairing = false
    @Published var errorMessage = ""
    @Published private(set) var enabled: Bool

    private let preferences = MacPreferences.defaults
    private let runLock = RunLock()
    private var client: BLEClient?
    private var wifiPeer: WiFiPeer?
    private var macPairServer: MacPairServer?
    private var macPairClient: MacPairClient?
    private var macWifiPeers = [String: WiFiPeer]()
    private var macPeerVerified = Set<String>()
    private var macPeerGates = [String: SpaceGate]()
    private var macPeerAllowed = Set<String>()
    private var spaceGate = SpaceGate()
    private var pendingTargetMilli: Int?
    private var quitting = false
    private var pairClient: PairClient?
    private var controlServer: ControlServer?
    private var currentKey: Data?
    private var activePadKey: Data?
    private var pendingKey: Data?
    private var pendingExpiresAt: Date?
    private var input: InputActivity?
    private var localOutput: MacQuietVolume?
    private var peerLedger = (MacPreferences.defaults.data(forKey: "peerDemandLedger")
        .flatMap { try? JSONDecoder().decode(PeerDemandLedger.self, from: $0) }) ?? PeerDemandLedger()
    private var timer: Timer?
    private var started = false
    private var targetEditing = false
    private var clientGeneration = 0
    private var pairingGeneration = 0
    private var credentialLoadGeneration = 0

    var connection: String {
        if directMacCount > 0 && !connectionState.isReady && !wifiVerified { return "Mac 直连已认证" }
        return wifiVerified && !connectionState.isReady ? "iPad Wi-Fi 已认证连接" : connectionState.text
    }
    var isConnected: Bool { connectionState.isReady || wifiVerified || directMacCount > 0 }
    var inputCount: Int { inputState.count }
    var inputError: String? { inputState.error }
    private var rawSpaceAllowed: Bool { spaceMode.allows(ble: bleReachable, wifi: wifiVerified) }
    var spaceStatus: String {
        let summary = "蓝牙\(bleReachable ? "已验证" : "未验证") · Wi-Fi 局域网\(wifiVerified ? "已认证互通" : "未验证") · \(rawSpaceAllowed ? "允许协同" : spaceAllowed ? "短断连宽限" : "等待空间条件")"
        return wifiIssue.map { "\(summary) · Wi-Fi 错误：\($0)" } ?? summary
    }

    var iconName: String {
        if runLock == nil || (!paired && macPeerCount == 0) { return "exclamationmark.triangle.fill" }
        if !enabled { return "waveform.slash" }
        if !isConnected { return "exclamationmark.circle" }
        return inputCount > 0 ? "waveform.circle.fill" : "waveform"
    }

    init() {
        enabled = preferences.object(forKey: "coordinationEnabled") as? Bool ?? true
        spaceMode = SpaceMode(rawValue: preferences.string(forKey: "spaceMode") ?? "") ?? .nearbyOrWiFi
        macTarget = preferences.object(forKey: "localOutputTarget") as? Double ?? 0
        loginEnabled = SMAppService.mainApp.status == .enabled
        if runLock == nil { connectionState = .message("另一个 Nearby Audio 控制程序正在运行") }
        Task { @MainActor [weak self] in self?.start() }
    }

    func start() {
        guard !started, runLock != nil else { return }
        started = true
        do {
            controlServer = try ControlServer { [weak self] request in
                self?.handleControl(request) ?? ControlResponse(ok: false, message: "应用正在退出", status: nil)
            }
        } catch { errorMessage = "本机控制入口不可用：\(error.localizedDescription)" }
        refreshSources()
        localOutput = MacQuietVolume { [weak self] in
            guard let self else { return }
            self.peerLedger.takeOver(at: Int64(Date().timeIntervalSince1970))
            self.persistPeerLedger()
            self.lastAction = "保留了你手动调整的 Mac 音量"
        }
        localOutput?.recoverPreviousRound()
        input = InputActivity { [weak self] observation in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inputState = observation
                self.publishLocalDemand()
            }
        }
        input?.poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.input?.poll()
                self?.expirePendingPairing()
                self?.refreshSpace()
                self?.refreshMacPeerSpaces()
                self?.expirePeerRequests()
            }
        }
        connectionState = .message("正在读取本机配对信息")
        let generation = credentialLoadGeneration
        Task.detached { [weak self] in
            do {
                let key = try MacCredentials.read("pairingKey")
                var pending: (key: Data, expiresAt: Date)?
                var pendingError: String?
                do { pending = try MacCredentials.pendingPairing() }
                catch { pendingError = "无法读取待激活配对：\(error.localizedDescription)" }
                await self?.loadedKeys(key, pending: pending, errorMessage: pendingError, generation: generation)
            } catch {
                await self?.startupFailed(error.localizedDescription, generation: generation)
            }
        }
    }

    private func loadedKeys(_ key: Data?, pending: (key: Data, expiresAt: Date)?, errorMessage: String?, generation: Int) {
        if generation != credentialLoadGeneration {
            if currentKey == nil { currentKey = key }
            return
        }
        currentKey = key
        startMacPeers()
        if let pending {
            pendingKey = pending.key
            pendingExpiresAt = pending.expiresAt
            pairingStatus = "正在验证上次的新配对"
            useKey(pending.key)
        } else if let key { useKey(key) }
        else { useKey(nil); showPairing = false }
        if let errorMessage { self.errorMessage = errorMessage }
    }

    private func startupFailed(_ message: String, generation: Int) {
        guard generation == credentialLoadGeneration else { return }
        startMacPeers()
        connectionState = .message("无法读取配对信息")
        errorMessage = message
    }

    private func useKey(_ key: Data?) {
        if let activePadKey, activePadKey != key {
            let change = peerLedger.stopResponding(to: sourceID(for: activePadKey),
                                                  at: Int64(Date().timeIntervalSince1970))
            persistPeerLedger()
            if change.ended { localOutput?.finish(manualAtEnd: change.manualAtEnd) }
        }
        activePadKey = key
        clientGeneration += 1
        let generation = clientGeneration
        client?.stop()
        client = nil
        wifiPeer?.stop()
        wifiPeer = nil
        bleReachable = false
        wifiVerified = false
        wifiIssue = nil
        spaceGate.reset()
        spaceAllowed = false
        guard let key, key.count == 32 else {
            paired = false
            connectionState = .message("尚未配对")
            showPairing = true
            return
        }
        paired = true
        showPairing = false
        errorMessage = ""
        connectionState = .message("正在连接 iPad")
        client = BLEClient(key: key, onStatus: { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.clientGeneration == generation else { return }
                self.connectionState = status
                self.bleReachable = status.isReady
                self.refreshSpace()
            }
        }, onAck: { [weak self] ack in
            Task { @MainActor [weak self] in
                guard let self, self.clientGeneration == generation else { return }
                self.accept(ack, key: key)
            }
        }, onPeerAck: { [weak self] ack in
            Task { @MainActor [weak self] in
                guard let self, self.clientGeneration == generation else { return }
                self.acceptPeerAck(ack, key: key)
            }
        }, onPeerState: { [weak self] update, done in
            Task { @MainActor [weak self] in
                guard let self, self.clientGeneration == generation else { done("stale"); return }
                done(self.receivePeerState(update, key: key, expectedOrigin: "ipad", allowed: self.spaceAllowed))
            }
        })
        publishLocalDemand()
        wifiPeer = WiFiPeer(localOrigin: "mac", remoteOrigin: "ipad", listens: true,
                            key: key, localUpdate: { [unowned self] in
            PeerQuietUpdate(origin: "mac", revision: MacCredentials.nextSequence(),
                            quiet: !self.quitting && self.enabled && self.inputState.needsQuiet && self.spaceAllowed,
                            validUntil: Int64(Date().timeIntervalSince1970) + PeerTiming.leaseSeconds,
                            targetMilli: self.pendingTargetMilli, key: key)
        }, receiveUpdate: { [unowned self] update in
            (self.receivePeerState(update, key: key, expectedOrigin: "ipad", allowed: self.spaceAllowed), nil)
        }, receiveAck: { [unowned self] ack in
            self.acceptPeerAck(ack, key: key)
        }, verifiedChanged: { [unowned self] verified in
            self.wifiVerified = verified
            self.refreshSpace()
        }, onIssue: { [unowned self] issue in
            self.wifiIssue = issue
        })
        wifiPeer?.start()
    }

    private func accept(_ ack: ControlAck, key: Data) {
        promotePendingPairing(key)
        guard ack.sequence >= (lastAckSequence ?? 0) else { return }
        lastAckSequence = ack.sequence
        if pendingTargetMilli == ack.targetMilli { pendingTargetMilli = nil }
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

    private func promotePendingPairing(_ key: Data) {
        if pendingKey == key {
            do {
                // Keep the old key until the iPad proves it accepted the new one.
                try MacCredentials.promotePairing(key)
                currentKey = key
                pendingKey = nil
                pendingExpiresAt = nil
                pairingStatus = "配对完成，iPad 已接受新密钥"
            } catch {
                errorMessage = "iPad 已接受新配对，但 Mac 保存失败：\(error.localizedDescription)"
                pairingStatus = errorMessage
            }
        }
    }

    private func acceptPeerAck(_ ack: PeerStateAck, key: Data) {
        promotePendingPairing(key)
        guard ack.revision >= (lastAckSequence ?? 0) else { return }
        lastAckSequence = ack.revision
        if pendingTargetMilli == ack.targetMilli { pendingTargetMilli = nil }
        client?.confirmTargetMilli(ack.targetMilli)
        if !targetEditing, let milli = ack.targetMilli, (0...500).contains(milli) {
            target = Double(milli) / 1000
            targetKnown = true
        }
        switch ack.result {
        case "applied": lastAction = "iPad 媒体音量已降低"
        case "restored": lastAction = "iPad 媒体音量正在恢复"
        case "preservedManualOrRoute": lastAction = "保留了你手动调整的音量或新输出设备"
        case "alreadyRestored": lastAction = "iPad 音量保持原状"
        default: lastAction = "iPad 回执：\(ack.result)"
        }
    }

    private func persistPeerLedger() {
        preferences.set(try? JSONEncoder().encode(peerLedger), forKey: "peerDemandLedger")
    }

    private func sourceID(for key: Data) -> String { Authentication.sign("paired-peer-id", key: key) }

    private func startMacPeers() {
        let peers: [MacCredentials.MacPeer]
        do { peers = try MacCredentials.macPeers() }
        catch { errorMessage = "无法读取 Mac 配对：\(error.localizedDescription)"; return }
        macPeerCount = peers.count
        for peer in peers {
            let source = sourceID(for: peer.key)
            guard macWifiPeers[source] == nil else { continue }
            let localOrigin = peer.isInitiator ? "mac-initiator" : "mac-responder"
            let remoteOrigin = peer.isInitiator ? "mac-responder" : "mac-initiator"
            let link = WiFiPeer(localOrigin: localOrigin, remoteOrigin: remoteOrigin,
                                listens: !peer.isInitiator, key: peer.key, localUpdate: { [unowned self] in
                PeerQuietUpdate(origin: localOrigin, revision: MacCredentials.nextSequence(),
                                quiet: !self.quitting && self.enabled && self.inputState.needsQuiet &&
                                       self.macPeerAllowed.contains(source),
                                validUntil: Int64(Date().timeIntervalSince1970) + PeerTiming.leaseSeconds,
                                key: peer.key)
            }, receiveUpdate: { [unowned self] update in
                (self.receivePeerState(update, key: peer.key, expectedOrigin: remoteOrigin,
                                       allowed: self.macPeerAllowed.contains(source)), nil)
            }, verifiedChanged: { [unowned self] verified in
                if verified { self.macPeerVerified.insert(source) }
                else { self.macPeerVerified.remove(source) }
                self.directMacCount = self.macPeerVerified.count
                self.refreshMacPeerSpaces()
                if verified { self.macWifiPeers[source]?.sendCurrentState() }
            }, onIssue: { [unowned self] issue in
                if let issue { self.macPairStatus = "Mac 链路：\(issue)" }
            })
            macWifiPeers[source] = link
            link.start()
        }
        refreshMacPeerSpaces()
    }

    private func refreshMacPeerSpaces() {
        let now = Int64(Date().timeIntervalSince1970)
        var next = Set<String>()
        for source in macWifiPeers.keys {
            var gate = macPeerGates[source] ?? SpaceGate()
            // Mac-to-Mac has no BLE proof; AND mode must remain closed.
            if gate.allows(spaceMode, ble: false, wifi: macPeerVerified.contains(source), at: now) {
                next.insert(source)
            }
            macPeerGates[source] = gate
        }
        let removed = macPeerAllowed.subtracting(next)
        guard next != macPeerAllowed else { return }
        macPeerAllowed = next
        for source in removed {
            let change = peerLedger.stopResponding(to: source, at: now)
            if change.ended { localOutput?.finish(manualAtEnd: change.manualAtEnd) }
        }
        if !removed.isEmpty { persistPeerLedger() }
        publishLocalDemand()
    }

    private func publishLocalDemand() {
        client?.setDesired(enabled && inputState.needsQuiet && spaceAllowed)
        wifiPeer?.sendCurrentState()
        for peer in macWifiPeers.values { peer.sendCurrentState() }
    }

    private func refreshSpace() {
        let allowed = spaceGate.allows(spaceMode, ble: bleReachable, wifi: wifiVerified,
                                       at: Int64(Date().timeIntervalSince1970))
        guard allowed != spaceAllowed else { return }
        spaceAllowed = allowed
        if !allowed {
            if let activePadKey {
                let change = peerLedger.stopResponding(to: sourceID(for: activePadKey),
                                                      at: Int64(Date().timeIntervalSince1970))
                persistPeerLedger()
                if change.ended { localOutput?.finish(manualAtEnd: change.manualAtEnd) }
            }
        }
        publishLocalDemand()
    }

    private func receivePeerState(_ update: PeerQuietUpdate, key: Data,
                                  expectedOrigin: String, allowed: Bool) -> String {
        let now = Int64(Date().timeIntervalSince1970)
        guard enabled && !quitting else { return "paused" }
        guard allowed else { return "outsideSpace" }
        let source = sourceID(for: key)
        let change = peerLedger.accept(update, from: source, expectedOrigin: expectedOrigin, key: key, at: now)
        persistPeerLedger()
        if change.ended {
            localOutput?.finish(manualAtEnd: change.manualAtEnd)
            lastAction = change.manualAtEnd ? "保留了你手动调整的 Mac 音量" : "Mac 音量正在恢复"
            return change.manualAtEnd ? "preservedManual" : "restoring"
        }
        if change.started {
            let result = localOutput?.begin(target: Float(macTarget)) ?? "outputUnsupported"
            lastAction = "Mac 音量：\(result)"
            return result
        }
        return change.activeCount > 0 ? "alreadyQuiet" : "alreadyRestored"
    }

    private func expirePeerRequests() {
        let change = peerLedger.expire(at: Int64(Date().timeIntervalSince1970))
        guard change.ended else { return }
        persistPeerLedger()
        localOutput?.finish(manualAtEnd: change.manualAtEnd)
        lastAction = change.manualAtEnd ? "保留了你手动调整的 Mac 音量" : "远端请求超时，Mac 音量正在恢复"
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        preferences.set(value, forKey: "coordinationEnabled")
        publishLocalDemand()
        if !value {
            let change = peerLedger.stopResponding(at: Int64(Date().timeIntervalSince1970))
            persistPeerLedger()
            if change.ended { localOutput?.finish(manualAtEnd: change.manualAtEnd) }
        }
    }

    func setSpaceMode(_ mode: SpaceMode) {
        spaceMode = mode
        preferences.set(mode.rawValue, forKey: "spaceMode")
        spaceGate.reset()
        macPeerGates.removeAll()
        refreshSpace()
        refreshMacPeerSpaces()
        publishLocalDemand()
    }

    func macTargetEditChanged(_ editing: Bool) {
        if !editing { preferences.set(macTarget, forKey: "localOutputTarget") }
    }

    func refreshSources() {
        virtualMicrophoneAvailable = VirtualMicrophone() != nil
        do { sources = try availableSources() }
        catch { errorMessage = "无法列出应用：\(error.localizedDescription)" }
    }

    func toggleExclusion(_ source: SourceCandidate) {
        _ = setExcluded(source.selector, add: !source.isExcluded)
    }

    private func setExcluded(_ selector: String, add: Bool) -> Bool {
        do {
            try ExclusionStore.change(selector, add: add)
            refreshSources()
            input?.poll()
            return true
        } catch {
            errorMessage = "无法保存排除设置：\(error.localizedDescription)"
            return false
        }
    }

    func toggleMute(_ source: SourceCandidate) {
        _ = setMuted(source.selector, add: !source.isMuted)
    }

    private func setMuted(_ selector: String, add: Bool) -> Bool {
        do {
            try MuteStore.change(selector, add: add)
            refreshSources()
            input?.poll()
            return true
        } catch {
            errorMessage = "无法保存麦克风静音设置：\(error.localizedDescription)"
            return false
        }
    }

    func chooseApp() { chooseApp(mute: false) }
    func chooseMutedApp() { chooseApp(mute: true) }

    private func chooseApp(mute: Bool) {
        let panel = NSOpenPanel()
        panel.message = mute ? "选择使用虚拟麦克风时要静音的 Mac 应用" : "选择不参与 iPad 音量协同的 Mac 应用"
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
                if mute { _ = self.setMuted("bundle:\(bundle)", add: true) }
                else { _ = self.setExcluded("bundle:\(bundle)", add: true) }
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
        credentialLoadGeneration += 1
        pairingGeneration += 1
        let generation = pairingGeneration
        pairClient?.stop()
        clientGeneration += 1
        client?.setDesired(false)
        client?.stop()
        client = nil
        connectionState = .message("正在配对")
        showPairing = true
        nearbyPads = []
        pairingCodeInput = ""
        pairingAwaitingCode = false
        pairingPadName = ""
        pairingActive = true
        pairingStatus = "正在查找附近的 iPad"
        errorMessage = ""
        pairClient = PairClient(onDevices: { [weak self] devices in
            guard let self, self.pairingGeneration == generation else { return }
            self.nearbyPads = devices
        }, onStatus: { [weak self] status in
            guard let self, self.pairingGeneration == generation else { return }
            self.pairingStatus = status
        }, onNeedCode: { [weak self] name in
            guard let self, self.pairingGeneration == generation else { return }
            self.pairingPadName = name
            self.pairingAwaitingCode = true
        }, onComplete: { [weak self] key in
            guard let self, self.pairingGeneration == generation else { return }
            self.pairingGeneration += 1
            self.pairClient = nil
            self.pairingActive = false
            self.pairingCodeInput = ""
            self.pairingAwaitingCode = false
            do {
                let deadline = try MacCredentials.stagePairing(key)
                self.pendingKey = key
                self.pendingExpiresAt = deadline
                self.pairingStatus = "验证码已通过，正在验证新密钥"
                self.useKey(key)
            } catch {
                self.restorePreviousPairing()
                self.errorMessage = "无法保存新配对：\(error.localizedDescription)"
            }
        }, onFailure: { [weak self] message in
            guard let self, self.pairingGeneration == generation else { return }
            self.pairingGeneration += 1
            self.pairClient = nil
            self.pairingActive = false
            self.pairingStatus = message
            self.pairingCodeInput = ""
            self.pairingAwaitingCode = false
            self.restorePreviousPairing()
            self.errorMessage = message
        })
    }

    func choosePad(_ id: UUID) { pairClient?.choose(id) }
    @discardableResult func submitPairingCode(_ code: String) -> Bool {
        guard pairingAwaitingCode, let pairClient else {
            pairingStatus = "请先选择处于配对模式的 iPad"
            return false
        }
        do {
            try pairClient.enterCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
            pairingCodeInput = ""
            pairingAwaitingCode = false
            return true
        } catch {
            pairingStatus = error.localizedDescription
            return false
        }
    }

    func cancelPairing() {
        pairingGeneration += 1
        pairClient?.reject()
        pairClient = nil
        pairingActive = false
        pairingCodeInput = ""
        pairingAwaitingCode = false
        restorePreviousPairing()
        showPairing = false
    }

    func offerMacPairing() {
        cancelMacPairing()
        do {
            let server = try MacPairServer(onStatus: { [weak self] status in
                self?.macPairStatus = status
                if status == "Mac 配对已超时" { self?.macPairCode = nil; self?.macPairServer = nil }
            }, onComplete: { [weak self] key, name in
                try MacCredentials.addMacPeer(key: key, name: name, isInitiator: false)
                self?.startMacPeers()
                self?.macPairCode = nil
            })
            macPairServer = server
            macPairCode = server.code
            macPairStatus = "在另一台 Mac 输入此验证码，有效期 2 分钟"
            try server.start()
        } catch {
            cancelMacPairing()
            macPairStatus = "无法开始 Mac 配对：\(error.localizedDescription)"
        }
    }

    func browseMacPairing() {
        cancelMacPairing()
        macPairBrowsing = true
        let browser = MacPairClient(onDevices: { [weak self] devices in
            self?.nearbyMacs = devices
        }, onStatus: { [weak self] status in
            self?.macPairStatus = status
            if status.hasPrefix("Mac 配对连接中断") { self?.macPairAwaitingCode = false }
            if status == "Mac 配对已超时" { self?.cancelMacPairing() }
        }, onReadyForCode: { [weak self] in
            self?.macPairAwaitingCode = true
            self?.macPairStatus = "请输入另一台 Mac 显示的验证码"
        }, onComplete: { [weak self] key, name in
            try MacCredentials.addMacPeer(key: key, name: name, isInitiator: true)
            self?.startMacPeers()
            self?.macPairBrowsing = false
            self?.macPairAwaitingCode = false
        })
        macPairClient = browser
        browser.start()
    }

    func chooseMac(_ id: String) { macPairClient?.choose(id) }

    func submitMacPairCode() {
        guard let macPairClient, macPairAwaitingCode else { return }
        do {
            try macPairClient.enterCode(macPairCodeInput.trimmingCharacters(in: .whitespacesAndNewlines))
            macPairCodeInput = ""
            macPairAwaitingCode = false
        } catch { macPairStatus = error.localizedDescription }
    }

    func cancelMacPairing() {
        macPairServer?.stop()
        macPairServer = nil
        macPairClient?.stop()
        macPairClient = nil
        macPairCode = nil
        macPairCodeInput = ""
        macPairAwaitingCode = false
        macPairBrowsing = false
        nearbyMacs = []
    }

    private func restorePreviousPairing() {
        if let currentKey { useKey(currentKey) }
        else { useKey(nil) }
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

    private func controlStatus() -> ControlStatus {
        ControlStatus(connection: connection, paired: paired, enabled: enabled, inputCount: inputCount,
                      inputError: inputError,
                      lastAction: lastAction, lastAckSequence: lastAckSequence,
                      target: targetKnown ? target : nil,
                      loginEnabled: loginEnabled, pairingActive: pairingActive,
                      pairingStatus: pairingStatus, pairingAwaitingCode: pairingAwaitingCode,
                      pairingPadName: pairingPadName,
                      pairingPendingActivation: pendingKey != nil,
                      nearbyPads: nearbyPads.map { .init(id: $0.id, name: $0.name) },
                      sources: sources.map { .init(selector: $0.selector, name: $0.name,
                                                   excluded: $0.isExcluded, muted: $0.isMuted,
                                                   active: $0.isActive) },
                      error: errorMessage)
    }

    private func handleControl(_ request: ControlRequest) -> ControlResponse {
        var problem: String?
        switch request.command {
        case "status": refreshSources()
        case "pair.start":
            beginPairing()
            if !pairingActive { problem = errorMessage }
        case "pair.cancel": cancelPairing()
        case "pair.choose":
            if let value = request.value, let id = UUID(uuidString: value),
               nearbyPads.contains(where: { $0.id == id }), pairingActive { choosePad(id) }
            else { problem = "设备不在当前扫描列表或配对未启动" }
        case "pair.code":
            if let value = request.value, !submitPairingCode(value) { problem = pairingStatus }
            else if request.value == nil { problem = "请输入 6 位验证码" }
        case "enabled.on": setEnabled(true)
        case "enabled.off": setEnabled(false)
        case "exclude.add", "exclude.remove":
            if let value = request.value, let selector = ExclusionStore.normalized(value) {
                if !setExcluded(selector, add: request.command == "exclude.add") { problem = errorMessage }
            } else { problem = "应用标识无效" }
        case "mute.add", "mute.remove":
            if let value = request.value, let selector = ExclusionStore.normalized(value) {
                if !setMuted(selector, add: request.command == "mute.add") { problem = errorMessage }
            } else { problem = "应用标识无效" }
        case "target.set":
            if let value = request.value, let number = Double(value), (0...0.5).contains(number) {
                target = number
                targetEditChanged(false)
            } else { problem = "目标音量须为 0 到 0.5" }
        default: problem = "未知命令"
        }
        return ControlResponse(ok: problem == nil, message: problem, status: controlStatus())
    }

    func targetEditChanged(_ editing: Bool) {
        targetEditing = editing
        if !editing {
            pendingTargetMilli = Int((target * 1000).rounded())
            client?.setTargetMilli(pendingTargetMilli!)
            wifiPeer?.sendCurrentState()
        }
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
        quitting = true
        cancelMacPairing()
        pairingGeneration += 1
        pairClient?.stop()
        client?.setDesired(false)
        wifiPeer?.sendCurrentState()
        for peer in macWifiPeers.values { peer.sendCurrentState() }
        let change = peerLedger.stopResponding(at: Int64(Date().timeIntervalSince1970))
        persistPeerLedger()
        if change.ended { localOutput?.finish(manualAtEnd: change.manualAtEnd) }
        clientGeneration += 1
        connectionState = .message("正在恢复音量并退出")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.client?.stop()
            self?.wifiPeer?.stop()
            self?.macWifiPeers.values.forEach { $0.stop() }
            NSApp.terminate(nil)
        }
    }
}
