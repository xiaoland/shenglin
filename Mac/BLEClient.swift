import CoreBluetooth
import Foundation
#if canImport(ShenglinCore)
import ShenglinCore
#endif

enum BLEConnectionState {
    case message(String)
    case awaitingAck
    case ready

    var text: String {
        switch self {
        case .message(let text): text
        case .awaitingAck: "已连接，正在确认控制"
        case .ready: "已连接"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

final class BLEClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceID = CBUUID(string: BLEIdentifiers.service)
    private let pairServiceID = CBUUID(string: BLEIdentifiers.pairingService)
    private let pairInfoID = CBUUID(string: BLEIdentifiers.pairingInfo)
    private let stateWriteID = CBUUID(string: BLEIdentifiers.stateWrite)
    private let stateAckID = CBUUID(string: BLEIdentifiers.stateAck)
    private let peerStateID = CBUUID(string: BLEIdentifiers.peerState)
    private let peerAckWriteID = CBUUID(string: BLEIdentifiers.peerAckWrite)
    private let key: Data
    private let targetPeripheralID: UUID?
    private let onStatus: (BLEConnectionState) -> Void
    private let onPeerAck: (PeerStateAck) -> Void
    private let onPeerState: (PeerQuietUpdate, @escaping (String) -> Void) -> Void
    private let onAuthenticated: (UUID) -> Void
    private let onPeerName: (String) -> Void
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var stateWriteCharacteristic: CBCharacteristic?
    private var stateAckCharacteristic: CBCharacteristic?
    private var peerStateCharacteristic: CBCharacteristic?
    private var peerAckWriteCharacteristic: CBCharacteristic?
    private var pairInfoCharacteristic: CBCharacteristic?
    private var reportedName: String?
    private var pendingPeer: PeerQuietUpdate?
    private var peerTimer: Timer?
    private var retryCount = 0
    private var stopped = false
    private var authenticated = false
    private var skippedPeripherals = [UUID: Date]()
    private(set) var desiredQuiet = false
    private var desiredTargetMilli: Int?

    init(key: Data, targetPeripheralID: UUID? = nil,
         onStatus: @escaping (BLEConnectionState) -> Void = { _ in },
         onPeerAck: @escaping (PeerStateAck) -> Void = { _ in },
         onPeerState: @escaping (PeerQuietUpdate, @escaping (String) -> Void) -> Void = { _, done in done("unsupported") },
         onAuthenticated: @escaping (UUID) -> Void = { _ in },
         onPeerName: @escaping (String) -> Void = { _ in }) {
        self.key = key
        self.targetPeripheralID = targetPeripheralID
        self.onStatus = onStatus
        self.onPeerAck = onPeerAck
        self.onPeerState = onPeerState
        self.onAuthenticated = onAuthenticated
        self.onPeerName = onPeerName
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func report(_ message: String) {
        print("\(Date().timeIntervalSince1970) \(message)")
        fflush(stdout)
    }

    func setDesired(_ quiet: Bool) {
        guard quiet != desiredQuiet else { return }
        desiredQuiet = quiet
        report("DESIRED quiet=\(quiet)")
        if stateWriteCharacteristic != nil { sendCurrentState() }
    }

    func setTargetMilli(_ target: Int) {
        guard (0...500).contains(target), target != desiredTargetMilli else { return }
        desiredTargetMilli = target
        if stateWriteCharacteristic != nil { sendCurrentState() }
    }

    func confirmTargetMilli(_ target: Int?) {
        if desiredTargetMilli == target { desiredTargetMilli = nil }
    }

    func stop() {
        stopped = true
        pendingPeer = nil
        peerTimer?.invalidate()
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard !stopped else { return }
        if manager.state == .poweredOn {
            report("BLUETOOTH ready; scanning")
            onStatus(.message("正在搜索已配对设备"))
            manager.scanForPeripherals(withServices: [serviceID])
        } else {
            report("BLUETOOTH unavailable state=\(manager.state.rawValue)")
            onStatus(.message(manager.state == .unauthorized ? "Mac 蓝牙权限未允许" : "Mac 蓝牙不可用"))
        }
    }

    func centralManager(_ manager: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped, peripheral == nil,
              (skippedPeripherals[found.identifier] ?? .distantPast) < Date(),
              targetPeripheralID == nil || found.identifier == targetPeripheralID else { return }
        peripheral = found
        manager.stopScan()
        report("DISCOVERED; connecting")
        onStatus(.message("正在连接"))
        manager.connect(found)
    }

    func centralManager(_ manager: CBCentralManager, didConnect found: CBPeripheral) {
        guard !stopped else { manager.cancelPeripheralConnection(found); return }
        report("CONNECTED; discovering service")
        onStatus(.message("已连接，正在验证服务"))
        found.delegate = self
        found.discoverServices([serviceID, pairServiceID])
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect found: CBPeripheral, error: Error?) {
        guard !stopped else { return }
        report("CONNECT FAILED \(String(describing: error))")
        onStatus(.message("连接失败，正在重试"))
        if targetPeripheralID == nil && !authenticated { scanAfterRejecting(found) }
        else { manager.connect(found) }
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral found: CBPeripheral, error: Error?) {
        guard !stopped else { return }
        report("DISCONNECTED; reconnecting")
        onStatus(.message("连接中断，正在重连"))
        stateWriteCharacteristic = nil
        stateAckCharacteristic = nil
        pendingPeer = nil
        peerTimer?.invalidate()
        peerTimer = nil
        peerStateCharacteristic = nil
        peerAckWriteCharacteristic = nil
        pairInfoCharacteristic = nil
        reportedName = nil
        if targetPeripheralID == nil && !authenticated { scanAfterRejecting(found) }
        else { manager.connect(found) }
    }

    private func scanAfterRejecting(_ found: CBPeripheral) {
        skippedPeripherals[found.identifier] = Date().addingTimeInterval(30)
        peripheral = nil
        central.scanForPeripherals(withServices: [serviceID])
        DispatchQueue.main.asyncAfter(deadline: .now() + 31) { [weak self] in
            guard let self, !self.stopped, self.peripheral == nil else { return }
            self.central.stopScan()
            self.central.scanForPeripherals(withServices: [self.serviceID])
        }
    }

    func peripheral(_ found: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopped else { return }
        if let error { report("SERVICE ERROR \(error)"); onStatus(.message("服务发现失败，正在重连")); central.cancelPeripheralConnection(found); return }
        for service in found.services ?? [] where service.uuid == serviceID {
            found.discoverCharacteristics([stateWriteID, stateAckID, peerStateID, peerAckWriteID], for: service)
        }
        for service in found.services ?? [] where service.uuid == pairServiceID {
            found.discoverCharacteristics([pairInfoID], for: service)
        }
    }

    func peripheral(_ found: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !stopped else { return }
        if service.uuid == pairServiceID {
            pairInfoCharacteristic = service.characteristics?.first(where: { $0.uuid == pairInfoID })
            if let pairInfoCharacteristic { found.readValue(for: pairInfoCharacteristic) }
            return
        }
        if let error { report("CHARACTERISTIC ERROR \(error)"); onStatus(.message("服务不完整，正在重连")); central.cancelPeripheralConnection(found); return }
        stateWriteCharacteristic = service.characteristics?.first(where: { $0.uuid == stateWriteID })
        stateAckCharacteristic = service.characteristics?.first(where: { $0.uuid == stateAckID })
        peerStateCharacteristic = service.characteristics?.first(where: { $0.uuid == peerStateID })
        peerAckWriteCharacteristic = service.characteristics?.first(where: { $0.uuid == peerAckWriteID })
        guard let stateAckCharacteristic, stateWriteCharacteristic != nil,
              peerStateCharacteristic != nil, peerAckWriteCharacteristic != nil else { report("SERVICE INCOMPLETE"); onStatus(.message("服务不完整，正在重连")); central.cancelPeripheralConnection(found); return }
        found.setNotifyValue(true, for: stateAckCharacteristic)
        if let peerStateCharacteristic, peerAckWriteCharacteristic != nil {
            found.setNotifyValue(true, for: peerStateCharacteristic)
        }
    }

    func peripheral(_ found: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped else { return }
        if characteristic.uuid == peerStateID {
            if error == nil, characteristic.isNotifying { found.readValue(for: characteristic) }
            return
        }
        guard characteristic.uuid == stateAckID else { return }
        if let error { report("ACK SUBSCRIPTION FAILED \(error)"); onStatus(.message("回执订阅失败，正在重连")); central.cancelPeripheralConnection(found); return }
        guard characteristic.isNotifying else { return }
        report("READY; reconciling current input state")
        onStatus(.awaitingAck)
        sendCurrentState()
        if peerStateCharacteristic != nil && peerAckWriteCharacteristic != nil {
            peerTimer?.invalidate()
            peerTimer = Timer.scheduledTimer(withTimeInterval: PeerTiming.renewalSeconds,
                                             repeats: true) { [weak self] _ in
                guard let self, !self.stopped else { return }
                if self.desiredQuiet { self.sendCurrentState() }
                if let found = self.peripheral, let peerState = self.peerStateCharacteristic {
                    found.readValue(for: peerState)
                }
                if let found = self.peripheral, let info = self.pairInfoCharacteristic {
                    found.readValue(for: info)
                }
            }
        }
    }

    private func sendCurrentState() {
        guard !stopped, let found = peripheral, let stateWriteCharacteristic else { return }
        do {
            let update = PeerQuietUpdate(origin: PeerRole.initiator.rawValue, revision: MacCredentials.nextSequence(),
                                         quiet: desiredQuiet,
                                         validUntil: Int64(Date().timeIntervalSince1970) + PeerTiming.leaseSeconds,
                                         targetMilli: desiredTargetMilli, key: key)
            pendingPeer = update
            retryCount = 0
            found.writeValue(try JSONEncoder().encode(update), for: stateWriteCharacteristic, type: .withResponse)
            report("PEER STATE rev=\(update.revision) quiet=\(desiredQuiet)")
            schedulePeerAckRead(revision: update.revision)
        } catch {
            report("COMMAND ERROR \(error)")
        }
    }

    private func schedulePeerAckRead(revision: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let pending = self.pendingPeer, pending.revision == revision,
                  !self.stopped, let found = self.peripheral, let ack = self.stateAckCharacteristic else { return }
            if self.retryCount >= 4 || pending.validUntil <= Int64(Date().timeIntervalSince1970) {
                self.report("NO PEER ACK rev=\(revision)")
                self.onStatus(.message("状态未获确认，正在重连"))
                self.pendingPeer = nil
                self.central.cancelPeripheralConnection(found)
                return
            }
            self.retryCount += 1
            found.readValue(for: ack)
            self.schedulePeerAckRead(revision: revision)
        }
    }

    func peripheral(_ found: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped else { return }
        if let error { report("GATT WRITE FAILED \(error)"); onStatus(.message("发送失败，正在重连")); central.cancelPeripheralConnection(found) }
        else { report("GATT write accepted; awaiting application ACK") }
    }

    func peripheral(_ found: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == pairInfoID {
            if error == nil, let data = characteristic.value,
               let info = try? JSONDecoder().decode(PairingFrame.self, from: data),
               info.version == 3, info.kind == .info,
               let name = info.name?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty, name.count <= 32 {
                reportedName = name
                if authenticated { onPeerName(name) }
            }
            return
        }
        if characteristic.uuid == peerStateID {
            guard !stopped, error == nil, let data = characteristic.value,
                  let update = try? JSONDecoder().decode(PeerQuietUpdate.self, from: data),
                  update.valid(key: key, expectedOrigin: PeerRole.responder.rawValue,
                               now: Int64(Date().timeIntervalSince1970)) else { return }
            onPeerState(update) { [weak self] result in
                guard let self, !self.stopped, let found = self.peripheral,
                      let ackWrite = self.peerAckWriteCharacteristic else { return }
                let ack = PeerStateAck(origin: PeerRole.initiator.rawValue, revision: update.revision,
                                       quiet: update.quiet, result: result, key: self.key)
                if let data = try? JSONEncoder().encode(ack) {
                    found.writeValue(data, for: ackWrite, type: .withResponse)
                }
            }
            return
        }
        if characteristic.uuid == stateAckID, error == nil, let data = characteristic.value,
           let ack = try? JSONDecoder().decode(PeerStateAck.self, from: data),
           ack.valid(key: key, expectedOrigin: PeerRole.responder.rawValue),
           let pendingPeer, ack.revision == pendingPeer.revision,
           ack.quiet == pendingPeer.quiet {
            report("PEER ACK rev=\(ack.revision) result=\(ack.result)")
            onStatus(.ready)
            authenticated = true
            onAuthenticated(found.identifier)
            if let reportedName { onPeerName(reportedName) }
            onPeerAck(ack)
            if pendingPeer.targetMilli == ack.targetMilli { desiredTargetMilli = nil }
            self.pendingPeer = nil
            return
        }

    }
}
