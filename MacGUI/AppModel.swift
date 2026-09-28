import AppKit
import CoreGraphics
import Foundation
import os
import ServiceManagement
import UniformTypeIdentifiers

struct MacPeerDisplay: Identifiable, Equatable {
    let id: String
    let name: String
    let authenticated: Bool
    let spaceAllowed: Bool
    var status: String {
        "\(name)：\(authenticated ? "Wi-Fi 已认证" : "未连接") · \(spaceAllowed ? (authenticated ? "允许协同" : "短断连宽限") : "等待空间条件")"
    }
}

struct PadPeerDisplay: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let connected: Bool
    let spaceAllowed: Bool
    let target: Double
    let targetKnown: Bool
}

@MainActor private final class PadPeerSession {
    let id: String
    let key: Data
    var name: String
    var peripheralID: UUID?
    var connectionState = BLEConnectionState.message("正在连接")
    var bleReachable = false
    var wifiVerified = false
    var wifiIssue: String?
    var spaceGate = SpaceGate()
    var spaceAllowed = false
    var target = 0.0
    var targetKnown = false
    var targetEditing = false
    var pendingTargetMilli: Int?
    var lastAckSequence: UInt64?
    var client: BLEClient?
    var wifiPeer: WiFiPeer?

    init(id: String, key: Data, name: String, peripheralID: UUID?) {
        self.id = id
        self.key = key
        self.name = name
        self.peripheralID = peripheralID
    }

    func stop() {
        client?.stop()
        wifiPeer?.stop()
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var lastAction = "尚无音量操作"
    @Published private(set) var lastAckSequence: UInt64?
    @Published private(set) var sources = [SourceCandidate]()
    @Published private(set) var sourceActivityUnknown = false
    @Published private(set) var virtualMicrophoneAvailable = false
    @Published private(set) var microphoneShortcuts = [String: MicrophoneHotKey]()
    @Published private(set) var sharedShortcutEnabled: Bool
    @Published private(set) var sharedShortcutActive = false
    @Published private(set) var recordingShortcutFor: String?
    @Published private(set) var shortcutMessage = ""
    @Published private(set) var diagnosticMessage = ""
    @Published private(set) var inputState = InputObservation.active(0)
    @Published private(set) var paired = false
    @Published private(set) var padPeerDisplays = [PadPeerDisplay]()
    @Published private(set) var loginEnabled = false
    @Published private(set) var nearbyPads = [NearbyPad]()
    @Published private(set) var pairingStatus = ""
    @Published var pairingCodeInput = ""
    @Published private(set) var pairingAwaitingCode = false
    @Published private(set) var pairingPadName = ""
    @Published private(set) var pairingActive = false
    @Published var macTarget = 0.0
    @Published private(set) var spaceMode: SpaceMode
    @Published private(set) var nearbyMacs = [NearbyMac]()
    @Published private(set) var macPairCode: String?
    @Published private(set) var macPairStatus = ""
    @Published private(set) var macPairAwaitingCode = false
    @Published private(set) var macPairBrowsing = false
    @Published private(set) var macPeerCount = 0
    @Published private(set) var macPeerDisplays = [MacPeerDisplay]()
    @Published private(set) var directMacCount = 0
    @Published private(set) var driverInstalling = false
    @Published private(set) var driverInstallStatus = ""
    @Published var macPairCodeInput = ""
    @Published var showPairing = false
    @Published var errorMessage = ""
    @Published private(set) var enabled: Bool

    private let preferences = MacPreferences.defaults
    private let connectionLog = Logger(subsystem: "local.nearbyaudio.mac", category: "connections")
    private let runLock = RunLock()
    private var padSessions = [String: PadPeerSession]()
    private var macPairServer: MacPairServer?
    private var macPairClient: MacPairClient?
    private var macWifiPeers = [String: WiFiPeer]()
    private var savedMacPeers = [MacCredentials.MacPeer]()
    private var macPeerVerified = Set<String>()
    private var macPeerGates = [String: SpaceGate]()
    private var macPeerAllowed = Set<String>()
    private var quitting = false
    private var pairClient: PairClient?
    private var controlServer: ControlServer?
    private var pendingKey: Data?
    private var pendingExpiresAt: Date?
    private var pendingPadName: String?
    private var pendingPadPeripheralID: UUID?
    private var input: InputActivity?
    private var hotKeys: MicrophoneHotKeys?
    private let muteFeedback = NSSound(named: NSSound.Name("Ping"))
    private var shortcutMonitor: Any?
    private var localOutput: MacQuietVolume?
    private var peerLedger = (MacPreferences.defaults.data(forKey: "peerDemandLedger")
        .flatMap { try? JSONDecoder().decode(PeerDemandLedger.self, from: $0) }) ?? PeerDemandLedger()
    private var timer: Timer?
    private var started = false
    private var pairingGeneration = 0
    private var credentialLoadGeneration = 0

    var localMacName: String { PeerName.display(Host.current().localizedName, fallback: "Mac") }
    var connection: String {
        let statuses = padPeerDisplays.map(\.status) + macPeerDisplays.map(\.status)
        return statuses.isEmpty ? "尚未配对设备" : statuses.joined(separator: "；")
    }
    var isConnected: Bool { padPeerDisplays.contains(where: \.connected) || directMacCount > 0 }
    var inputCount: Int { inputState.count }
    var inputError: String? { inputState.error }
    var spaceStatus: String {
        let allowed = padPeerDisplays.filter(\.spaceAllowed).count + macPeerAllowed.count
        return "\(allowed) / \(padPeerDisplays.count + macPeerCount) 台设备满足空间条件"
    }

    var iconName: String {
        if runLock == nil || (padPeerDisplays.isEmpty && macPeerCount == 0) { return "exclamationmark.triangle.fill" }
        if !enabled { return "waveform.slash" }
        if !isConnected { return "exclamationmark.circle" }
        return inputCount > 0 ? "waveform.circle.fill" : "waveform"
    }

    private func recordConnection(_ event: String) {
        connectionLog.notice("event=\(event, privacy: .public) pid=\(getpid()) app=\(Bundle.main.bundleURL.path, privacy: .public) padPaired=\(self.padPeerDisplays.count) padAllowed=\(self.padPeerDisplays.filter(\.spaceAllowed).count) macPaired=\(self.macPeerCount) macVerified=\(self.directMacCount) macAllowed=\(self.macPeerAllowed.count)")
    }

    init() {
        enabled = preferences.object(forKey: "coordinationEnabled") as? Bool ?? true
        sharedShortcutEnabled = preferences.bool(forKey: "shareMicrophoneHotKeys")
        spaceMode = SpaceMode(rawValue: preferences.string(forKey: "spaceMode") ?? "") ?? .nearbyOrWiFi
        macTarget = preferences.object(forKey: "localOutputTarget") as? Double ?? 0
        loginEnabled = SMAppService.mainApp.status == .enabled
        guard runLock != nil else {
            Task { @MainActor in NSApp.terminate(nil) }
            return
        }
        Task { @MainActor [weak self] in self?.start() }
    }

    func start() {
        guard !started, runLock != nil else { return }
        started = true
        recordConnection("startup")
        do {
            controlServer = try ControlServer { [weak self] request in
                self?.handleControl(request) ?? ControlResponse(ok: false, message: "应用正在退出", status: nil)
            }
        } catch { errorMessage = "本机控制入口不可用：\(error.localizedDescription)" }
        refreshSources()
        restoreMicrophoneShortcuts()
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
        let generation = credentialLoadGeneration
        Task.detached { [weak self] in
            do {
                let peers = try MacCredentials.padPeers()
                var pending: (key: Data, expiresAt: Date, name: String?, peripheralID: UUID?)?
                var pendingError: String?
                do { pending = try MacCredentials.pendingPairing() }
                catch { pendingError = "无法读取待激活配对：\(error.localizedDescription)" }
                await self?.loadedKeys(peers, pending: pending, errorMessage: pendingError, generation: generation)
            } catch {
                await self?.startupFailed(error.localizedDescription, generation: generation)
            }
        }
    }

    private func loadedKeys(_ peers: [MacCredentials.PadPeer],
                            pending: (key: Data, expiresAt: Date, name: String?, peripheralID: UUID?)?,
                            errorMessage: String?, generation: Int) {
        guard generation == credentialLoadGeneration else { return }
        startMacPeers()
        for peer in peers { startPadPeer(peer) }
        if let pending {
            pendingKey = pending.key
            pendingExpiresAt = pending.expiresAt
            pendingPadName = pending.name
            pendingPadPeripheralID = pending.peripheralID
            pairingStatus = "正在验证上次的新配对"
            startPadPeer(.init(key: pending.key,
                               name: PeerName.display(pending.name, fallback: "iPad"),
                               peripheralID: pending.peripheralID))
        }
        if let errorMessage { self.errorMessage = errorMessage }
        recordConnection("credentials-loaded")
    }

    private func startupFailed(_ message: String, generation: Int) {
        guard generation == credentialLoadGeneration else { return }
        startMacPeers()
        errorMessage = message
        recordConnection("peer-keychain-read-failed")
    }

    private func refreshPadDisplays() {
        let displays: [PadPeerDisplay] = padSessions.values.map { session in
            let link = session.bleReachable ? "蓝牙已认证" : session.wifiVerified ? "Wi-Fi 已认证" : session.connectionState.text
            let space = session.spaceAllowed
                ? (session.bleReachable || session.wifiVerified ? "允许协同" : "短断连宽限")
                : "等待空间条件"
            return PadPeerDisplay(id: session.id, name: session.name,
                                  status: "\(session.name)：\(link) · \(space)",
                                  connected: session.bleReachable || session.wifiVerified,
                                  spaceAllowed: session.spaceAllowed, target: session.target,
                                  targetKnown: session.targetKnown)
        }.sorted { (left: PadPeerDisplay, right: PadPeerDisplay) in
            let order = left.name.localizedCaseInsensitiveCompare(right.name)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
        if displays != padPeerDisplays { padPeerDisplays = displays }
        paired = !displays.isEmpty
    }

    private func startPadPeer(_ peer: MacCredentials.PadPeer) {
        let id = sourceID(for: peer.key)
        if let existing = padSessions[id] {
            existing.name = peer.name
            existing.peripheralID = peer.peripheralID
            refreshPadDisplays()
            return
        }
        let session = PadPeerSession(id: id, key: peer.key, name: peer.name,
                                     peripheralID: peer.peripheralID)
        padSessions[id] = session
        refreshPadDisplays()
        session.client = BLEClient(key: peer.key, targetPeripheralID: peer.peripheralID,
            onStatus: { [weak self, weak session] status in
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.padSessions[id] === session else { return }
                    session.connectionState = status
                    session.bleReachable = status.isReady
                    self.refreshPadSpace(session)
                }
            }, onAck: { [weak self, weak session] ack in
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.padSessions[id] === session else { return }
                    self.accept(ack, session: session)
                }
            }, onPeerAck: { [weak self, weak session] ack in
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.padSessions[id] === session else { return }
                    self.acceptPeerAck(ack, session: session)
                }
            }, onPeerState: { [weak self, weak session] update, done in
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.padSessions[id] === session else { done("stale"); return }
                    done(self.receivePeerState(update, key: session.key,
                                               expectedOrigin: "ipad", allowed: session.spaceAllowed))
                }
            }, onAuthenticated: { [weak self, weak session] peripheralID in
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.padSessions[id] === session,
                          session.peripheralID == nil else { return }
                    do {
                        try MacCredentials.updatePadPeripheralID(session.key, peripheralID: peripheralID)
                        session.peripheralID = peripheralID
                    } catch { self.errorMessage = "无法保存设备标识：\(error.localizedDescription)" }
                }
            })
        session.wifiPeer = WiFiPeer(localOrigin: "mac", remoteOrigin: "ipad", listens: true,
            key: peer.key, localUpdate: { [unowned self, unowned session] in
                PeerQuietUpdate(origin: "mac", revision: MacCredentials.nextSequence(),
                                quiet: !self.quitting && self.enabled && self.inputState.needsQuiet && session.spaceAllowed,
                                validUntil: Int64(Date().timeIntervalSince1970) + PeerTiming.leaseSeconds,
                                targetMilli: session.pendingTargetMilli, key: session.key)
            }, receiveUpdate: { [unowned self, unowned session] update in
                (self.receivePeerState(update, key: session.key, expectedOrigin: "ipad",
                                       allowed: session.spaceAllowed), nil)
            }, receiveAck: { [unowned self, unowned session] ack in
                self.acceptPeerAck(ack, session: session)
            }, verifiedChanged: { [unowned self, unowned session] verified in
                session.wifiVerified = verified
                self.refreshPadSpace(session)
            }, onIssue: { [unowned self, unowned session] issue in
                session.wifiIssue = issue
                if let issue { self.errorMessage = "\(session.name) Wi-Fi：\(issue)" }
            })
        session.wifiPeer?.start()
        publishLocalDemand()
    }

    private func removePadSession(for key: Data) {
        let id = sourceID(for: key)
        guard let session = padSessions.removeValue(forKey: id) else { return }
        session.stop()
        let change = peerLedger.stopResponding(to: id, at: Int64(Date().timeIntervalSince1970))
        persistPeerLedger()
        if change.ended { localOutput?.finish(manualAtEnd: change.manualAtEnd) }
        refreshPadDisplays()
    }

    private func accept(_ ack: ControlAck, session: PadPeerSession) {
        promotePendingPairing(session.key)
        guard ack.sequence >= (session.lastAckSequence ?? 0) else { return }
        session.lastAckSequence = ack.sequence
        lastAckSequence = max(lastAckSequence ?? 0, ack.sequence)
        if session.pendingTargetMilli == ack.targetMilli { session.pendingTargetMilli = nil }
        if !session.targetEditing, (0...500).contains(ack.targetMilli) {
            session.target = Double(ack.targetMilli) / 1000
            session.targetKnown = true
            refreshPadDisplays()
        }
        switch ack.result {
        case "applied": lastAction = "\(session.name) 媒体音量已降低至 \(ack.volumeMilli)‰"
        case "restored": lastAction = "\(session.name) 媒体音量已恢复至 \(ack.volumeMilli)‰"
        case "preservedManualOrRoute": lastAction = "保留了你手动调整的音量或新输出设备"
        case "alreadyRestored": lastAction = "\(session.name) 音量保持原状"
        default: lastAction = "\(session.name) 回执：\(ack.result)"
        }
    }

    private func promotePendingPairing(_ key: Data) {
        if pendingKey == key {
            do {
                // Keep the old key until the iPad proves it accepted the new one.
                let confirmedName = PeerName.display(pendingPadName ?? pairingPadName, fallback: "iPad")
                try MacCredentials.promotePairing(key, name: confirmedName,
                                                  peripheralID: pendingPadPeripheralID)
                pendingKey = nil
                pendingExpiresAt = nil
                pendingPadName = nil
                pendingPadPeripheralID = nil
                preferences.set(sourceID(for: key), forKey: "pairedPadIdentity")
                preferences.set(confirmedName, forKey: "pairedPadName")
                padSessions[sourceID(for: key)]?.name = confirmedName
                refreshPadDisplays()
                pairingStatus = "配对完成，\(confirmedName) 已接受新密钥"
            } catch {
                errorMessage = "iPad 已接受新配对，但 Mac 保存失败：\(error.localizedDescription)"
                pairingStatus = errorMessage
            }
        }
    }

    private func acceptPeerAck(_ ack: PeerStateAck, session: PadPeerSession) {
        promotePendingPairing(session.key)
        guard ack.revision >= (session.lastAckSequence ?? 0) else { return }
        session.lastAckSequence = ack.revision
        lastAckSequence = max(lastAckSequence ?? 0, ack.revision)
        if session.pendingTargetMilli == ack.targetMilli { session.pendingTargetMilli = nil }
        session.client?.confirmTargetMilli(ack.targetMilli)
        if !session.targetEditing, let milli = ack.targetMilli, (0...500).contains(milli) {
            session.target = Double(milli) / 1000
            session.targetKnown = true
            refreshPadDisplays()
        }
        switch ack.result {
        case "applied": lastAction = "\(session.name) 媒体音量已降低"
        case "restored": lastAction = "\(session.name) 媒体音量正在恢复"
        case "preservedManualOrRoute": lastAction = "保留了你手动调整的音量或新输出设备"
        case "alreadyRestored": lastAction = "\(session.name) 音量保持原状"
        default: lastAction = "\(session.name) 回执：\(ack.result)"
        }
    }

    private func persistPeerLedger() {
        preferences.set(try? JSONEncoder().encode(peerLedger), forKey: "peerDemandLedger")
    }

    private func sourceID(for key: Data) -> String { Authentication.sign("paired-peer-id", key: key) }

    private func startMacPeers() {
        let peers: [MacCredentials.MacPeer]
        do { peers = try MacCredentials.macPeers() }
        catch {
            errorMessage = "无法读取 Mac 配对：\(error.localizedDescription)"
            recordConnection("mac-keychain-read-failed")
            return
        }
        savedMacPeers = peers
        macPeerCount = peers.count
        recordConnection("mac-credentials-loaded")
        for (index, peer) in peers.enumerated() {
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
                self.recordConnection(verified ? "mac-peer-\(index)-verified" : "mac-peer-\(index)-disconnected")
                if verified { self.macWifiPeers[source]?.sendCurrentState() }
            }, onIssue: { [unowned self] issue in
                if let issue { self.macPairStatus = "\(peer.name) 链路：\(issue)" }
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
        let changed = next != macPeerAllowed
        macPeerAllowed = next
        let displays = savedMacPeers.map { peer in
            let id = sourceID(for: peer.key)
            return MacPeerDisplay(id: id, name: peer.name,
                authenticated: macPeerVerified.contains(id), spaceAllowed: next.contains(id))
        }
        if displays != macPeerDisplays { macPeerDisplays = displays }
        guard changed else { return }
        for source in removed {
            let change = peerLedger.stopResponding(to: source, at: now)
            if change.ended { localOutput?.finish(manualAtEnd: change.manualAtEnd) }
        }
        if !removed.isEmpty { persistPeerLedger() }
        publishLocalDemand()
    }

    private func publishLocalDemand() {
        for session in padSessions.values {
            session.client?.setDesired(enabled && inputState.needsQuiet && session.spaceAllowed)
            session.wifiPeer?.sendCurrentState()
        }
        for peer in macWifiPeers.values { peer.sendCurrentState() }
    }

    private func refreshSpace() {
        for session in padSessions.values { refreshPadSpace(session) }
    }

    private func refreshPadSpace(_ session: PadPeerSession) {
        let allowed = session.spaceGate.allows(spaceMode, ble: session.bleReachable,
                                               wifi: session.wifiVerified,
                                               at: Int64(Date().timeIntervalSince1970))
        guard allowed != session.spaceAllowed else { refreshPadDisplays(); return }
        session.spaceAllowed = allowed
        refreshPadDisplays()
        if !allowed {
            let change = peerLedger.stopResponding(to: session.id,
                                                  at: Int64(Date().timeIntervalSince1970))
            persistPeerLedger()
            if change.ended { localOutput?.finish(manualAtEnd: change.manualAtEnd) }
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
            lastAction = change.manualAtEnd ? "保留了你手动调整的 \(localMacName) 音量" : "\(localMacName) 音量正在恢复"
            return change.manualAtEnd ? "preservedManual" : "restoring"
        }
        if change.started {
            let result = localOutput?.begin(target: Float(macTarget)) ?? "outputUnsupported"
            lastAction = "\(localMacName) 音量：\(result)"
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
        for device in (try? MicrophoneStore.load()) ?? [] {
            AudioForensics.shared.event(device.selector, "coordination-changed", ["enabled": value])
        }
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
        for session in padSessions.values { session.spaceGate.reset() }
        macPeerGates.removeAll()
        refreshSpace()
        refreshMacPeerSpaces()
        publishLocalDemand()
    }

    func macTargetEditChanged(_ editing: Bool) {
        if !editing { preferences.set(macTarget, forKey: "localOutputTarget") }
    }

    func refreshSources() {
        virtualMicrophoneAvailable = VirtualMicrophone.pluginID != nil
        let active = activeInputPIDs()
        sourceActivityUnknown = active == nil
        do { sources = try availableSources(active: active ?? []) }
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

    private func toggleMute(_ selector: String) {
        do {
            if setMuted(selector, add: !(try MuteStore.load()).contains(selector)), !sharedShortcutEnabled {
                muteFeedback?.stop()
                muteFeedback?.currentTime = 0
                muteFeedback?.play()
            }
        }
        catch { errorMessage = "无法读取麦克风静音设置：\(error.localizedDescription)" }
    }

    var sharedShortcutStatus: String {
        if !sharedShortcutEnabled { return "当前使用系统热键；同组合的前台应用内快捷键可能收不到按键。" }
        if microphoneShortcuts.isEmpty { return "共享模式已选定；录入快捷键后才开始监听。" }
        if sharedShortcutActive {
            return "共享模式运行中：macOS 会交付所有按键按下事件；Nearby 只处理已配置组合，不记录其他按键。"
        }
        return "共享模式等待授权：请在系统设置 → 隐私与安全性 → 输入监控中允许 Nearby Audio；此期间 Nearby 快捷键不可用。授权后点“重新检查授权”。"
    }

    func setSharedShortcutEnabled(_ value: Bool) {
        guard value != sharedShortcutEnabled else { return }
        cancelShortcutRecording()
        hotKeys = nil
        sharedShortcutActive = false
        sharedShortcutEnabled = value
        preferences.set(value, forKey: "shareMicrophoneHotKeys")
        if value { _ = CGRequestListenEventAccess() }
        activateMicrophoneShortcuts()
    }

    func retrySharedShortcutAuthorization() { activateMicrophoneShortcuts() }

    private func restoreMicrophoneShortcuts() {
        do {
            let devices = Set(try MicrophoneStore.load().map(\.selector))
            var saved = try HotKeyStore.load()
            saved = saved.filter { devices.contains($0.key) }
            try HotKeyStore.save(saved)
            microphoneShortcuts = saved
            activateMicrophoneShortcuts()
        } catch { shortcutMessage = "无法恢复麦克风快捷键：\(error.localizedDescription)" }
    }

    private func activateMicrophoneShortcuts() {
        hotKeys = nil // Deinitialization unregisters Carbon before a passive tap can start.
        sharedShortcutActive = false
        shortcutMessage = ""
        if microphoneShortcuts.isEmpty { return }
        do {
            let manager = try MicrophoneHotKeys(usePassiveTap: sharedShortcutEnabled) { [weak self] selector in
                Task { @MainActor [weak self] in self?.toggleMute(selector) }
            }
            for (selector, shortcut) in microphoneShortcuts {
                do { try manager.register(shortcut, for: selector) }
                catch { shortcutMessage = "\(selector) 的快捷键无法启用：\(error.localizedDescription)" }
            }
            hotKeys = manager
            sharedShortcutActive = manager.usesPassiveTap
        } catch { shortcutMessage = "快捷键未启用：\(error.localizedDescription)" }
    }

    func recordShortcut(for source: SourceCandidate) {
        cancelShortcutRecording()
        recordingShortcutFor = source.selector
        shortcutMessage = "请按至少两个修饰键（⌃、⌥、⌘）和一个字母或数字；Esc 取消。"
        NSApp.activate(ignoringOtherApps: true)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recordingShortcutFor == source.selector else { return event }
            if event.keyCode == 53 { self.cancelShortcutRecording(); return nil }
            guard !event.isARepeat else { return nil }
            guard let shortcut = MicrophoneHotKey(event: event) else {
                self.shortcutMessage = "组合不可用：请用至少两个修饰键加字母或数字，避开系统保留键。"
                return nil
            }
            self.setShortcut(shortcut, for: source.selector)
            return nil
        }
    }

    func cancelShortcutRecording() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        recordingShortcutFor = nil
        shortcutMessage = ""
    }

    private func setShortcut(_ shortcut: MicrophoneHotKey, for selector: String) {
        guard !microphoneShortcuts.contains(where: { $0.key != selector &&
            $0.value.keyCode == shortcut.keyCode && $0.value.modifiers == shortcut.modifiers }) else {
            shortcutMessage = "该组合已分配给另一台专用麦克风。"
            return
        }
        do {
            var updated = microphoneShortcuts
            updated[selector] = shortcut
            try HotKeyStore.save(updated)
            microphoneShortcuts = updated
            cancelShortcutRecording()
            activateMicrophoneShortcuts()
        } catch {
            shortcutMessage = "无法设置快捷键：\(error.localizedDescription)"
        }
    }

    func clearShortcut(for selector: String) {
        var updated = microphoneShortcuts
        updated.removeValue(forKey: selector)
        do {
            try HotKeyStore.save(updated)
            microphoneShortcuts = updated
            if recordingShortcutFor == selector { cancelShortcutRecording() }
            activateMicrophoneShortcuts()
        } catch { shortcutMessage = "无法清除快捷键：\(error.localizedDescription)" }
    }

    private func setMuted(_ selector: String, add: Bool) -> Bool {
        do {
            guard try MicrophoneStore.load().contains(where: { $0.selector == selector }) else {
                throw NSError(domain: "NearbyAudio", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "请先为该应用添加专用麦克风"])
            }
            try MuteStore.change(selector, add: add)
            AudioForensics.shared.event(selector, "mute-changed", ["muted": add])
            refreshSources()
            input?.poll()
            return true
        } catch {
            errorMessage = "无法保存麦克风静音设置：\(error.localizedDescription)"
            return false
        }
    }

    func removeMicrophone(_ source: SourceCandidate) {
        _ = setMicrophone(source.selector, name: source.name, add: false)
    }

    func microphoneSourceDescription(for selector: String) -> String {
        guard let device = try? MicrophoneStore.load().first(where: { $0.selector == selector }) else { return "" }
        let name = device.sourceUID.flatMap { uid in
            PhysicalInputSource.available().first(where: { $0.id == uid })?.name
        } ?? (device.sourceUID == nil ? "系统默认输入（旧设备）" : "上游已断开")
        return "上游：\(name) · \(device.outputSampleRate) Hz / \(device.outputChannels) 声道"
    }

    func changeMicrophoneSource(_ source: SourceCandidate) {
        guard !sourceActivityUnknown && !source.microphoneInUse else {
            errorMessage = sourceActivityUnknown ? "无法确认麦克风是否正在使用，暂不能切换上游。"
                : "请先结束使用 \(source.microphoneName ?? source.name) 的录音，再切换上游。"
            return
        }
        guard let selected = choosePhysicalSource() else { return }
        _ = setMicrophone(source.selector, name: source.name, add: true, selectedSource: selected)
    }

    func forensicDescription(for selector: String) -> String {
        let status = AudioForensics.shared.status(for: selector)
        let minutes = status.coverageSeconds / 60
        let seconds = status.coverageSeconds % 60
        return "取证回看 \(minutes)分\(seconds)秒 · 上游丢块 \(status.droppedSourceBlocks) · 驱动丢块 \(status.droppedDriverBlocks) · 写盘错误 \(status.writeErrors)"
    }

    func forensicWarning(for selector: String) -> String? { AudioForensics.shared.status(for: selector).warning }
    var forensicLocation: String { AudioForensics.shared.location.path }
    var forensicLimitGB: Int { AudioForensics.shared.limitGB }

    func markForensics(_ source: SourceCandidate) {
        AudioForensics.shared.mark(source.selector)
        diagnosticMessage = "已标记 \(source.name) 的现场；取证会持续自动记录。"
    }

    func chooseForensicLocation() {
        guard !sourceActivityUnknown && !sources.contains(where: { $0.microphoneInUse }) else {
            diagnosticMessage = sourceActivityUnknown ? "无法确认麦克风是否正在使用，暂不能更换取证目录。"
                : "请先结束专用麦克风录音，再更换取证目录。"
            return
        }
        let panel = NSOpenPanel()
        panel.message = "选择原始音频取证存储目录；可使用外挂 SSD"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AudioForensics.shared.setLocation(url)
        diagnosticMessage = "后续取证将写入 \(url.path)；旧目录内容保留。"
    }

    func setForensicLimitGB(_ value: Int) {
        AudioForensics.shared.setLimitGB(value)
        diagnosticMessage = "取证存储上限已设为 \(value) GB。"
    }

    func exportForensics() {
        guard !sourceActivityUnknown && !sources.contains(where: { $0.microphoneInUse }) else {
            diagnosticMessage = sourceActivityUnknown ? "无法确认麦克风是否正在使用，暂不能导出诊断包。"
                : "请先结束专用麦克风录音，再导出一致的诊断包；取证数据会自动保存。"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NearbyAudio-Diagnostics.zip"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        diagnosticMessage = "正在导出本地诊断包…"
        AudioForensics.shared.export(to: url) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.diagnosticMessage = error.map { "导出失败：\($0.localizedDescription)" } ?? "诊断包已保存到 \(url.path)"
            }
        }
    }

    private func choosePhysicalSource() -> PhysicalInputSource? {
        let sources = PhysicalInputSource.available()
        guard !sources.isEmpty else {
            errorMessage = "没有可用的单声道或双声道物理麦克风。"
            return nil
        }
        let alert = NSAlert()
        alert.messageText = "选择物理上游麦克风"
        alert.informativeText = "虚拟设备创建时采用所选输入的采样率与声道数；切换不同格式的上游会重建虚拟设备。"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        for source in sources {
            picker.addItem(withTitle: "\(source.name) · \(source.sampleRate) Hz / \(source.channels) 声道\(source.isDefault ? " · 当前默认" : "")")
        }
        picker.selectItem(at: sources.firstIndex(where: \.isDefault) ?? 0)
        alert.accessoryView = picker
        alert.addButton(withTitle: "选择")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? sources[picker.indexOfSelectedItem] : nil
    }

    private func setMicrophone(_ selector: String, name: String, add: Bool,
                               selectedSource: PhysicalInputSource? = nil) -> Bool {
        do {
            guard selector.hasPrefix("bundle:"), VirtualMicrophone.pluginID != nil else {
                throw NSError(domain: "NearbyAudio", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "需要新版驱动和有效的应用 bundle ID"])
            }
            var devices = try MicrophoneStore.load()
            if add {
                if let source = selectedSource ?? (devices.contains(where: { $0.selector == selector }) ? nil :
                    PhysicalInputSource.available().first(where: \.isDefault)) {
                    if let old = devices.firstIndex(where: { $0.selector == selector }) {
                        if let id = VirtualMicrophone.deviceID(uid: devices[old].uid),
                           (activeInputPIDs(on: id)?.isEmpty != true) {
                            throw NSError(domain: "NearbyAudio", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "请先停止使用该专用麦克风，再切换上游"])
                        }
                        devices[old] = DedicatedMicrophone(bundle: String(selector.dropFirst(7)), name: name,
                            sourceUID: source.id, sampleRate: source.sampleRate, channels: source.channels)
                    } else {
                        devices.append(DedicatedMicrophone(bundle: String(selector.dropFirst(7)), name: name,
                            sourceUID: source.id, sampleRate: source.sampleRate, channels: source.channels))
                    }
                } else if !devices.contains(where: { $0.selector == selector }) {
                    throw NSError(domain: "NearbyAudio", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "请先连接并选择物理上游麦克风"])
                }
            } else {
                if let existing = devices.first(where: { $0.selector == selector }),
                   let id = VirtualMicrophone.deviceID(uid: existing.uid) {
                    guard let clients = activeInputPIDs(on: id), clients.isEmpty else {
                        throw NSError(domain: "NearbyAudio", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "请先停止使用该专用麦克风，再移除设备"])
                    }
                }
                devices.removeAll { $0.selector == selector }
                try MuteStore.change(selector, add: false)
            }
            try MicrophoneStore.save(devices)
            if !add { clearShortcut(for: selector) }
            input?.poll()
            refreshSources()
            if errorMessage.hasPrefix("无法更新专用麦克风：") { errorMessage = "" }
            return true
        } catch {
            errorMessage = "无法更新专用麦克风：\(error.localizedDescription)"
            return false
        }
    }

    func installDriver() {
        guard !driverInstalling else { return }
        do {
            let devices = try MicrophoneStore.load()
            for device in devices {
                if let id = VirtualMicrophone.deviceID(uid: device.uid) {
                    guard let users = activeInputPIDs(on: id), users.isEmpty else {
                        driverInstallStatus = "请先停止使用专用麦克风，再安装驱动。"
                        return
                    }
                }
            }
        } catch {
            driverInstallStatus = "无法核对专用麦克风状态：\(error.localizedDescription)"
            return
        }
        guard let helper = Bundle.main.url(forResource: "install-mac-driver", withExtension: "sh"),
              Bundle.main.url(forResource: "NearbyAudioDriver", withExtension: "driver") != nil else {
            driverInstallStatus = "应用未包含已签名驱动，请重新构建 Nearby Audio。"
            return
        }
        let path = helper.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script (\"/bin/sh \" & quoted form of \"\(path)\") with administrator privileges"
        driverInstalling = true
        driverInstallStatus = "等待 macOS 管理员认证…"
        NSApp.activate(ignoringOtherApps: true)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let errors = Pipe()
                process.standardError = errors
                do { try process.run() }
                catch { return error.localizedDescription }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    return String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                }
                return nil
            }.value
            guard let self else { return }
            self.driverInstalling = false
            self.driverInstallStatus = result == nil ? "驱动已安装，音频服务正在恢复。" : "驱动安装未完成：\(result!)"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.refreshSources()
        }
    }

    func addApp(_ url: URL, microphone: Bool) {
        guard let bundle = Bundle(url: url)?.bundleIdentifier else {
            errorMessage = "所选应用没有可用的 bundle ID"
            return
        }
        if microphone {
            guard let source = choosePhysicalSource() else { return }
            _ = setMicrophone("bundle:\(bundle)", name: url.deletingPathExtension().lastPathComponent,
                add: true, selectedSource: source)
        }
        else { _ = setExcluded("bundle:\(bundle)", add: true) }
    }

    func beginPairing() {
        if pendingKey != nil {
            do { try MacCredentials.clearPendingPairing() }
            catch { errorMessage = "无法清除上次待激活配对：\(error.localizedDescription)"; return }
            if let pendingKey { removePadSession(for: pendingKey) }
            pendingKey = nil
            pendingExpiresAt = nil
            pendingPadName = nil
            pendingPadPeripheralID = nil
        }
        pairingGeneration += 1
        let generation = pairingGeneration
        pairClient?.stop()
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
        }, onComplete: { [weak self] key, name, peripheralID in
            guard let self, self.pairingGeneration == generation else { return }
            self.pairingPadName = name
            self.pairingGeneration += 1
            self.pairClient = nil
            self.pairingActive = false
            self.pairingCodeInput = ""
            self.pairingAwaitingCode = false
            do {
                let deadline = try MacCredentials.stagePairing(key, name: name, peripheralID: peripheralID)
                self.pendingKey = key
                self.pendingExpiresAt = deadline
                self.pendingPadName = name
                self.pendingPadPeripheralID = peripheralID
                self.pairingStatus = "验证码已通过，正在验证新密钥"
                self.startPadPeer(.init(key: key, name: name, peripheralID: peripheralID))
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
        if let pendingKey { removePadSession(for: pendingKey) }
        pendingKey = nil
        pendingExpiresAt = nil
        pendingPadName = nil
        pendingPadPeripheralID = nil
    }

    private func expirePendingPairing() {
        guard let pendingExpiresAt, Date() >= pendingExpiresAt else { return }
        do { try MacCredentials.clearPendingPairing() }
        catch { errorMessage = "无法清除过期配对：\(error.localizedDescription)"; return }
        if let pendingKey { removePadSession(for: pendingKey) }
        pendingKey = nil
        self.pendingExpiresAt = nil
        pendingPadName = nil
        pendingPadPeripheralID = nil
        restorePreviousPairing()
        errorMessage = "新配对未能连接 iPad，旧配对已保留；请重新配对。"
    }

    private func controlStatus() -> ControlStatus {
        ControlStatus(connection: connection, paired: paired, enabled: enabled, inputCount: inputCount,
                      captureDiagnostics: input?.captureDiagnostics,
                      ipadBLEVerified: padSessions.values.contains(where: \.bleReachable),
                      ipadWiFiVerified: padSessions.values.contains(where: \.wifiVerified),
                      ipadSpaceAllowed: padSessions.values.contains(where: \.spaceAllowed),
                      macPairedCount: macPeerCount,
                      macVerifiedCount: directMacCount, macSpaceAllowedCount: macPeerAllowed.count,
                      driverInstalling: driverInstalling, driverInstallStatus: driverInstallStatus,
                      inputError: inputError,
                      lastAction: lastAction, lastAckSequence: lastAckSequence,
                      target: padSessions.values.first(where: \.targetKnown)?.target,
                      loginEnabled: loginEnabled, pairingActive: pairingActive,
                      pairingStatus: pairingStatus, pairingAwaitingCode: pairingAwaitingCode,
                      pairingPadName: pairingPadName,
                      pairingPendingActivation: pendingKey != nil,
                      nearbyPads: nearbyPads.map { .init(id: $0.id, name: $0.name) },
                      sources: sources.map { .init(selector: $0.selector, name: $0.name,
                                                   excluded: $0.isExcluded, muted: $0.isMuted,
                                                   active: $0.isActive, microphone: $0.microphoneName,
                                                   microphoneInUse: $0.microphoneInUse) },
                      error: errorMessage)
    }

    private func handleControl(_ request: ControlRequest) -> ControlResponse {
        var problem: String?
        switch request.command {
        case "status": refreshSources()
        case "driver.install": installDriver()
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
        case "microphone.add", "microphone.remove":
            if let value = request.value, let selector = ExclusionStore.normalized(value), selector.hasPrefix("bundle:") {
                let name = sources.first(where: { $0.selector == selector })?.name ?? String(selector.dropFirst(7))
                if !setMicrophone(selector, name: name, add: request.command == "microphone.add") { problem = errorMessage }
            } else { problem = "请输入应用 bundle ID" }
        case "target.set":
            if let value = request.value, let number = Double(value), (0...0.5).contains(number) {
                for session in padSessions.values {
                    session.target = number
                    setPadTarget(session.id, value: number)
                    padTargetEditChanged(session.id, false)
                }
            } else { problem = "目标音量须为 0 到 0.5" }
        default: problem = "未知命令"
        }
        return ControlResponse(ok: problem == nil, message: problem, status: controlStatus())
    }

    func setPadTarget(_ id: String, value: Double) {
        guard let session = padSessions[id] else { return }
        session.target = value
        refreshPadDisplays()
    }

    func padTargetEditChanged(_ id: String, _ editing: Bool) {
        guard let session = padSessions[id] else { return }
        session.targetEditing = editing
        if !editing {
            let milli = Int((session.target * 1000).rounded())
            session.pendingTargetMilli = milli
            session.client?.setTargetMilli(milli)
            session.wifiPeer?.sendCurrentState()
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
        for session in padSessions.values {
            session.client?.setDesired(false)
            session.wifiPeer?.sendCurrentState()
        }
        for peer in macWifiPeers.values { peer.sendCurrentState() }
        let change = peerLedger.stopResponding(at: Int64(Date().timeIntervalSince1970))
        persistPeerLedger()
        if change.ended { localOutput?.finish(manualAtEnd: change.manualAtEnd) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.padSessions.values.forEach { $0.stop() }
            self?.macWifiPeers.values.forEach { $0.stop() }
            NSApp.terminate(nil)
        }
    }
}
