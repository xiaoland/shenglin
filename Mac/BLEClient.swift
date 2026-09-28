import CoreBluetooth
import Foundation
#if canImport(NearbyAudioCore)
import NearbyAudioCore
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
    private let commandID = CBUUID(string: BLEIdentifiers.command)
    private let ackID = CBUUID(string: BLEIdentifiers.ack)
    private let peerStateID = CBUUID(string: BLEIdentifiers.peerState)
    private let peerAckWriteID = CBUUID(string: BLEIdentifiers.peerAckWrite)
    private let key: Data
    private let onStatus: (BLEConnectionState) -> Void
    private let onAck: (ControlAck) -> Void
    private let onPeerAck: (PeerStateAck) -> Void
    private let onPeerState: (PeerQuietUpdate, @escaping (String) -> Void) -> Void
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var ackCharacteristic: CBCharacteristic?
    private var peerStateCharacteristic: CBCharacteristic?
    private var peerAckWriteCharacteristic: CBCharacteristic?
    private var pending: ControlCommand?
    private var pendingPeer: PeerQuietUpdate?
    private var peerTimer: Timer?
    private var retryCount = 0
    private var stopped = false
    private(set) var desiredQuiet = false
    private var desiredTargetMilli: Int?

    init(key: Data, onStatus: @escaping (BLEConnectionState) -> Void = { _ in },
         onAck: @escaping (ControlAck) -> Void = { _ in },
         onPeerAck: @escaping (PeerStateAck) -> Void = { _ in },
         onPeerState: @escaping (PeerQuietUpdate, @escaping (String) -> Void) -> Void = { _, done in done("unsupported") }) {
        self.key = key
        self.onStatus = onStatus
        self.onAck = onAck
        self.onPeerAck = onPeerAck
        self.onPeerState = onPeerState
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
        if commandCharacteristic != nil { sendCurrentState() }
    }

    func setTargetMilli(_ target: Int) {
        guard (0...500).contains(target), target != desiredTargetMilli else { return }
        desiredTargetMilli = target
        if commandCharacteristic != nil { sendCurrentState() }
    }

    func confirmTargetMilli(_ target: Int?) {
        if desiredTargetMilli == target { desiredTargetMilli = nil }
    }

    func stop() {
        stopped = true
        pending = nil
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
        guard !stopped, peripheral == nil else { return }
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
        found.discoverServices([serviceID])
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect found: CBPeripheral, error: Error?) {
        guard !stopped else { return }
        report("CONNECT FAILED \(String(describing: error))")
        onStatus(.message("连接失败，正在重试"))
        if !stopped { manager.connect(found) }
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral found: CBPeripheral, error: Error?) {
        guard !stopped else { return }
        report("DISCONNECTED; reconnecting")
        onStatus(.message("连接中断，正在重连"))
        commandCharacteristic = nil
        ackCharacteristic = nil
        pending = nil
        pendingPeer = nil
        peerTimer?.invalidate()
        peerTimer = nil
        peerStateCharacteristic = nil
        peerAckWriteCharacteristic = nil
        manager.connect(found)
    }

    func peripheral(_ found: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopped else { return }
        if let error { report("SERVICE ERROR \(error)"); onStatus(.message("服务发现失败，正在重连")); central.cancelPeripheralConnection(found); return }
        for service in found.services ?? [] where service.uuid == serviceID {
            found.discoverCharacteristics([commandID, ackID, peerStateID, peerAckWriteID], for: service)
        }
    }

    func peripheral(_ found: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !stopped else { return }
        if let error { report("CHARACTERISTIC ERROR \(error)"); onStatus(.message("服务不完整，正在重连")); central.cancelPeripheralConnection(found); return }
        commandCharacteristic = service.characteristics?.first(where: { $0.uuid == commandID })
        ackCharacteristic = service.characteristics?.first(where: { $0.uuid == ackID })
        peerStateCharacteristic = service.characteristics?.first(where: { $0.uuid == peerStateID })
        peerAckWriteCharacteristic = service.characteristics?.first(where: { $0.uuid == peerAckWriteID })
        guard let ackCharacteristic, commandCharacteristic != nil else { report("SERVICE INCOMPLETE"); onStatus(.message("服务不完整，正在重连")); central.cancelPeripheralConnection(found); return }
        found.setNotifyValue(true, for: ackCharacteristic)
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
        guard characteristic.uuid == ackID else { return }
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
            }
        }
    }

    private func sendCurrentState() {
        guard !stopped, let found = peripheral, let commandCharacteristic else { return }
        do {
            if peerStateCharacteristic != nil && peerAckWriteCharacteristic != nil {
                let update = PeerQuietUpdate(origin: "mac", revision: MacCredentials.nextSequence(),
                                             quiet: desiredQuiet,
                                             validUntil: Int64(Date().timeIntervalSince1970) + PeerTiming.leaseSeconds,
                                             targetMilli: desiredTargetMilli, key: key)
                pendingPeer = update
                pending = nil
                retryCount = 0
                found.writeValue(try JSONEncoder().encode(update), for: commandCharacteristic, type: .withResponse)
                report("PEER STATE rev=\(update.revision) quiet=\(desiredQuiet)")
                schedulePeerAckRead(revision: update.revision)
                return
            }
            let sequence = MacCredentials.nextSequence()
            let command = ControlCommand(sequence: sequence, quiet: desiredQuiet,
                                         expiresAt: Int64(Date().timeIntervalSince1970) + 15,
                                         targetMilli: desiredTargetMilli, key: key)
            pending = command
            retryCount = 0
            found.writeValue(try JSONEncoder().encode(command), for: commandCharacteristic, type: .withResponse)
            report("COMMAND seq=\(sequence) quiet=\(desiredQuiet)")
            scheduleAckRead(sequence: sequence)
        } catch {
            report("COMMAND ERROR \(error)")
        }
    }

    private func schedulePeerAckRead(revision: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let pending = self.pendingPeer, pending.revision == revision,
                  !self.stopped, let found = self.peripheral, let ack = self.ackCharacteristic else { return }
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

    private func scheduleAckRead(sequence: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let pending = self.pending, pending.sequence == sequence,
                  !self.stopped, let found = self.peripheral, let ack = self.ackCharacteristic else { return }
            if self.retryCount >= 4 || pending.expiresAt <= Int64(Date().timeIntervalSince1970) {
                self.report("NO APPLICATION ACK seq=\(sequence)")
                self.onStatus(.message("命令未获确认，正在重连"))
                self.pending = nil
                self.central.cancelPeripheralConnection(found)
                return
            }
            self.retryCount += 1
            found.readValue(for: ack)
            self.scheduleAckRead(sequence: sequence)
        }
    }

    func peripheral(_ found: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped else { return }
        if let error { report("GATT WRITE FAILED \(error)"); onStatus(.message("发送失败，正在重连")); central.cancelPeripheralConnection(found) }
        else { report("GATT write accepted; awaiting application ACK") }
    }

    func peripheral(_ found: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == peerStateID {
            guard !stopped, error == nil, let data = characteristic.value,
                  let update = try? JSONDecoder().decode(PeerQuietUpdate.self, from: data),
                  update.valid(key: key, expectedOrigin: "ipad",
                               now: Int64(Date().timeIntervalSince1970)) else { return }
            onPeerState(update) { [weak self] result in
                guard let self, !self.stopped, let found = self.peripheral,
                      let ackWrite = self.peerAckWriteCharacteristic else { return }
                let ack = PeerStateAck(origin: "mac", revision: update.revision,
                                       quiet: update.quiet, result: result, key: self.key)
                if let data = try? JSONEncoder().encode(ack) {
                    found.writeValue(data, for: ackWrite, type: .withResponse)
                }
            }
            return
        }
        if characteristic.uuid == ackID, error == nil, let data = characteristic.value,
           let ack = try? JSONDecoder().decode(PeerStateAck.self, from: data),
           ack.valid(key: key, expectedOrigin: "ipad"),
           let pendingPeer, ack.revision == pendingPeer.revision,
           ack.quiet == pendingPeer.quiet {
            report("PEER ACK rev=\(ack.revision) result=\(ack.result)")
            onStatus(.ready)
            onPeerAck(ack)
            if pendingPeer.targetMilli == ack.targetMilli { desiredTargetMilli = nil }
            self.pendingPeer = nil
            return
        }
        guard !stopped, characteristic.uuid == ackID, error == nil, let data = characteristic.value,
              let ack = try? JSONDecoder().decode(ControlAck.self, from: data), ack.valid(key: key),
              let pending, ack.sequence == pending.sequence, ack.quiet == pending.quiet else { return }
        report("APPLICATION ACK seq=\(ack.sequence) result=\(ack.result) volume=\(ack.volumeMilli)‰")
        onStatus(.ready)
        onAck(ack)
        if pending.targetMilli == ack.targetMilli { desiredTargetMilli = nil }
        self.pending = nil
    }
}
