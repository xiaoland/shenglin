import CoreBluetooth
import Foundation
import UIKit

struct PairedPeerDisplay: Identifiable, Equatable {
    let id: String
    let name: String
    let link: String
    let space: String
    let connected: Bool
    let allowsCoordination: Bool

    var summary: String {
        if allowsCoordination { return connected ? "可协同" : "短暂断连，仍可协同" }
        return connected ? "等待空间条件" : "未连接"
    }
}

@MainActor final class BLEServer: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    static let serviceID = CBUUID(string: BLEIdentifiers.service)
    static let pairServiceID = CBUUID(string: BLEIdentifiers.pairingService)
    static let stateWriteID = CBUUID(string: BLEIdentifiers.stateWrite)
    static let stateAckID = CBUUID(string: BLEIdentifiers.stateAck)
    static let peerStateID = CBUUID(string: BLEIdentifiers.peerState)
    static let peerAckWriteID = CBUUID(string: BLEIdentifiers.peerAckWrite)
    static let pairWriteID = CBUUID(string: BLEIdentifiers.pairingWrite)
    static let pairResponseID = CBUUID(string: BLEIdentifiers.pairingResponse)
    static let pairInfoID = CBUUID(string: BLEIdentifiers.pairingInfo)

    @Published private(set) var status = "正在启动"
    @Published private(set) var startupIssue: String?
    @Published private(set) var bluetoothIssue: String?
    @Published private(set) var isPaired = false
    @Published private(set) var pairedCount = 0
    @Published private(set) var pairedPeerDisplays = [PairedPeerDisplay]()
    @Published private(set) var pairingMode = false
    @Published private(set) var pairingStatus = "配对模式未开启"
    @Published private(set) var deviceName = String(PeerName.display(
        UserDefaults.standard.string(forKey: "deviceName"),
        fallback: PeerName.display(UIDevice.current.name, fallback: "iPad")).prefix(32))
    @Published private(set) var shortCode: String?
    @Published private(set) var peerName = ""
    @Published private(set) var lastAction = "尚无命令"
    @Published private(set) var recordingStatus = "录音状态待检测"
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: "listeningEnabled") as? Bool ?? true
    @Published private(set) var spaceMode = SpaceMode(rawValue: UserDefaults.standard.string(forKey: "spaceMode") ?? "") ?? .nearbyOrWiFi
    @Published private(set) var bleAuthenticated = false
    private struct BLEProof { let key: Data; var at: Int64 }
    private var bleProofs = [UUID: BLEProof]()
    @Published private(set) var wifiVerified = false
    @Published private(set) var wifiIssue: String?
    @Published private(set) var spaceAllowed = false
    var spaceStatus: String {
        let summary = "蓝牙已验证 \(bleProofs.count) 台 · Wi-Fi 局域网\(wifiVerified ? "已认证互通" : "未验证") · \(!enabled ? "已暂停" : "符合空间条件 \(allowedSources.count) 台")"
        return wifiIssue.map { "\(summary) · Wi-Fi 错误：\($0)" } ?? summary
    }
    private var manager: CBPeripheralManager?
    private var wifiPeers = [String: WiFiPeer]()
    private var wifiVerifiedSources = Set<String>()
    private var wifiIssues = [String: String]()
    private var spaceGates = [String: SpaceGate]()
    private var allowedSources = Set<String>()
    private var stateAckCharacteristic: CBMutableCharacteristic?
    private var peerStateCharacteristic: CBMutableCharacteristic?
    private var pairResponseCharacteristic: CBMutableCharacteristic?
    private var pairResponseData: Data?
    private var controlRegistered = false
    private var pairRegistered = false
    private var subscribed = Set<UUID>()
    private var pairedKeys = [Data]()
    private var pairedPeers = [PairedPeer]()
    private var lastAckByCentral = [UUID: Data]()
    private var pendingKey: Data?
    var pairingPendingActivation: Bool { pendingKey != nil }
    private var pairing: PairingResponder?
    private var pairingCentral: UUID?
    private var pairingDeadline: Date?
    private var pairAttempts = 0
    private var pairingTimer: Timer?
    private var volume: VolumeCoordinator?
    private var outputDemandActive = false
    private var outputPausedForInput = false
    private var peerLedger = (UserDefaults.standard.data(forKey: "peerDemandLedgerV3")
        .flatMap { try? JSONDecoder().decode(PeerDemandLedger.self, from: $0) }) ?? PeerDemandLedger()
    private var localRevision = UserDefaults.standard.string(forKey: "localPeerRevisionV3").flatMap(UInt64.init) ?? 0
    private var peerTimer: Timer?

    private func note(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private func advertise() {
        manager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID],
                                   CBAdvertisementDataLocalNameKey: "声邻 · \(deviceName)"])
    }

    override init() {
        super.init()
        UserDefaults.standard.set(deviceName, forKey: "deviceName")
        do {
            let peers = try PairingStore.all()
            pairedPeers = peers
            pairedKeys = peers.map(\.key)
            pairedCount = pairedKeys.count
            do { pendingKey = try PairingStore.pending() }
            catch { pairingStatus = "待激活配对不可用：\(error.localizedDescription)" }
            isPaired = !pairedKeys.isEmpty
            volume = VolumeCoordinator()
            outputDemandActive = volume?.hasSnapshot == true
            status = volume == nil ? "当前系统的媒体音量接口不兼容" : "等待蓝牙"
            if volume == nil { startupIssue = status }
            note("BLUETOOTH_AUTHORIZATION \(CBPeripheralManager.authorization.rawValue)")
            manager = CBPeripheralManager(delegate: self, queue: .main,
                                          options: [CBPeripheralManagerOptionRestoreIdentifierKey: "ShenglinPeripheral"])
            startWiFi()
            note("BLUETOOTH_MANAGER_CREATED")
            peerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshSpace()
                    self?.expirePeerRequests()
                }
            }
        } catch {
            status = "无法读取配对密钥：\(error.localizedDescription)"
            startupIssue = status
        }
    }

    func setDeviceName(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 32, !pairingMode else { return }
        deviceName = name
        UserDefaults.standard.set(name, forKey: "deviceName")
        publishWiFiState()
        if manager?.isAdvertising == true {
            manager?.stopAdvertising()
            advertise()
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "listeningEnabled")
        publishWiFiState()
        if value {
            refreshSpace()
            guard manager?.state == .poweredOn else { return }
            publishService()
        } else {
            publishLocalState()
            cancelPairing(reason: "已停止配对")
            manager?.stopAdvertising()
            manager?.removeAllServices()
            stateAckCharacteristic = nil
            peerStateCharacteristic = nil
            pairResponseCharacteristic = nil
            controlRegistered = false
            pairRegistered = false
            subscribed.removeAll()
            bleProofs.removeAll()
            refreshSpace()
            let change = peerLedger.stopResponding(at: Int64(Date().timeIntervalSince1970))
            persistPeerLedger()
            _ = volume?.release(manual: change.manualAtEnd)
            status = "已停止监听"
        }
    }

    func setSpaceMode(_ mode: SpaceMode) {
        spaceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "spaceMode")
        spaceGates.removeAll()
        refreshSpace()
        publishLocalState()
        publishWiFiState()
    }

    private func refreshSpace() {
        let now = Int64(Date().timeIntervalSince1970)
        for central in Array(bleProofs.keys) where now >= (bleProofs[central]?.at ?? 0) + PeerTiming.leaseSeconds {
            bleProofs.removeValue(forKey: central)
        }
        bleAuthenticated = !bleProofs.isEmpty
        var next = Set<String>()
        for peerKey in pairedKeys where enabled {
            let source = sourceID(for: peerKey)
            var gate = spaceGates[source] ?? SpaceGate()
            let ble = bleProofs.values.contains { $0.key == peerKey }
            let wifi = wifiVerifiedSources.contains(source)
            if gate.allows(spaceMode, ble: ble, wifi: wifi, at: now) { next.insert(source) }
            spaceGates[source] = gate
        }
        let removed = allowedSources.subtracting(next)
        let changed = next != allowedSources
        allowedSources = next
        spaceAllowed = !next.isEmpty
        for source in removed {
            let change = peerLedger.stopResponding(to: source, at: now)
            if change.ended {
                _ = volume?.release(manual: change.manualAtEnd)
            }
        }
        let displays = pairedPeers.map { peer in
            let source = sourceID(for: peer.key)
            let ble = bleProofs.values.contains { $0.key == peer.key }
            let wifi = wifiVerifiedSources.contains(source)
            let allowed = allowedSources.contains(source)
            return PairedPeerDisplay(id: source, name: peer.name,
                link: ble ? "蓝牙已认证" : wifi ? "Wi-Fi 已认证" : "未连接",
                space: allowed ? (ble || wifi ? "允许协同" : "短断连宽限") : "等待空间条件",
                connected: ble || wifi, allowsCoordination: allowed)
        }
        if displays != pairedPeerDisplays { pairedPeerDisplays = displays }
        if !removed.isEmpty { persistPeerLedger() }
        if changed {
            publishLocalState()
            publishWiFiState()
        }
    }

    private func sourceID(for key: Data) -> String { Authentication.sign("paired-peer-id", key: key) }

    private func recordBLEProof(from central: UUID, key: Data, at now: Int64) {
        bleProofs[central] = BLEProof(key: key, at: now)
        refreshSpace()
    }

    func restoreNow() {
        guard let volume else { return }
        peerLedger.takeOver(at: Int64(Date().timeIntervalSince1970))
        persistPeerLedger()
        let result = volume.apply(quiet: false, target: 0)
        lastAction = PeerResult.message(result.0, device: deviceName)
    }

    func beginPairing() {
        guard enabled, manager?.state == .poweredOn else {
            pairingStatus = "请先开启自动协同，并确认蓝牙可用"
            return
        }
        do {
            try PairingStore.clearPending()
            pendingKey = nil
            pairing = nil
            pairingCentral = nil
            pairResponseData = nil
            pairAttempts = 0
            shortCode = try PairingCode.generate()
            peerName = ""
            pairingMode = true
            pairingDeadline = Date().addingTimeInterval(120)
            pairingStatus = "验证码最多可尝试 3 次"
            pairingTimer?.invalidate()
            pairingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let deadline = self.pairingDeadline, Date() >= deadline else { return }
                    self.cancelPairing(reason: "配对已超时，请重新开启")
                }
            }
        } catch { pairingStatus = "无法准备配对：\(error.localizedDescription)" }
    }

    func rejectPairing() { cancelPairing(reason: "已取消配对") }

    private func cancelPairing(reason: String) {
        if let pairing, let central = pairingCentral {
            publishPair(PairingFrame(kind: .reject, session: pairing.session), to: central)
        }
        pairing = nil
        pairingCentral = nil
        shortCode = nil
        peerName = ""
        pairingMode = false
        pairingDeadline = nil
        pairingTimer?.invalidate()
        pairingTimer = nil
        pairingStatus = reason
    }

    private func finishPairing(_ frame: PairingFrame) {
        guard let key = pairing?.confirmedKey, let central = pairingCentral else { return }
        do {
            try PairingStore.stage(key, name: peerName)
            pendingKey = key
            pairingStatus = "验证码已通过，等待新设备连接"
            pairingMode = false
            pairingDeadline = nil
            pairingTimer?.invalidate()
            pairingTimer = nil
            publishPair(frame, to: central)
            pairing = nil
            pairingCentral = nil
            shortCode = nil
            peerName = ""
        } catch { cancelPairing(reason: "无法保存新配对：\(error.localizedDescription)") }
    }

    private func publishPair(_ frame: PairingFrame, to central: UUID) {
        guard let data = try? JSONEncoder().encode(frame), let manager, let pairResponseCharacteristic else { return }
        pairResponseData = data
        if let subscribers = pairResponseCharacteristic.subscribedCentrals?.filter({ $0.identifier == central }),
           !subscribers.isEmpty {
            _ = manager.updateValue(data, for: pairResponseCharacteristic, onSubscribedCentrals: subscribers)
        }
    }

    private func publishService() {
        guard enabled, let manager, manager.state == .poweredOn else { return }
        if controlRegistered && pairRegistered {
            if !manager.isAdvertising { advertise() }
            status = "蓝牙已就绪"
            return
        }
        if !controlRegistered {
            let command = CBMutableCharacteristic(type: Self.stateWriteID, properties: [.write], value: nil, permissions: [.writeable])
            let ack = CBMutableCharacteristic(type: Self.stateAckID, properties: [.read, .notify], value: nil, permissions: [.readable])
            let peerState = CBMutableCharacteristic(type: Self.peerStateID, properties: [.read, .notify], value: nil, permissions: [.readable])
            let peerAckWrite = CBMutableCharacteristic(type: Self.peerAckWriteID, properties: [.write], value: nil, permissions: [.writeable])
            let service = CBMutableService(type: Self.serviceID, primary: true)
            service.characteristics = [command, ack, peerState, peerAckWrite]
            stateAckCharacteristic = ack
            peerStateCharacteristic = peerState
            controlRegistered = true
            manager.add(service)
        }
        if !pairRegistered {
            let pairWrite = CBMutableCharacteristic(type: Self.pairWriteID, properties: [.write], value: nil, permissions: [.writeable])
            let pairResponse = CBMutableCharacteristic(type: Self.pairResponseID, properties: [.read, .notify], value: nil, permissions: [.readable])
            let pairInfo = CBMutableCharacteristic(type: Self.pairInfoID, properties: [.read], value: nil, permissions: [.readable])
            let service = CBMutableService(type: Self.pairServiceID, primary: true)
            service.characteristics = [pairWrite, pairResponse, pairInfo]
            pairResponseCharacteristic = pairResponse
            pairRegistered = true
            manager.add(service)
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn, .unknown, .resetting: bluetoothIssue = nil
        case .poweredOff: bluetoothIssue = "蓝牙已关闭"
        case .unauthorized: bluetoothIssue = "请在系统设置中允许声邻使用蓝牙"
        case .unsupported: bluetoothIssue = "此设备不支持蓝牙"
        @unknown default: bluetoothIssue = "蓝牙暂不可用"
        }
        status = peripheral.state == .poweredOn ? "蓝牙已开启" : "蓝牙不可用（\(peripheral.state.rawValue)）"
        note("BLUETOOTH_STATE \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn { publishService() }
        else {
            bleProofs.removeAll()
            refreshSpace()
            if pairingMode { cancelPairing(reason: "蓝牙已关闭，配对中止") }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState state: [String: Any]) {
        for service in state[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? [] {
            let characteristics = service.characteristics ?? []
            if service.uuid == Self.serviceID,
               let ack = characteristics.first(where: { $0.uuid == Self.stateAckID }) as? CBMutableCharacteristic,
               let peerState = characteristics.first(where: { $0.uuid == Self.peerStateID }) as? CBMutableCharacteristic,
               characteristics.contains(where: { $0.uuid == Self.stateWriteID }),
               characteristics.contains(where: { $0.uuid == Self.peerAckWriteID }) {
                controlRegistered = true
                stateAckCharacteristic = ack
                peerStateCharacteristic = peerState
            } else if service.uuid == Self.pairServiceID,
                      let response = characteristics.first(where: { $0.uuid == Self.pairResponseID }) as? CBMutableCharacteristic,
                      characteristics.contains(where: { $0.uuid == Self.pairWriteID }),
                      characteristics.contains(where: { $0.uuid == Self.pairInfoID }) {
                pairRegistered = true
                pairResponseCharacteristic = response
            } else {
                peripheral.remove(service)
            }
        }
        if peripheral.state == .poweredOn { publishService() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        note("SERVICE \(error.map(String.init(describing:)) ?? "ready")")
        if let error {
            if service.uuid == Self.serviceID { controlRegistered = false }
            if service.uuid == Self.pairServiceID { pairRegistered = false }
            status = "发布服务失败：\(error.localizedDescription)"
            bluetoothIssue = status
            return
        }
        if controlRegistered && pairRegistered && !peripheral.isAdvertising { advertise() }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        note("ADVERTISING \(error.map(String.init(describing:)) ?? "ready")")
        status = error.map { "蓝牙广播失败：\($0.localizedDescription)" } ?? "蓝牙已就绪"
        bluetoothIssue = error.map { "蓝牙广播失败：\($0.localizedDescription)" }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let central = request.central.identifier
        if let proof = bleProofs[central],
           request.characteristic.uuid == Self.stateAckID || request.characteristic.uuid == Self.peerStateID {
            recordBLEProof(from: central, key: proof.key,
                           at: Int64(Date().timeIntervalSince1970))
        }
        let data: Data
        switch request.characteristic.uuid {
        case Self.stateAckID:
            data = lastAckByCentral[central] ?? Data()
        case Self.peerStateID:
            expirePeerRequests()
            data = bleProofs[central].flatMap { currentLocalState(key: $0.key) } ?? Data()
        case Self.pairInfoID:
            data = (try? JSONEncoder().encode(PairingFrame(kind: .info, session: Data(),
                name: deviceName, pairingMode: pairingMode && (pairingDeadline.map { $0 > Date() } ?? false)))) ?? Data()
        case Self.pairResponseID:
            data = pairResponseData ?? Data()
        default:
            peripheral.respond(to: request, withResult: .readNotPermitted)
            return
        }
        guard request.offset <= data.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = data.dropFirst(request.offset)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == Self.pairWriteID {
                receivePairWrite(request, peripheral: peripheral)
                continue
            }
            if request.characteristic.uuid == Self.peerAckWriteID {
                receivePeerAck(request, peripheral: peripheral)
                continue
            }
            if request.characteristic.uuid == Self.stateWriteID,
               let data = request.value, data.count <= 512,
               let update = try? JSONDecoder().decode(PeerQuietUpdate.self, from: data) {
                receivePeerUpdate(update, request: request, peripheral: peripheral)
                continue
            }
            peripheral.respond(to: request, withResult: .unlikelyError)
        }
    }

    private func persistPeerLedger() {
        UserDefaults.standard.set(try? JSONEncoder().encode(peerLedger), forKey: "peerDemandLedgerV3")
    }

    private func expirePeerRequests() {
        let now = Int64(Date().timeIntervalSince1970)
        observeManualTakeover(at: now)
        let change = peerLedger.expire(at: now)
        if change.ended { persistPeerLedger() }
        let result = coordinateOutput(at: now, manualAtEnd: change.manualAtEnd)
        if result.0 != "alreadyQuiet" && result.0 != "alreadyRestored" {
            lastAction = PeerResult.message(result.0, device: deviceName)
        }
    }

    private func coordinateOutput(at now: Int64, manualAtEnd: Bool = false) -> (String, Int) {
        guard let volume else { return ("unsupported", -1) }
        let demand = enabled && peerLedger.activeCount(at: now) > 0
        guard demand else {
            guard outputDemandActive || (volume.hasSnapshot && !volume.isRestoring) else { return ("alreadyRestored", -1) }
            outputDemandActive = false
            outputPausedForInput = false
            return volume.release(manual: manualAtEnd)
        }
        let recording = sampleRecording()
        let manual = peerLedger.manualTakeover
        if manual {
            outputDemandActive = true
            outputPausedForInput = false
            return volume.release(manual: true)
        }
        if !VolumePolicy.remoteDuckingAllowed(hasDemand: demand, localRecording: recording, manual: manual) {
            if !outputPausedForInput {
                let restored = volume.pauseForLocalInput()
                outputDemandActive = true
                if ["restoreFailed", "readFailed", "readFailedAfterSet"].contains(restored.0) {
                    return restored
                }
                if restored.0 == "preservedManualOrRoute" {
                    peerLedger.takeOver(at: now)
                    persistPeerLedger()
                    return restored
                }
            }
            outputDemandActive = true
            outputPausedForInput = true
            return (recording == true ? "protectedLocal" : "unknown", -1)
        }
        outputDemandActive = true
        outputPausedForInput = false
        let result = volume.apply(quiet: true, target: Float(UserDefaults.standard.double(forKey: "targetVolume")))
        if result.0 == "preservedManualOrRoute" {
            peerLedger.takeOver(at: now)
            persistPeerLedger()
        }
        return result
    }

    private func observeManualTakeover(at now: Int64) {
        guard peerLedger.activeCount(at: now) > 0,
              volume?.manualOrRouteChanged() == true else { return }
        peerLedger.takeOver(at: now)
        persistPeerLedger()
        _ = volume?.release(manual: true)
        lastAction = "保留了你手动调整的音量或新输出设备"
    }

    private func receivePeerUpdate(_ update: PeerQuietUpdate, request: CBATTRequest,
                                   peripheral: CBPeripheralManager) {
        guard enabled else { peripheral.respond(to: request, withResult: .unlikelyError); return }
        let now = Int64(Date().timeIntervalSince1970)
        let authenticatedKey: Data
        if let pendingKey, update.valid(key: pendingKey, expectedOrigin: PeerRole.initiator.rawValue, now: now) {
            do {
                _ = try PairingStore.promotePending()
                self.pendingKey = nil
                pairedPeers = try PairingStore.all()
                pairedKeys = pairedPeers.map(\.key)
                pairedCount = pairedKeys.count
                startWiFi()
                isPaired = true
                pairingStatus = "配对完成，已添加一台设备"
                authenticatedKey = pendingKey
            } catch {
                peripheral.respond(to: request, withResult: .unlikelyError)
                pairingStatus = "无法激活新配对：\(error.localizedDescription)"
                return
            }
        } else if let matched = pairedKeys.first(where: { update.valid(key: $0, expectedOrigin: PeerRole.initiator.rawValue, now: now) }) {
            authenticatedKey = matched
        } else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        let central = request.central.identifier
        recordBLEProof(from: central, key: authenticatedKey, at: now)
        let ack = processPeerUpdate(update, key: authenticatedKey, now: now)
        lastAckByCentral[central] = try? JSONEncoder().encode(ack)
        lastAction = PeerResult.message(ack.result, device: deviceName)
        peripheral.respond(to: request, withResult: .success)
        publishAck(to: central)
        publishLocalState()
    }

    private func processPeerUpdate(_ update: PeerQuietUpdate, key: Data, now: Int64) -> PeerStateAck {
        let currentTarget = Float(UserDefaults.standard.double(forKey: "targetVolume"))
        let source = sourceID(for: key)
        guard enabled else {
            return PeerStateAck(origin: PeerRole.responder.rawValue, revision: update.revision, quiet: update.quiet,
                                result: "paused", targetMilli: Int((currentTarget * 1000).rounded()), key: key)
        }
        guard allowedSources.contains(source) else {
            return PeerStateAck(origin: PeerRole.responder.rawValue, revision: update.revision, quiet: update.quiet,
                                result: "outsideSpace", targetMilli: Int((currentTarget * 1000).rounded()), key: key)
        }
        observeManualTakeover(at: now)
        let change = peerLedger.accept(update, from: source, expectedOrigin: PeerRole.initiator.rawValue,
                                       key: key, at: now)
        persistPeerLedger()
        if change.accepted, let targetMilli = update.targetMilli {
            UserDefaults.standard.set(Double(targetMilli) / 1000, forKey: "targetVolume")
        }
        let target = Float(UserDefaults.standard.double(forKey: "targetVolume"))
        let result = coordinateOutput(at: now, manualAtEnd: change.manualAtEnd)
        return PeerStateAck(origin: PeerRole.responder.rawValue, revision: update.revision, quiet: update.quiet,
                            result: result.0, targetMilli: Int((target * 1000).rounded()), key: key)
    }

    private func currentLocalState(key: Data) -> Data? {
        let update = makeLocalState(key: key)
        return try? JSONEncoder().encode(update)
    }

    private func makeLocalState(key: Data) -> PeerQuietUpdate {
        let recording = sampleRecording()
        let now = Int64(Date().timeIntervalSince1970)
        let clock = UInt64(Date().timeIntervalSince1970 * 1000)
        localRevision = max(clock, localRevision &+ 1)
        UserDefaults.standard.set(String(localRevision), forKey: "localPeerRevisionV3")
        return PeerQuietUpdate(origin: PeerRole.responder.rawValue, revision: localRevision,
                               quiet: recording == true && enabled && allowedSources.contains(sourceID(for: key)),
                               known: !enabled || recording != nil,
                               validUntil: now + PeerTiming.leaseSeconds, key: key)
    }

    private func sampleRecording() -> Bool? {
        let recording = RecordingActivity.current?.sample()
        let next = recording.map { $0 ? "本机正在录音" : "本机未录音" } ?? "录音状态不可用"
        if next != recordingStatus {
            recordingStatus = next
            note("RECORDING_STATUS \(next) appState=\(UIApplication.shared.applicationState.rawValue)")
        }
        return recording
    }

    private func startWiFi() {
        for peerKey in pairedKeys {
            let source = sourceID(for: peerKey)
            guard wifiPeers[source] == nil else { continue }
            let peer = WiFiPeer(localOrigin: PeerRole.responder.rawValue, remoteOrigin: PeerRole.initiator.rawValue, listens: false,
                                key: peerKey, localUpdate: { [unowned self] in
                self.makeLocalState(key: peerKey)
            }, localName: { [unowned self] in self.deviceName },
            receiveName: { [unowned self] name in
                guard let index = self.pairedPeers.firstIndex(where: { $0.key == peerKey }),
                      self.pairedPeers[index].name != name else { return }
                do {
                    try PairingStore.updateName(peerKey, name: name)
                    self.pairedPeers[index].name = name
                    self.refreshSpace()
                } catch { self.pairingStatus = "无法保存设备名称：\(error.localizedDescription)" }
            }, receiveUpdate: { [unowned self] update in
                guard self.pairedKeys.contains(peerKey) else { return ("stalePairing", nil) }
                let ack = self.processPeerUpdate(update, key: peerKey,
                                                 now: Int64(Date().timeIntervalSince1970))
                self.lastAction = PeerResult.message(ack.result, device: self.deviceName)
                return (ack.result, ack.targetMilli)
            }, verifiedChanged: { [unowned self] verified in
                if verified { self.wifiVerifiedSources.insert(source) }
                else { self.wifiVerifiedSources.remove(source) }
                self.wifiVerified = !self.wifiVerifiedSources.isEmpty
                self.refreshSpace()
                if verified { self.wifiPeers[source]?.sendCurrentState() }
            }, onIssue: { [unowned self] issue in
                self.wifiIssues[source] = issue
                self.wifiIssue = self.wifiIssues.values.sorted().first
            })
            wifiPeers[source] = peer
            peer.start()
        }
    }

    private func publishWiFiState() {
        for peer in wifiPeers.values { peer.sendCurrentState() }
    }

    private func publishLocalState() {
        guard let manager, let characteristic = peerStateCharacteristic else { return }
        for central in characteristic.subscribedCentrals ?? [] {
            guard let key = bleProofs[central.identifier]?.key,
                  let data = currentLocalState(key: key) else { continue }
            _ = manager.updateValue(data, for: characteristic, onSubscribedCentrals: [central])
        }
    }

    private func receivePeerAck(_ request: CBATTRequest, peripheral: CBPeripheralManager) {
        guard let key = bleProofs[request.central.identifier]?.key,
              let data = request.value, data.count <= 512,
              let ack = try? JSONDecoder().decode(PeerStateAck.self, from: data),
              ack.valid(key: key, expectedOrigin: PeerRole.initiator.rawValue) else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        note("PEER ACK rev=\(ack.revision) result=\(ack.result)")
        peripheral.respond(to: request, withResult: .success)
    }

    private func receivePairWrite(_ request: CBATTRequest, peripheral: CBPeripheralManager) {
        guard enabled, let data = request.value, data.count <= 512,
              let frame = try? JSONDecoder().decode(PairingFrame.self, from: data), frame.version == 3 else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        if frame.kind == .start {
            guard pairingMode, shortCode != nil, pairingDeadline.map({ $0 > Date() }) == true,
                  pairAttempts < 3, pairing == nil else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                return
            }
            do {
                let session = try PairingResponder(start: frame, code: shortCode!, responderName: deviceName)
                pairAttempts += 1
                pairing = session
                pairingCentral = request.central.identifier
                peerName = PeerName.display(frame.name, fallback: "Mac")
                pairingStatus = "正在核验 \(peerName) 输入的验证码"
                peripheral.respond(to: request, withResult: .success)
                publishPair(session.offerFrame, to: request.central.identifier)
            } catch { peripheral.respond(to: request, withResult: .unlikelyError) }
            return
        }
        guard let pairing, pairingCentral == request.central.identifier,
              frame.session == pairing.session else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        do {
            switch frame.kind {
            case .confirm:
                let finish = try pairing.receiveConfirm(frame)
                peripheral.respond(to: request, withResult: .success)
                finishPairing(finish)
            case .reject:
                peripheral.respond(to: request, withResult: .success)
                cancelPairing(reason: "对方已取消配对")
            default:
                peripheral.respond(to: request, withResult: .unlikelyError)
            }
        } catch {
            peripheral.respond(to: request, withResult: .success)
            failPairingAttempt(reason: error.localizedDescription)
        }
    }

    private func failPairingAttempt(reason: String) {
        if let pairing, let central = pairingCentral {
            publishPair(PairingFrame(kind: .reject, session: pairing.session), to: central)
        }
        pairing = nil
        pairingCentral = nil
        peerName = ""
        if pairAttempts >= 3 { cancelPairing(reason: "验证码尝试次数已用完，请重新开启配对") }
        else { pairingStatus = "\(reason)；还可尝试 \(3 - pairAttempts) 次" }
    }

    private func publishAck(to id: UUID) {
        guard let manager, let stateAckCharacteristic, let data = lastAckByCentral[id],
              let central = stateAckCharacteristic.subscribedCentrals?.first(where: { $0.identifier == id }) else { return }
        _ = manager.updateValue(data, for: stateAckCharacteristic, onSubscribedCentrals: [central])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == Self.stateAckID { subscribed.insert(central.identifier) }
        if characteristic.uuid == Self.peerStateID { publishLocalState() }
        status = "设备已连接"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == Self.pairResponseID, pairingCentral == central.identifier,
           pairing?.confirmedKey == nil {
            pairing = nil
            pairingCentral = nil
            pairResponseData = nil
            peerName = ""
            pairingStatus = "连接中断；配对时间内可用同一验证码重试"
        }
        guard characteristic.uuid == Self.stateAckID else { return }
        subscribed.remove(central.identifier)
        lastAckByCentral.removeValue(forKey: central.identifier)
        if bleProofs.removeValue(forKey: central.identifier) != nil {
            refreshSpace()
        }
        if subscribed.isEmpty {
            publishLocalState()
            publishWiFiState()
            expirePeerRequests()
            status = "等待设备重连"
        }
    }
}
