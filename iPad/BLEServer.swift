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
    @Published private(set) var pairingMode = false
    @Published private(set) var pairingStatus = "配对模式未开启"
    @Published private(set) var shortCode: String?
    @Published private(set) var peerName = ""
    @Published private(set) var lastAction = "尚无命令"
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: "listeningEnabled") as? Bool ?? true
    @Published private(set) var spaceMode = SpaceMode(rawValue: UserDefaults.standard.string(forKey: "spaceMode") ?? "") ?? .nearbyOrWiFi
    @Published private(set) var bleAuthenticated = false
    private var authenticatedCentral: UUID?
    private var lastBLEProofAt: Int64?
    @Published private(set) var wifiVerified = false
    @Published private(set) var wifiIssue: String?
    @Published private(set) var spaceAllowed = false
    private var rawSpaceAllowed: Bool { spaceMode.allows(ble: bleAuthenticated, wifi: wifiVerified) }
    var spaceStatus: String {
        let summary = "蓝牙\(bleAuthenticated ? "已验证" : "未验证") · Wi-Fi 局域网\(wifiVerified ? "已认证互通" : "未验证") · \(!enabled ? "已暂停" : rawSpaceAllowed ? "允许协同" : spaceAllowed ? "短断连宽限" : "等待空间条件")"
        return wifiIssue.map { "\(summary) · Wi-Fi 错误：\($0)" } ?? summary
    }
    private var manager: CBPeripheralManager?
    private var wifiPeer: WiFiPeer?
    private var spaceGate = SpaceGate()
    private var ackCharacteristic: CBMutableCharacteristic?
    private var peerStateCharacteristic: CBMutableCharacteristic?
    private var pairResponseCharacteristic: CBMutableCharacteristic?
    private var pairResponseData: Data?
    private var controlRegistered = false
    private var pairRegistered = false
    private var subscribed = Set<UUID>()
    private var key: Data?
    private var pendingKey: Data?
    var pairingPendingActivation: Bool { pendingKey != nil }
    private var pairing: PairingResponder?
    private var pairingCentral: UUID?
    private var pairingDeadline: Date?
    private var pairAttempts = 0
    private var pairingTimer: Timer?
    private var volume: VolumeCoordinator?
    private var lastSequence = UInt64(UserDefaults.standard.integer(forKey: "lastSequence"))
    private var lastAckData = UserDefaults.standard.data(forKey: "lastAck")
    private var peerLedger = (UserDefaults.standard.data(forKey: "peerDemandLedger")
        .flatMap { try? JSONDecoder().decode(PeerDemandLedger.self, from: $0) }) ?? PeerDemandLedger()
    private var peerProtocolActive = UserDefaults.standard.bool(forKey: "peerProtocolActive")
    private var localQuiet = false
    private var localRevision = UserDefaults.standard.string(forKey: "localPeerRevision").flatMap(UInt64.init) ?? 0
    private var localStateData: Data?
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
            key = try PairingStore.current()
            do { pendingKey = try PairingStore.pending() }
            catch { pairingStatus = "待激活配对不可用：\(error.localizedDescription)" }
            isPaired = key != nil
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
        wifiPeer?.sendCurrentState()
        if value {
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
            bleAuthenticated = false
            authenticatedCentral = nil
            lastBLEProofAt = nil
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
        spaceGate.reset()
        refreshSpace()
        publishLocalState()
        wifiPeer?.sendCurrentState()
    }

    private func refreshSpace() {
        let now = Int64(Date().timeIntervalSince1970)
        if let lastBLEProofAt, now >= lastBLEProofAt + PeerTiming.leaseSeconds {
            bleAuthenticated = false
            authenticatedCentral = nil
            self.lastBLEProofAt = nil
        }
        let allowed = spaceGate.allows(spaceMode, ble: bleAuthenticated, wifi: wifiVerified, at: now)
        guard allowed != spaceAllowed else { return }
        spaceAllowed = allowed
        if !allowed {
            let change = peerLedger.stopResponding(at: now)
            persistPeerLedger()
            if change.ended {
                if peerProtocolActive { _ = volume?.release(manual: change.manualAtEnd) }
                else { _ = volume?.apply(quiet: false, target: 0) }
            }
        }
        publishLocalState()
        wifiPeer?.sendCurrentState()
    }

    private func recordBLEProof(from central: UUID, at now: Int64) {
        authenticatedCentral = central
        lastBLEProofAt = now
        bleAuthenticated = true
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
            try PairingStore.stage(key)
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
            bleAuthenticated = false
            authenticatedCentral = nil
            lastBLEProofAt = nil
            refreshSpace()
            if pairingMode { cancelPairing(reason: "蓝牙已关闭，配对中止") }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState state: [String: Any]) {
        for service in state[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? [] {
            let characteristics = service.characteristics ?? []
            if service.uuid == Self.serviceID,
               let ack = characteristics.first(where: { $0.uuid == Self.ackID }) as? CBMutableCharacteristic,
               characteristics.contains(where: { $0.uuid == Self.commandID }) {
                controlRegistered = true
                ackCharacteristic = ack
                peerStateCharacteristic = characteristics.first(where: { $0.uuid == Self.peerStateID }) as? CBMutableCharacteristic
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
        if request.central.identifier == authenticatedCentral,
           request.characteristic.uuid == Self.ackID || request.characteristic.uuid == Self.peerStateID {
            recordBLEProof(from: request.central.identifier,
                           at: Int64(Date().timeIntervalSince1970))
        }
        let data: Data
        switch request.characteristic.uuid {
        case Self.ackID:
            data = lastAckData ?? Data()
        case Self.peerStateID:
            expirePeerRequests()
            data = currentLocalState() ?? Data()
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
                    key = try PairingStore.promotePending()
                    self.pendingKey = nil
                    startWiFi()
                    lastSequence = 0
                    lastAckData = nil
                    peerLedger = PeerDemandLedger()
                    persistPeerLedger()
                    peerProtocolActive = false
                    UserDefaults.standard.set(false, forKey: "peerProtocolActive")
                    isPaired = true
                    pairingStatus = "配对完成，新 Mac 已连接并替换旧配对"
                    authenticatedKey = pendingKey
                    UserDefaults.standard.set(0, forKey: "lastSequence")
                    UserDefaults.standard.removeObject(forKey: "lastAck")
                } catch {
                    peripheral.respond(to: request, withResult: .unlikelyError)
                    pairingStatus = "无法激活新配对：\(error.localizedDescription)"
                    continue
                }
            } else if let key, command.valid(key: key, now: now) {
                authenticatedKey = key
            } else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }
            recordBLEProof(from: request.central.identifier, at: now)
            if command.sequence < lastSequence {
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }
            if command.sequence == lastSequence {
                peripheral.respond(to: request, withResult: .success)
                publishAck()
                continue
            }
            if let targetMilli = command.targetMilli {
                UserDefaults.standard.set(Double(targetMilli) / 1000, forKey: "targetVolume")
            }
            let target = Float(UserDefaults.standard.double(forKey: "targetVolume"))
            let result = command.quiet && !spaceAllowed ? ("outsideSpace", -1)
                         : volume?.apply(quiet: command.quiet, target: target) ?? ("unsupported", -1)
            let ack = ControlAck(sequence: command.sequence, quiet: command.quiet,
                                 result: result.0, volumeMilli: result.1,
                                 targetMilli: Int((target * 1000).rounded()), key: authenticatedKey)
            lastSequence = command.sequence
            lastAckData = try? JSONEncoder().encode(ack)
            UserDefaults.standard.set(Int64(bitPattern: lastSequence), forKey: "lastSequence")
            UserDefaults.standard.set(lastAckData, forKey: "lastAck")
            UserDefaults.standard.synchronize()
            lastAction = "\(command.quiet ? "降低" : "恢复")：\(result.0)（\(result.1)‰）"
            note("APPLIED seq=\(command.sequence) quiet=\(command.quiet) result=\(result.0) volumeMilli=\(result.1)")
            peripheral.respond(to: request, withResult: .success)
            publishAck()
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
                _ = volume?.apply(quiet: false, target: 0)
                key = try PairingStore.promotePending()
                self.pendingKey = nil
                startWiFi()
                peerLedger = PeerDemandLedger()
                persistPeerLedger()
                lastSequence = 0
                lastAckData = nil
                UserDefaults.standard.removeObject(forKey: "lastAck")
                isPaired = true
                pairingStatus = "配对完成，新 Mac 已连接并替换旧配对"
                authenticatedKey = pendingKey
                UserDefaults.standard.set(0, forKey: "lastSequence")
            } catch {
                peripheral.respond(to: request, withResult: .unlikelyError)
                pairingStatus = "无法激活新配对：\(error.localizedDescription)"
                return
            }
        } else if let key, update.valid(key: key, expectedOrigin: "mac", now: now) {
            authenticatedKey = key
        } else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        recordBLEProof(from: request.central.identifier, at: now)
        let ack = processPeerUpdate(update, key: authenticatedKey, now: now)
        lastAckData = try? JSONEncoder().encode(ack)
        UserDefaults.standard.set(lastAckData, forKey: "lastAck")
        lastAction = "对等请求：\(ack.result)"
        peripheral.respond(to: request, withResult: .success)
        publishAck()
        publishLocalState()
    }

    private func processPeerUpdate(_ update: PeerQuietUpdate, key: Data, now: Int64) -> PeerStateAck {
        let currentTarget = Float(UserDefaults.standard.double(forKey: "targetVolume"))
        guard enabled else {
            return PeerStateAck(origin: "ipad", revision: update.revision, quiet: update.quiet,
                                result: "paused", targetMilli: Int((currentTarget * 1000).rounded()), key: key)
        }
        guard spaceAllowed else {
            return PeerStateAck(origin: "ipad", revision: update.revision, quiet: update.quiet,
                                result: "outsideSpace", targetMilli: Int((currentTarget * 1000).rounded()), key: key)
        }
        observeManualTakeover(at: now)
        let source = Authentication.sign("paired-peer-id", key: key)
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

    private func currentLocalState() -> Data? {
        guard let key else { return nil }
        let update = makeLocalState(key: key)
        localStateData = try? JSONEncoder().encode(update)
        return localStateData
    }

    private func makeLocalState(key: Data) -> PeerQuietUpdate {
        let now = Int64(Date().timeIntervalSince1970)
        let clock = UInt64(Date().timeIntervalSince1970 * 1000)
        localRevision = max(clock, localRevision &+ 1)
        UserDefaults.standard.set(String(localRevision), forKey: "localPeerRevision")
        return PeerQuietUpdate(origin: "ipad", revision: localRevision,
                               quiet: localQuiet && enabled && spaceAllowed,
                               validUntil: now + PeerTiming.leaseSeconds, key: key)
    }

    private func startWiFi() {
        wifiPeer?.stop()
        wifiPeer = nil
        wifiVerified = false
        wifiIssue = nil
        refreshSpace()
        guard let key else { return }
        wifiPeer = WiFiPeer(role: .ipad, key: key, localUpdate: { [unowned self] in
            self.makeLocalState(key: key)
        }, receiveUpdate: { [unowned self] update in
            guard self.key == key else { return ("stalePairing", nil) }
            let ack = self.processPeerUpdate(update, key: key,
                                             now: Int64(Date().timeIntervalSince1970))
            self.lastAction = "Wi-Fi 对等请求：\(ack.result)"
            return (ack.result, ack.targetMilli)
        }, verifiedChanged: { [unowned self] verified in
            self.wifiVerified = verified
            self.refreshSpace()
            if verified { self.wifiPeer?.sendCurrentState() }
        }, onIssue: { [unowned self] issue in
            self.wifiIssue = issue
        })
        wifiPeer?.start()
    }

    private func publishLocalState() {
        guard let manager, let characteristic = peerStateCharacteristic,
              let data = currentLocalState() else { return }
        _ = manager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
    }

    func setLocalQuiet(_ quiet: Bool) {
        guard localQuiet != quiet else { return }
        localQuiet = quiet
        publishLocalState()
        wifiPeer?.sendCurrentState()
    }

    private func receivePeerAck(_ request: CBATTRequest, peripheral: CBPeripheralManager) {
        guard let key, let data = request.value, data.count <= 512,
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

    private func publishAck() {
        guard let manager, let ackCharacteristic, let lastAckData else { return }
        _ = manager.updateValue(lastAckData, for: ackCharacteristic, onSubscribedCentrals: nil)
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
        if authenticatedCentral == central.identifier {
            bleAuthenticated = false
            authenticatedCentral = nil
            lastBLEProofAt = nil
            refreshSpace()
        }
        if subscribed.isEmpty {
            publishLocalState()
            wifiPeer?.sendCurrentState()
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
