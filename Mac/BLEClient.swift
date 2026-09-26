import CoreBluetooth
import Foundation
#if canImport(NearbyAudioCore)
import NearbyAudioCore
#endif

final class BLEClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceID = CBUUID(string: BLEIdentifiers.service)
    private let commandID = CBUUID(string: BLEIdentifiers.command)
    private let ackID = CBUUID(string: BLEIdentifiers.ack)
    private let key: Data
    private let onStatus: (String) -> Void
    private let onAck: (ControlAck) -> Void
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var ackCharacteristic: CBCharacteristic?
    private var pending: ControlCommand?
    private var retryCount = 0
    private var stopped = false
    private(set) var desiredQuiet = false
    private var desiredTargetMilli: Int?

    init(key: Data, onStatus: @escaping (String) -> Void = { _ in },
         onAck: @escaping (ControlAck) -> Void = { _ in }) {
        self.key = key
        self.onStatus = onStatus
        self.onAck = onAck
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

    func stop() {
        stopped = true
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard !stopped else { return }
        if manager.state == .poweredOn {
            report("BLUETOOTH ready; scanning")
            onStatus("正在搜索 iPad")
            manager.scanForPeripherals(withServices: [serviceID])
        } else {
            report("BLUETOOTH unavailable state=\(manager.state.rawValue)")
            onStatus(manager.state == .unauthorized ? "Mac 蓝牙权限未允许" : "Mac 蓝牙不可用")
        }
    }

    func centralManager(_ manager: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped, peripheral == nil else { return }
        peripheral = found
        manager.stopScan()
        report("DISCOVERED; connecting")
        onStatus("正在连接 iPad")
        manager.connect(found)
    }

    func centralManager(_ manager: CBCentralManager, didConnect found: CBPeripheral) {
        report("CONNECTED; discovering service")
        onStatus("已连接，正在验证服务")
        found.delegate = self
        found.discoverServices([serviceID])
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect found: CBPeripheral, error: Error?) {
        report("CONNECT FAILED \(String(describing: error))")
        onStatus("连接失败，正在重试")
        if !stopped { manager.connect(found) }
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral found: CBPeripheral, error: Error?) {
        report("DISCONNECTED; reconnecting")
        onStatus(stopped ? "已断开" : "连接中断，正在重连")
        commandCharacteristic = nil
        ackCharacteristic = nil
        pending = nil
        if !stopped { manager.connect(found) }
    }

    func peripheral(_ found: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { report("SERVICE ERROR \(error)"); onStatus("服务发现失败，正在重连"); central.cancelPeripheralConnection(found); return }
        for service in found.services ?? [] where service.uuid == serviceID {
            found.discoverCharacteristics([commandID, ackID], for: service)
        }
    }

    func peripheral(_ found: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { report("CHARACTERISTIC ERROR \(error)"); onStatus("服务不完整，正在重连"); central.cancelPeripheralConnection(found); return }
        commandCharacteristic = service.characteristics?.first(where: { $0.uuid == commandID })
        ackCharacteristic = service.characteristics?.first(where: { $0.uuid == ackID })
        guard let ackCharacteristic, commandCharacteristic != nil else { report("SERVICE INCOMPLETE"); onStatus("服务不完整，正在重连"); central.cancelPeripheralConnection(found); return }
        found.setNotifyValue(true, for: ackCharacteristic)
    }

    func peripheral(_ found: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == ackID else { return }
        if let error { report("ACK SUBSCRIPTION FAILED \(error)"); onStatus("回执订阅失败，正在重连"); central.cancelPeripheralConnection(found); return }
        guard characteristic.isNotifying else { return }
        report("READY; reconciling current input state")
        onStatus("iPad 已连接")
        sendCurrentState()
    }

    private func sendCurrentState() {
        guard !stopped, let found = peripheral, let commandCharacteristic else { return }
        do {
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

    private func scheduleAckRead(sequence: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let pending = self.pending, pending.sequence == sequence,
                  let found = self.peripheral, let ack = self.ackCharacteristic else { return }
            if self.retryCount >= 4 || pending.expiresAt <= Int64(Date().timeIntervalSince1970) {
                self.report("NO APPLICATION ACK seq=\(sequence)")
                self.onStatus("iPad 未确认命令，正在重连")
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
        if let error { report("GATT WRITE FAILED \(error)"); onStatus("发送失败，正在重连"); central.cancelPeripheralConnection(found) }
        else { report("GATT write accepted; awaiting application ACK") }
    }

    func peripheral(_ found: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == ackID, error == nil, let data = characteristic.value,
              let ack = try? JSONDecoder().decode(ControlAck.self, from: data), ack.valid(key: key),
              let pending, ack.sequence == pending.sequence, ack.quiet == pending.quiet else { return }
        report("APPLICATION ACK seq=\(ack.sequence) result=\(ack.result) volume=\(ack.volumeMilli)‰")
        onStatus("iPad 已连接")
        onAck(ack)
        if pending.targetMilli == ack.targetMilli { desiredTargetMilli = nil }
        self.pending = nil
    }
}
