import CoreBluetooth
import Foundation

@MainActor final class BLEServer: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    static let serviceID = CBUUID(string: "8A27D37F-A94F-4A53-AD7C-0D48CC8108CF")
    static let commandID = CBUUID(string: "E1FA496A-299F-4C84-9621-63396F75A3F2")
    static let ackID = CBUUID(string: "0F20B426-BBC9-48A4-A518-82827239AA9E")

    @Published private(set) var status = "正在启动"
    @Published private(set) var pairingCode = ""
    @Published private(set) var lastAction = "尚无命令"
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: "listeningEnabled") as? Bool ?? true
    private var manager: CBPeripheralManager?
    private var ackCharacteristic: CBMutableCharacteristic?
    private var restoredServices = false
    private var subscribed = Set<UUID>()
    private var key: Data?
    private var volume: VolumeCoordinator?
    private var lastSequence = UInt64(UserDefaults.standard.integer(forKey: "lastSequence"))
    private var lastAckData = UserDefaults.standard.data(forKey: "lastAck")

    private func note(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    override init() {
        super.init()
        do {
            key = try PairingStore.loadOrCreate()
            pairingCode = key!.base64EncodedString()
            volume = VolumeCoordinator()
            status = volume == nil ? "当前系统的媒体音量接口不兼容" : "等待蓝牙"
            note("BLUETOOTH_AUTHORIZATION \(CBPeripheralManager.authorization.rawValue)")
            manager = CBPeripheralManager(delegate: self, queue: .main,
                                          options: [CBPeripheralManagerOptionRestoreIdentifierKey: "NearbyAudioPeripheral"])
            note("BLUETOOTH_MANAGER_CREATED")
        } catch {
            status = "无法读取配对密钥：\(error.localizedDescription)"
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "listeningEnabled")
        if value {
            guard manager?.state == .poweredOn else { return }
            publishService()
        } else {
            manager?.stopAdvertising()
            manager?.removeAllServices()
            ackCharacteristic = nil
            restoredServices = false
            subscribed.removeAll()
            _ = volume?.apply(quiet: false, target: 0)
            status = "已停止监听"
        }
    }

    func restoreNow() {
        guard let volume else { return }
        let result = volume.apply(quiet: false, target: 0)
        lastAction = "手动恢复：\(result.0)"
    }

    private func publishService() {
        guard enabled, let manager, manager.state == .poweredOn else { return }
        if restoredServices {
            if !manager.isAdvertising { manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]]) }
            status = "蓝牙已就绪"
            return
        }
        let command = CBMutableCharacteristic(type: Self.commandID, properties: [.write], value: nil, permissions: [.writeable])
        let ack = CBMutableCharacteristic(type: Self.ackID, properties: [.read, .notify], value: nil, permissions: [.readable])
        ackCharacteristic = ack
        let service = CBMutableService(type: Self.serviceID, primary: true)
        service.characteristics = [command, ack]
        manager.add(service)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        status = peripheral.state == .poweredOn ? "蓝牙已开启" : "蓝牙不可用（\(peripheral.state.rawValue)）"
        note("BLUETOOTH_STATE \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn { publishService() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState state: [String: Any]) {
        if let services = state[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService],
           let service = services.first(where: { $0.uuid == Self.serviceID }) {
            restoredServices = true
            ackCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.ackID }) as? CBMutableCharacteristic
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        note("SERVICE \(error.map(String.init(describing:)) ?? "ready")")
        if let error { status = "发布服务失败：\(error.localizedDescription)"; return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        note("ADVERTISING \(error.map(String.init(describing:)) ?? "ready")")
        status = error.map { "蓝牙广播失败：\($0.localizedDescription)" } ?? "蓝牙已就绪"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.ackID, request.offset == 0 else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = lastAckData ?? Data()
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard enabled, request.characteristic.uuid == Self.commandID,
                  let data = request.value, data.count <= 512,
                  let key, let command = try? JSONDecoder().decode(ControlCommand.self, from: data),
                  command.valid(key: key, now: Int64(Date().timeIntervalSince1970)) else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }
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
            let result = volume?.apply(quiet: command.quiet, target: target) ?? ("unsupported", -1)
            let ack = ControlAck(sequence: command.sequence, quiet: command.quiet,
                                 result: result.0, volumeMilli: result.1,
                                 targetMilli: Int((target * 1000).rounded()), key: key)
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

    private func publishAck() {
        guard let manager, let ackCharacteristic, let lastAckData else { return }
        _ = manager.updateValue(lastAckData, for: ackCharacteristic, onSubscribedCentrals: nil)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == Self.ackID { subscribed.insert(central.identifier) }
        status = "Mac 已连接"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.ackID else { return }
        subscribed.remove(central.identifier)
        if subscribed.isEmpty {
            let result = volume?.apply(quiet: false, target: 0)
            if let result { lastAction = "连接中断：\(result.0)" }
            status = "等待 Mac 重连"
        }
    }
}
