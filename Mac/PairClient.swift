import CoreBluetooth
import Foundation
#if canImport(NearbyAudioCore)
import NearbyAudioCore
#endif

struct NearbyPad: Identifiable {
    let id: UUID
    let name: String
}

final class PairClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceID = CBUUID(string: BLEIdentifiers.service)
    private let pairServiceID = CBUUID(string: BLEIdentifiers.pairingService)
    private let writeID = CBUUID(string: BLEIdentifiers.pairingWrite)
    private let responseID = CBUUID(string: BLEIdentifiers.pairingResponse)
    private let infoID = CBUUID(string: BLEIdentifiers.pairingInfo)
    private let onDevices: ([NearbyPad]) -> Void
    private let onStatus: (String) -> Void
    private let onNeedCode: (String) -> Void
    private let onComplete: (Data) -> Void
    private let onFailure: (String) -> Void
    private var central: CBCentralManager!
    private var found = [UUID: CBPeripheral]()
    private var names = [UUID: String]()
    private var selected: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private var infoCharacteristic: CBCharacteristic?
    private var responseSubscribed = false
    private var infoAllowsPairing = false
    private var codeRequested = false
    private var cancelAfterWrite = false
    private var handshake: PairingInitiator?
    private var handled = Set<PairingFrame.Kind>()
    private var stopped = false
    private var deadline = Date().addingTimeInterval(120)
    private var timer: Timer?

    init(onDevices: @escaping ([NearbyPad]) -> Void, onStatus: @escaping (String) -> Void,
         onNeedCode: @escaping (String) -> Void, onComplete: @escaping (Data) -> Void,
         onFailure: @escaping (String) -> Void) {
        self.onDevices = onDevices
        self.onStatus = onStatus
        self.onNeedCode = onNeedCode
        self.onComplete = onComplete
        self.onFailure = onFailure
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.stopped, Date() >= self.deadline else { return }
            self.fail("配对已超时，请在两端重新开始")
        }
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stop()
        onFailure(message)
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        central.stopScan()
        if let selected { central.cancelPeripheralConnection(selected) }
        handshake = nil
    }

    private func publishDevices() {
        onDevices(names.map { NearbyPad(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard !stopped else { return }
        guard manager.state == .poweredOn else {
            if manager.state == .unauthorized || manager.state == .poweredOff || manager.state == .unsupported {
                fail(manager.state == .unauthorized ? "Mac 蓝牙权限未允许" : "Mac 蓝牙不可用")
            }
            return
        }
        onStatus("正在查找附近的 iPad")
        manager.scanForPeripherals(withServices: [serviceID])
    }

    func centralManager(_ manager: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped else { return }
        found[peripheral.identifier] = peripheral
        names[peripheral.identifier] = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "附近的 iPad"
        publishDevices()
    }

    func choose(_ id: UUID) {
        guard !stopped, selected == nil, let peripheral = found[id] else { return }
        selected = peripheral
        central.stopScan()
        onStatus("正在连接 \(names[id] ?? "iPad")")
        central.connect(peripheral)
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !stopped else { return }
        onStatus("已连接，正在检查 iPad 配对模式")
        peripheral.delegate = self
        peripheral.discoverServices([pairServiceID])
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("无法连接 iPad，请重试")
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if !stopped { fail("配对连接中断，请重新开始") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopped else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == pairServiceID }) else {
            fail("iPad 尚未发布新版配对服务")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !stopped else { return }
        guard error == nil else { fail("无法读取 iPad 配对服务"); return }
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == writeID })
        responseCharacteristic = service.characteristics?.first(where: { $0.uuid == responseID })
        infoCharacteristic = service.characteristics?.first(where: { $0.uuid == infoID })
        guard writeCharacteristic != nil, let responseCharacteristic, let infoCharacteristic else {
            let found = (service.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ",")
            fail("iPad 配对服务缺少新特征（已发现：\(found)）")
            return
        }
        peripheral.setNotifyValue(true, for: responseCharacteristic)
        peripheral.readValue(for: infoCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped else { return }
        guard characteristic.uuid == responseID else { return }
        guard error == nil, characteristic.isNotifying else { fail("无法订阅配对确认"); return }
        responseSubscribed = true
        beginIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped, !cancelAfterWrite, error == nil, let data = characteristic.value,
              data.count <= 512, let frame = try? JSONDecoder().decode(PairingFrame.self, from: data) else { return }
        if characteristic.uuid == infoID {
            guard frame.version == 2, frame.kind == .info else { fail("iPad 配对信息无效"); return }
            if let name = frame.name, let id = selected?.identifier {
                names[id] = name
                publishDevices()
            }
            infoAllowsPairing = frame.pairingMode == true
            if infoAllowsPairing { beginIfReady() }
            else {
                onStatus("请在 iPad App 点按“开始 2 分钟配对”")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !self.stopped, self.handshake == nil,
                          let selected = self.selected, let info = self.infoCharacteristic else { return }
                    selected.readValue(for: info)
                }
            }
            return
        }
        guard characteristic.uuid == responseID, let handshake,
              frame.session == handshake.session else { return }
        if frame.kind == .reject { fail("验证码未通过或 iPad 已取消配对，请重新开始"); return }
        guard !handled.contains(frame.kind) else { return }
        do {
            switch frame.kind {
            case .offer:
                let next = try handshake.receiveOffer(frame)
                handled.insert(.offer)
                send(next)
                onStatus("正在核验验证码并等待 iPad 确认")
            case .finish:
                let key = try handshake.receiveFinish(frame)
                handled.insert(.finish)
                stop()
                onComplete(key)
            default: break
            }
        } catch { fail("配对校验失败：\(error.localizedDescription)") }
    }

    private func beginIfReady() {
        guard !stopped, responseSubscribed, infoAllowsPairing, !codeRequested else { return }
        codeRequested = true
        onNeedCode(selected.flatMap { names[$0.identifier] } ?? "iPad")
        onStatus("请输入 iPad 显示的 6 位验证码")
    }

    func enterCode(_ code: String) throws {
        guard !stopped, codeRequested, handshake == nil else { throw PairingError.wrongStep }
        let macName = Host.current().localizedName ?? "Mac"
        let session = try PairingInitiator(code: code, macName: macName)
        handshake = session
        deadline = Date().addingTimeInterval(90)
        onStatus("正在进行安全配对")
        send(session.startFrame)
    }

    func reject() {
        guard let handshake, !stopped else { stop(); return }
        cancelAfterWrite = true
        send(PairingFrame(kind: .reject, session: handshake.session))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in stop() }
    }

    private func send(_ frame: PairingFrame) {
        guard !stopped, let selected, let writeCharacteristic,
              let data = try? JSONEncoder().encode(frame),
              data.count <= selected.maximumWriteValueLength(for: .withResponse) else {
            fail("配对消息无法发送")
            return
        }
        selected.writeValue(data, for: writeCharacteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped else { return }
        guard characteristic.uuid == writeID else { return }
        if cancelAfterWrite { stop(); return }
        guard error == nil else { fail("iPad 拒绝了配对步骤，请重新开始"); return }
        if let responseCharacteristic {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, !self.stopped else { return }
                peripheral.readValue(for: responseCharacteristic)
            }
        }
    }
}
