import CoreBluetooth
import Foundation
import UIKit

@MainActor final class BLEServer: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    static let serviceID = CBUUID(string: BLEIdentifiers.service)
    static let pairServiceID = CBUUID(string: BLEIdentifiers.pairingService)
    static let commandID = CBUUID(string: BLEIdentifiers.command)
    static let ackID = CBUUID(string: BLEIdentifiers.ack)
    static let peerStateID = CBUUID(string: BLEIdentifiers.peerState)
    static let peerAckWriteID = CBUUID(string: BLEIdentifiers.peerAckWrite)
    static let pairWriteID = CBUUID(string: BLEIdentifiers.pairingWrite)
    static let pairResponseID = CBUUID(string: BLEIdentifiers.pairingResponse)
    static let pairInfoID = CBUUID(string: BLEIdentifiers.pairingInfo)

    @Published private(set) var status = "正在启动"
    @Published private(set) var isPaired = false
    @Published private(set) var pairedCount = 0
    @Published private(set) var pairingMode = false
    @Published private(set) var pairingStatus = "配对模式未开启"
    @Published private(set) var shortCode: String?
    @Published private(set) var peerName = ""
    @Published private(set) var lastAction = "尚无命令"
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
    private var ackCharacteristic: CBMutableCharacteristic?
    private var peerStateCharacteristic: CBMutableCharacteristic?
    private var pairResponseCharacteristic: CBMutableCharacteristic?
    private var pairResponseData: Data?
    private var controlRegistered = false
    private var pairRegistered = false
    private var subscribed = Set<UUID>()
    private var pairedKeys = [Data]()
    private var lastAckByCentral = [UUID: Data]()
    private var pendingKey: Data?
    var pairingPendingActivation: Bool { pendingKey != nil }
    private var pairing: PairingResponder?
    private var pairingCentral: UUID?
    private var pairingDeadline: Date?
    private var pairAttempts = 0
    private var pairingTimer: Timer?
    private var volume: VolumeCoordinator?
    private var legacySequences = UserDefaults.standard.dictionary(forKey: "legacySequences") as? [String: String] ?? [:]
    private var peerLedger = (UserDefaults.standard.data(forKey: "peerDemandLedger")
        .flatMap { try? JSONDecoder().decode(PeerDemandLedger.self, from: $0) }) ?? PeerDemandLedger()
    private var peerProtocolActive = UserDefaults.standard.bool(forKey: "peerProtocolActive")
    private var localQuiet = false
    private var localRevision = UserDefaults.standard.string(forKey: "localPeerRevision").flatMap(UInt64.init) ?? 0
    private var peerTimer: Timer?

    private func note(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private var deviceName: String { String(UIDevice.current.name.prefix(32)) }

    private func advertise() {
        manager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID],
                                   CBAdvertisementDataLocalNameKey: "Nearby Audio · \(deviceName)"])
    }

    override init() {
        super.init()
        do {
            let peers = try PairingStore.all()
            pairedKeys = peers.map(\.key)
            pairedCount = pairedKeys.count
            do { pendingKey = try PairingStore.pending() }
            catch { pairingStatus = "待激活配对不可用：\(error.localizedDescription)" }
            isPaired = !pairedKeys.isEmpty
            volume = VolumeCoordinator()
            status = volume == nil ? "当前系统的媒体音量接口不兼容" : "等待蓝牙"
            note("BLUETOOTH_AUTHORIZATION \(CBPeripheralManager.authorization.rawValue)")
            manager = CBPeripheralManager(delegate: self, queue: .main,
                                          options: [CBPeripheralManagerOptionRestoreIdentifierKey: "NearbyAudioPeripheral"])
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
            setLocalQuiet(false)
            cancelPairing(reason: "已停止配对")
            manager?.stopAdvertising()
            manager?.removeAllServices()
            ackCharacteristic = nil
            peerStateCharacteristic = nil
            pairResponseCharacteristic = nil
            controlRegistered = false
            pairRegistered = false
            subscribed.removeAll()
            bleProofs.removeAll()
            refreshSpace()
            let change = peerLedger.stopResponding(at: Int64(Date().timeIntervalSince1970))
            persistPeerLedger()
            if peerProtocolActive { _ = volume?.release(manual: change.manualAtEnd) }
            else { _ = volume?.apply(quiet: false, target: 0) }
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
                if peerProtocolActive { _ = volume?.release(manual: change.manualAtEnd) }
                else { _ = volume?.apply(quiet: false, target: 0) }
            }
        }
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
        if peerProtocolActive {
            peerLedger.takeOver(at: Int64(Date().timeIntervalSince1970))
            persistPeerLedger()
        }
        let result = volume.apply(quiet: false, target: 0)
        lastAction = "手动恢复：\(result.0)"
    }

    func beginPairing() {
        guard enabled, manager?.state == .poweredOn else {
            pairingStatus = "请先开启蓝牙监听"
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
            pairingStatus = "2 分钟内在 Mac 输入下方验证码；最多尝试 3 次"
            pairingTimer?.invalidate()
            pairingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let deadline = self.pairingDeadline, Date() >= deadline else { return }
                    self.cancelPairing(reason: "配对已超时，请重新开启")
                }
            }
        } catch { pairingStatus = "无法准备配对：\(error.localizedDescription)" }
    }

    func rejectPairing() { cancelPairing(reason: "已拒绝配对") }

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
            pairingStatus = "验证码已通过，等待新 Mac 使用新密钥连接"
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
            let command = CBMutableCharacteristic(type: Self.commandID, properties: [.write], value: nil, permissions: [.writeable])
            let ack = CBMutableCharacteristic(type: Self.ackID, properties: [.read, .notify], value: nil, permissions: [.readable])
            let peerState = CBMutableCharacteristic(type: Self.peerStateID, properties: [.read, .notify], value: nil, permissions: [.readable])
            let peerAckWrite = CBMutableCharacteristic(type: Self.peerAckWriteID, properties: [.write], value: nil, permissions: [.writeable])
            let service = CBMutableService(type: Self.serviceID, primary: true)
            service.characteristics = [command, ack, peerState, peerAckWrite]
            ackCharacteristic = ack
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
               let ack = characteristics.first(where: { $0.uuid == Self.ackID }) as? CBMutableCharacteristic,
               let peerState = characteristics.first(where: { $0.uuid == Self.peerStateID }) as? CBMutableCharacteristic,
               characteristics.contains(where: { $0.uuid == Self.commandID }),
               characteristics.contains(where: { $0.uuid == Self.peerAckWriteID }) {
                controlRegistered = true
                ackCharacteristic = ack
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
            return
        }
        if controlRegistered && pairRegistered && !peripheral.isAdvertising { advertise() }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        note("ADVERTISING \(error.map(String.init(describing:)) ?? "ready")")
        status = error.map { "蓝牙广播失败：\($0.localizedDescription)" } ?? "蓝牙已就绪"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let central = request.central.identifier
        if let proof = bleProofs[central],
           request.characteristic.uuid == Self.ackID || request.characteristic.uuid == Self.peerStateID {
            recordBLEProof(from: central, key: proof.key,
                           at: Int64(Date().timeIntervalSince1970))
        }
        let data: Data
        switch request.characteristic.uuid {
        case Self.ackID:
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
            if request.characteristic.uuid == Self.commandID,
               let data = request.value, data.count <= 512,
               let update = try? JSONDecoder().decode(PeerQuietUpdate.self, from: data) {
                receivePeerUpdate(update, request: request, peripheral: peripheral)
                continue
            }
            guard enabled, request.characteristic.uuid == Self.commandID,
                  let data = request.value, data.count <= 512,
                  let command = try? JSONDecoder().decode(ControlCommand.self, from: data) else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }
            let now = Int64(Date().timeIntervalSince1970)
            let authenticatedKey: Data
            if let pendingKey, command.valid(key: pendingKey, now: now) {
                do {
                    // Activate on the first authenticated command; the Mac waits for our signed ACK.
                    _ = try PairingStore.promotePending()
                    self.pendingKey = nil
                    pairedKeys = try PairingStore.all().map(\.key)
                    pairedCount = pairedKeys.count
                    startWiFi()
                    isPaired = true
                    pairingStatus = "配对完成，已添加一台 Mac"
                    authenticatedKey = pendingKey
                } catch {
                    peripheral.respond(to: request, withResult: .unlikelyError)
                    pairingStatus = "无法激活新配对：\(error.localizedDescription)"
                    continue
                }
            } else if let matched = pairedKeys.first(where: { command.valid(key: $0, now: now) }) {
                authenticatedKey = matched
            } else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }
            let central = request.central.identifier
            recordBLEProof(from: central, key: authenticatedKey, at: now)
            let source = sourceID(for: authenticatedKey)
            let previous = UInt64(legacySequences[source] ?? "") ??
                (pairedKeys.count == 1 ? UInt64(UserDefaults.standard.integer(forKey: "lastSequence")) : 0)
            if command.sequence < previous {
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }
            if command.sequence == previous {
                let target = Float(UserDefaults.standard.double(forKey: "targetVolume"))
                let duplicate = ControlAck(sequence: command.sequence, quiet: command.quiet,
                    result: "duplicate", volumeMilli: Int(((volume?.current() ?? 0) * 1000).rounded()),
                    targetMilli: Int((target * 1000).rounded()), key: authenticatedKey)
                lastAckByCentral[central] = try? JSONEncoder().encode(duplicate)
                peripheral.respond(to: request, withResult: .success)
                publishAck(to: central)
                continue
            }
            if let targetMilli = command.targetMilli {
                UserDefaults.standard.set(Double(targetMilli) / 1000, forKey: "targetVolume")
            }
            let target = Float(UserDefaults.standard.double(forKey: "targetVolume"))
            let result = command.quiet && !allowedSources.contains(source) ? ("outsideSpace", -1)
                         : volume?.apply(quiet: command.quiet, target: target) ?? ("unsupported", -1)
            let ack = ControlAck(sequence: command.sequence, quiet: command.quiet,
                                 result: result.0, volumeMilli: result.1,
                                 targetMilli: Int((target * 1000).rounded()), key: authenticatedKey)
            legacySequences[source] = String(command.sequence)
            lastAckByCentral[central] = try? JSONEncoder().encode(ack)
            UserDefaults.standard.set(legacySequences, forKey: "legacySequences")
            UserDefaults.standard.synchronize()
            lastAction = "\(command.quiet ? "降低" : "恢复")：\(result.0)（\(result.1)‰）"
            note("APPLIED seq=\(command.sequence) quiet=\(command.quiet) result=\(result.0) volumeMilli=\(result.1)")
            peripheral.respond(to: request, withResult: .success)
            publishAck(to: central)
        }
    }

    private func persistPeerLedger() {
        UserDefaults.standard.set(try? JSONEncoder().encode(peerLedger), forKey: "peerDemandLedger")
    }

    private func expirePeerRequests() {
        let now = Int64(Date().timeIntervalSince1970)
        observeManualTakeover(at: now)
        let change = peerLedger.expire(at: now)
        if change.ended {
            persistPeerLedger()
            let result = volume?.release(manual: change.manualAtEnd)
            if let result { lastAction = "请求超时：\(result.0)" }
        }
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
        if let pendingKey, update.valid(key: pendingKey, expectedOrigin: "mac", now: now) {
            do {
                _ = try PairingStore.promotePending()
                self.pendingKey = nil
                pairedKeys = try PairingStore.all().map(\.key)
                pairedCount = pairedKeys.count
                startWiFi()
                isPaired = true
                pairingStatus = "配对完成，已添加一台 Mac"
                authenticatedKey = pendingKey
            } catch {
                peripheral.respond(to: request, withResult: .unlikelyError)
                pairingStatus = "无法激活新配对：\(error.localizedDescription)"
                return
            }
        } else if let matched = pairedKeys.first(where: { update.valid(key: $0, expectedOrigin: "mac", now: now) }) {
            authenticatedKey = matched
        } else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        let central = request.central.identifier
        recordBLEProof(from: central, key: authenticatedKey, at: now)
        let ack = processPeerUpdate(update, key: authenticatedKey, now: now)
        lastAckByCentral[central] = try? JSONEncoder().encode(ack)
        lastAction = "对等请求：\(ack.result)"
        peripheral.respond(to: request, withResult: .success)
        publishAck(to: central)
        publishLocalState()
    }

    private func processPeerUpdate(_ update: PeerQuietUpdate, key: Data, now: Int64) -> PeerStateAck {
        let currentTarget = Float(UserDefaults.standard.double(forKey: "targetVolume"))
        let source = sourceID(for: key)
        guard enabled else {
            return PeerStateAck(origin: "ipad", revision: update.revision, quiet: update.quiet,
                                result: "paused", targetMilli: Int((currentTarget * 1000).rounded()), key: key)
        }
        guard allowedSources.contains(source) else {
            return PeerStateAck(origin: "ipad", revision: update.revision, quiet: update.quiet,
                                result: "outsideSpace", targetMilli: Int((currentTarget * 1000).rounded()), key: key)
        }
        observeManualTakeover(at: now)
        let change = peerLedger.accept(update, from: source, expectedOrigin: "mac",
                                       key: key, at: now)
        peerProtocolActive = true
        UserDefaults.standard.set(true, forKey: "peerProtocolActive")
        persistPeerLedger()
        if change.accepted, let targetMilli = update.targetMilli {
            UserDefaults.standard.set(Double(targetMilli) / 1000, forKey: "targetVolume")
        }
        let target = Float(UserDefaults.standard.double(forKey: "targetVolume"))
        let result: (String, Int)
        if change.ended && !change.manualAtEnd {
            result = volume?.release(manual: false) ?? ("unsupported", -1)
        } else if change.ended {
            result = volume?.release(manual: true) ?? ("unsupported", -1)
        } else if change.started {
            result = volume?.apply(quiet: true, target: target) ?? ("unsupported", -1)
        } else {
            result = (change.activeCount > 0 ? "alreadyQuiet" : "alreadyRestored", -1)
        }
        return PeerStateAck(origin: "ipad", revision: update.revision, quiet: update.quiet,
                            result: result.0, targetMilli: Int((target * 1000).rounded()), key: key)
    }

    private func currentLocalState(key: Data) -> Data? {
        let update = makeLocalState(key: key)
        return try? JSONEncoder().encode(update)
    }

    private func makeLocalState(key: Data) -> PeerQuietUpdate {
        let now = Int64(Date().timeIntervalSince1970)
        let clock = UInt64(Date().timeIntervalSince1970 * 1000)
        localRevision = max(clock, localRevision &+ 1)
        UserDefaults.standard.set(String(localRevision), forKey: "localPeerRevision")
        return PeerQuietUpdate(origin: "ipad", revision: localRevision,
                               quiet: localQuiet && enabled && allowedSources.contains(sourceID(for: key)),
                               validUntil: now + PeerTiming.leaseSeconds, key: key)
    }

    private func startWiFi() {
        for peerKey in pairedKeys {
            let source = sourceID(for: peerKey)
            guard wifiPeers[source] == nil else { continue }
            let peer = WiFiPeer(localOrigin: "ipad", remoteOrigin: "mac", listens: false,
                                key: peerKey, localUpdate: { [unowned self] in
                self.makeLocalState(key: peerKey)
            }, receiveUpdate: { [unowned self] update in
                guard self.pairedKeys.contains(peerKey) else { return ("stalePairing", nil) }
                let ack = self.processPeerUpdate(update, key: peerKey,
                                                 now: Int64(Date().timeIntervalSince1970))
                self.lastAction = "Wi-Fi 对等请求：\(ack.result)"
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

    func setLocalQuiet(_ quiet: Bool) {
        guard localQuiet != quiet else { return }
        localQuiet = quiet
        publishLocalState()
        publishWiFiState()
    }

    private func receivePeerAck(_ request: CBATTRequest, peripheral: CBPeripheralManager) {
        guard let key = bleProofs[request.central.identifier]?.key,
              let data = request.value, data.count <= 512,
              let ack = try? JSONDecoder().decode(PeerStateAck.self, from: data),
              ack.valid(key: key, expectedOrigin: "mac") else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        note("PEER ACK rev=\(ack.revision) result=\(ack.result)")
        peripheral.respond(to: request, withResult: .success)
    }

    private func receivePairWrite(_ request: CBATTRequest, peripheral: CBPeripheralManager) {
        guard enabled, let data = request.value, data.count <= 512,
              let frame = try? JSONDecoder().decode(PairingFrame.self, from: data), frame.version == 2 else {
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
                let session = try PairingResponder(start: frame, code: shortCode!, padName: deviceName)
                pairAttempts += 1
                pairing = session
                pairingCentral = request.central.identifier
                peerName = frame.name ?? "Mac"
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
                cancelPairing(reason: "Mac 已取消配对")
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
        guard let manager, let ackCharacteristic, let data = lastAckByCentral[id],
              let central = ackCharacteristic.subscribedCentrals?.first(where: { $0.identifier == id }) else { return }
        _ = manager.updateValue(data, for: ackCharacteristic, onSubscribedCentrals: [central])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == Self.ackID { subscribed.insert(central.identifier) }
        if characteristic.uuid == Self.peerStateID { publishLocalState() }
        status = "Mac 已连接"
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
        guard characteristic.uuid == Self.ackID else { return }
        subscribed.remove(central.identifier)
        lastAckByCentral.removeValue(forKey: central.identifier)
        if bleProofs.removeValue(forKey: central.identifier) != nil {
            refreshSpace()
        }
        if subscribed.isEmpty {
            publishLocalState()
            publishWiFiState()
            if peerProtocolActive {
                expirePeerRequests()
            } else {
                let result = volume?.apply(quiet: false, target: 0)
                if let result { lastAction = "连接中断：\(result.0)" }
            }
            status = "等待 Mac 重连"
        }
    }
}
