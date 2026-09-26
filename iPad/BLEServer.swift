import CoreBluetooth
import Foundation
import UIKit

@MainActor final class BLEServer: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    static let serviceID = CBUUID(string: "8A27D37F-A94F-4A53-AD7C-0D48CC8108CF")
    static let commandID = CBUUID(string: "E1FA496A-299F-4C84-9621-63396F75A3F2")
    static let ackID = CBUUID(string: "0F20B426-BBC9-48A4-A518-82827239AA9E")
    static let pairWriteID = CBUUID(string: "01FA287F-9E5C-4A8A-8B58-23A9808981F4")
    static let pairResponseID = CBUUID(string: "D56446C2-AB92-43C6-B80F-BE5E964015B4")
    static let pairInfoID = CBUUID(string: "BF903515-CC03-4056-A7D0-16E3267ABEB4")

    @Published private(set) var status = "正在启动"
    @Published private(set) var isPaired = false
    @Published private(set) var pairingMode = false
    @Published private(set) var pairingStatus = "配对模式未开启"
    @Published private(set) var shortCode: String?
    @Published private(set) var localConfirmed = false
    @Published private(set) var peerName = ""
    @Published private(set) var lastAction = "尚无命令"
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: "listeningEnabled") as? Bool ?? true
    private var manager: CBPeripheralManager?
    private var ackCharacteristic: CBMutableCharacteristic?
    private var pairResponseCharacteristic: CBMutableCharacteristic?
    private var pairResponseData: Data?
    private var restoredServices = false
    private var subscribed = Set<UUID>()
    private var key: Data?
    private var pendingKey: Data?
    private var pairing: PairingResponder?
    private var pairingCentral: UUID?
    private var pairingDeadline: Date?
    private var pairAttempts = 0
    private var pairingTimer: Timer?
    private var volume: VolumeCoordinator?
    private var lastSequence = UInt64(UserDefaults.standard.integer(forKey: "lastSequence"))
    private var lastAckData = UserDefaults.standard.data(forKey: "lastAck")

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
            cancelPairing(reason: "已停止配对")
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
            shortCode = nil
            localConfirmed = false
            peerName = ""
            pairingMode = true
            pairingDeadline = Date().addingTimeInterval(120)
            pairingStatus = "已开放 2 分钟，请在 Mac 菜单栏开始查找"
            pairingTimer?.invalidate()
            pairingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let deadline = self.pairingDeadline, Date() >= deadline else { return }
                    self.cancelPairing(reason: "配对已超时，请重新开启")
                }
            }
        } catch { pairingStatus = "无法准备配对：\(error.localizedDescription)" }
    }

    func confirmPairing() {
        guard let pairing, shortCode != nil, !localConfirmed else { return }
        do {
            let finish = try pairing.confirmLocal()
            localConfirmed = true
            if let finish { finishPairing(finish) }
            else { pairingStatus = "本机已确认，等待 Mac 确认" }
        } catch { cancelPairing(reason: error.localizedDescription) }
    }

    func rejectPairing() { cancelPairing(reason: "已拒绝配对") }

    private func cancelPairing(reason: String) {
        if let pairing, let central = pairingCentral {
            publishPair(PairingFrame(kind: .reject, session: pairing.session), to: central)
        }
        pairing = nil
        pairingCentral = nil
        shortCode = nil
        localConfirmed = false
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
            pairingStatus = "双方已确认，等待 Mac 自动连接"
            pairingMode = false
            pairingDeadline = nil
            pairingTimer?.invalidate()
            pairingTimer = nil
            publishPair(frame, to: central)
            pairing = nil
            pairingCentral = nil
            shortCode = nil
            localConfirmed = false
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
        if restoredServices {
            if !manager.isAdvertising { advertise() }
            status = "蓝牙已就绪"
            return
        }
        let command = CBMutableCharacteristic(type: Self.commandID, properties: [.write], value: nil, permissions: [.writeable])
        let ack = CBMutableCharacteristic(type: Self.ackID, properties: [.read, .notify], value: nil, permissions: [.readable])
        let pairWrite = CBMutableCharacteristic(type: Self.pairWriteID, properties: [.write], value: nil, permissions: [.writeable])
        let pairResponse = CBMutableCharacteristic(type: Self.pairResponseID, properties: [.read, .notify], value: nil, permissions: [.readable])
        let pairInfo = CBMutableCharacteristic(type: Self.pairInfoID, properties: [.read], value: nil, permissions: [.readable])
        ackCharacteristic = ack
        pairResponseCharacteristic = pairResponse
        let service = CBMutableService(type: Self.serviceID, primary: true)
        service.characteristics = [command, ack, pairWrite, pairResponse, pairInfo]
        manager.add(service)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        status = peripheral.state == .poweredOn ? "蓝牙已开启" : "蓝牙不可用（\(peripheral.state.rawValue)）"
        note("BLUETOOTH_STATE \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn { publishService() }
        else if pairingMode { cancelPairing(reason: "蓝牙已关闭，配对中止") }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState state: [String: Any]) {
        if let services = state[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService],
           let service = services.first(where: { $0.uuid == Self.serviceID }) {
            let characteristics = service.characteristics ?? []
            if let ack = characteristics.first(where: { $0.uuid == Self.ackID }) as? CBMutableCharacteristic,
               let pairResponse = characteristics.first(where: { $0.uuid == Self.pairResponseID }) as? CBMutableCharacteristic {
                restoredServices = true
                ackCharacteristic = ack
                pairResponseCharacteristic = pairResponse
            } else {
                peripheral.removeAllServices()
                if peripheral.state == .poweredOn { publishService() }
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        note("SERVICE \(error.map(String.init(describing:)) ?? "ready")")
        if let error { status = "发布服务失败：\(error.localizedDescription)"; return }
        advertise()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        note("ADVERTISING \(error.map(String.init(describing:)) ?? "ready")")
        status = error.map { "蓝牙广播失败：\($0.localizedDescription)" } ?? "蓝牙已就绪"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let data: Data
        switch request.characteristic.uuid {
        case Self.ackID:
            data = lastAckData ?? Data()
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
                    key = try PairingStore.promotePending()
                    self.pendingKey = nil
                    lastSequence = 0
                    lastAckData = nil
                    isPaired = true
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

    private func receivePairWrite(_ request: CBATTRequest, peripheral: CBPeripheralManager) {
        guard enabled, let data = request.value, data.count <= 512,
              let frame = try? JSONDecoder().decode(PairingFrame.self, from: data), frame.version == 1 else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        if frame.kind == .start {
            guard pairingMode, pairingDeadline.map({ $0 > Date() }) == true,
                  pairAttempts < 3, pairing == nil else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                return
            }
            do {
                let session = try PairingResponder(start: frame, padName: deviceName)
                pairAttempts += 1
                pairing = session
                pairingCentral = request.central.identifier
                peerName = frame.name ?? "Mac"
                pairingStatus = "已连接 \(peerName)，正在生成验证码"
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
            case .nonceA:
                let response = try pairing.receiveNonceA(frame)
                shortCode = pairing.shortCode
                localConfirmed = false
                pairingStatus = "请核对 Mac 与 iPad 的 6 位验证码；一致才确认"
                peripheral.respond(to: request, withResult: .success)
                publishPair(response, to: request.central.identifier)
            case .confirm:
                let finish = try pairing.receiveConfirm(frame)
                peripheral.respond(to: request, withResult: .success)
                if let finish { finishPairing(finish) }
                else { pairingStatus = "Mac 已确认，请在 iPad 核对后确认" }
            case .reject:
                peripheral.respond(to: request, withResult: .success)
                cancelPairing(reason: "Mac 已取消配对")
            default:
                peripheral.respond(to: request, withResult: .unlikelyError)
            }
        } catch {
            peripheral.respond(to: request, withResult: .unlikelyError)
            cancelPairing(reason: "配对失败：\(error.localizedDescription)")
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
        if characteristic.uuid == Self.pairResponseID, pairingCentral == central.identifier,
           pairing?.confirmedKey == nil {
            pairing = nil
            pairingCentral = nil
            pairResponseData = nil
            shortCode = nil
            localConfirmed = false
            peerName = ""
            pairingStatus = "连接中断，请在 Mac 重试配对"
        }
        guard characteristic.uuid == Self.ackID else { return }
        subscribed.remove(central.identifier)
        if subscribed.isEmpty {
            let result = volume?.apply(quiet: false, target: 0)
            if let result { lastAction = "连接中断：\(result.0)" }
            status = "等待 Mac 重连"
        }
    }
}
