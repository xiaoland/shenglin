import CoreBluetooth
import Foundation
import Network

// 隔离协议探针：只模拟需求，不访问音频、正式偏好或 Keychain。
@MainActor private final class PeripheralProbe: NSObject, @preconcurrency CBPeripheralManagerDelegate {
    private let serviceID = CBUUID(string: BLEIdentifiers.service)
    private let writeID = CBUUID(string: BLEIdentifiers.stateWrite)
    private let ackID = CBUUID(string: BLEIdentifiers.stateAck)
    private let stateID = CBUUID(string: BLEIdentifiers.peerState)
    private let peerAckID = CBUUID(string: BLEIdentifiers.peerAckWrite)
    private var pairing: WiFiPairServer?
    private var link: WiFiPeer?
    private var diagnosticBrowser: NWBrowser?
    private var manager: CBPeripheralManager?
    private var peer: PairedPeer?
    private var activated = false
    private var revision: UInt64 = 0
    private var quiet = false
    private var timer: Timer?
    private var ackCharacteristic: CBMutableCharacteristic?
    private var stateCharacteristic: CBMutableCharacteristic?
    private var authenticated = Set<UUID>()
    private var lastAck = [UUID: Data]()
    private var snapshots = [UUID: [CBUUID: Data]]()
    private var pending = [UUID: [UInt64: PeerQuietUpdate]]()

    func event(_ values: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: values) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }

    func start() throws {
        pairing = try WiFiPairServer(localName: "声邻蓝牙外设探针", platform: .ipad,
            onStatus: { [weak self] in self?.event(["status": $0]) },
            onComplete: { [weak self] in self?.paired($0) })
        try pairing!.start()
        event(["code": pairing!.code, "name": "声邻蓝牙外设探针", "platform": "ipad"])
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    private func localUpdate() -> PeerQuietUpdate {
        revision += 1
        return PeerQuietUpdate(origin: peer!.localRole.rawValue, revision: revision, quiet: quiet,
            validUntil: Int64(Date().timeIntervalSince1970) + PeerTiming.leaseSeconds, key: peer!.key)
    }

    private func paired(_ peer: PairedPeer) {
        self.peer = peer
        let identifier = Data(base64Encoded: Authentication.sign("wifi-service", key: peer.key))!.prefix(8)
        event(["paired": peer.platform.rawValue, "localRole": peer.localRole.rawValue,
               "expectedService": "Shenglin-" + identifier.map { String(format: "%02x", $0) }.joined()])
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .other, .loopback]
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_shenglin._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.event(["browseState": String(describing: state)]) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.event(["browseEndpoints": results.map { String(describing: $0.endpoint) }]) }
        }
        diagnosticBrowser = browser
        browser.start(queue: .main)
        link = WiFiPeer(localOrigin: peer.localRole.rawValue, remoteOrigin: peer.localRole.remote.rawValue,
            listens: peer.localRole == .initiator, key: peer.key, localUpdate: { [unowned self] in localUpdate() },
            localName: { "声邻蓝牙外设探针" }, receiveName: { [weak self] _ in self?.event(["nameVerified": true]) },
            receiveUpdate: { [weak self] update in
                self?.event(["transport": "lan", "receivedQuiet": update.quiet, "revision": update.revision])
                return ("alreadyRestored", nil)
            }, receiveAck: { [weak self] ack in
                self?.event(["transport": "lan", "ack": ack.result, "quiet": ack.quiet])
            }, verifiedChanged: { [weak self] verified in
                guard let self else { return }
                event(["lanVerified": verified])
                if verified && !activated {
                    activated = true
                    manager = CBPeripheralManager(delegate: self, queue: .main)
                }
            }, networkScope: .lan, onIssue: { [weak self] issue in
                self?.event(["lanIssue": issue ?? "ready"])
            })
        link?.start()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        event(["bleState": peripheral.state.rawValue])
        guard peripheral.state == .poweredOn else { authenticated.removeAll(); return }
        let write = CBMutableCharacteristic(type: writeID, properties: [.write], value: nil, permissions: [.writeable])
        let ack = CBMutableCharacteristic(type: ackID, properties: [.read, .notify], value: nil, permissions: [.readable])
        let state = CBMutableCharacteristic(type: stateID, properties: [.read, .notify], value: nil, permissions: [.readable])
        let peerAck = CBMutableCharacteristic(type: peerAckID, properties: [.write], value: nil, permissions: [.writeable])
        let service = CBMutableService(type: serviceID, primary: true)
        service.characteristics = [write, ack, state, peerAck]
        ackCharacteristic = ack
        stateCharacteristic = state
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { event(["bleError": error.localizedDescription]); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID], CBAdvertisementDataLocalNameKey: "声邻蓝牙探针"])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { event(["bleError": error.localizedDescription]) }
        else { event(["bleAdvertising": true]) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let id = request.central.identifier
        let data: Data
        if request.offset == 0 {
            if request.characteristic.uuid == ackID { data = lastAck[id] ?? Data() }
            else if request.characteristic.uuid == stateID, authenticated.contains(id) {
                let update = localUpdate()
                pending[id, default: [:]][update.revision] = update
                data = (try? JSONEncoder().encode(update)) ?? Data()
            } else { peripheral.respond(to: request, withResult: .readNotPermitted); return }
            snapshots[id, default: [:]][request.characteristic.uuid] = data
        } else if let snapshot = snapshots[id]?[request.characteristic.uuid] { data = snapshot }
        else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        guard request.offset <= data.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = data.dropFirst(request.offset)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let request = requests.first, let peer else { return }
        guard requests.allSatisfy({ $0.central.identifier == request.central.identifier &&
            $0.characteristic.uuid == request.characteristic.uuid && $0.value != nil }),
            let data = BLEAttributeWrite.assemble(requests.map { ($0.offset, $0.value ?? Data()) }) else {
            peripheral.respond(to: request, withResult: .invalidAttributeValueLength); return
        }
        let id = request.central.identifier
        if request.characteristic.uuid == writeID,
           let update = try? JSONDecoder().decode(PeerQuietUpdate.self, from: data),
           update.valid(key: peer.key, expectedOrigin: peer.localRole.remote.rawValue, now: Int64(Date().timeIntervalSince1970)) {
            if authenticated.insert(id).inserted { event(["bleAuthenticated": true]) }
            event(["transport": "ble", "receivedQuiet": update.quiet, "revision": update.revision])
            let ack = PeerStateAck(origin: peer.localRole.rawValue, revision: update.revision, quiet: update.quiet,
                                   result: "alreadyRestored", key: peer.key)
            let encoded = try! JSONEncoder().encode(ack)
            lastAck[id] = encoded
            peripheral.respond(to: request, withResult: .success)
            if let characteristic = ackCharacteristic, encoded.count <= request.central.maximumUpdateValueLength {
                peripheral.updateValue(encoded, for: characteristic, onSubscribedCentrals: [request.central])
            }
        } else if request.characteristic.uuid == peerAckID,
                  let ack = try? JSONDecoder().decode(PeerStateAck.self, from: data),
                  ack.valid(key: peer.key, expectedOrigin: peer.localRole.remote.rawValue),
                  let expected = pending[id]?[ack.revision], expected.validUntil > Int64(Date().timeIntervalSince1970), ack.quiet == expected.quiet {
            event(["transport": "ble", "ack": ack.result, "quiet": ack.quiet, "revision": ack.revision])
            pending[id]?.removeValue(forKey: ack.revision)
            peripheral.respond(to: request, withResult: .success)
        } else {
            event(["bleRejected": true, "bytes": data.count])
            peripheral.respond(to: request, withResult: .unlikelyError)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        event(["bleSubscribed": characteristic.uuid.uuidString, "maximumUpdateBytes": central.maximumUpdateValueLength])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == ackID {
            authenticated.remove(central.identifier)
            snapshots.removeValue(forKey: central.identifier)
            pending.removeValue(forKey: central.identifier)
            lastAck.removeValue(forKey: central.identifier)
            event(["bleDisconnected": true])
        }
    }

    private func publish() {
        let now = Int64(Date().timeIntervalSince1970)
        for id in pending.keys { pending[id] = pending[id]?.filter { $0.value.validUntil > now } }
        link?.sendCurrentState()
        guard let manager, let characteristic = stateCharacteristic else { return }
        for central in characteristic.subscribedCentrals ?? [] where authenticated.contains(central.identifier) {
            let update = localUpdate()
            guard let data = try? JSONEncoder().encode(update), data.count <= central.maximumUpdateValueLength else { continue }
            pending[central.identifier, default: [:]][update.revision] = update
            manager.updateValue(data, for: characteristic, onSubscribedCentrals: [central])
        }
    }

    func command(_ line: String) {
        switch line {
        case "quiet": quiet = true; publish(); event(["quiet": true])
        case "idle": quiet = false; publish(); event(["quiet": false])
        case "lanoff": link?.stop(); link = nil; event(["lanStopped": true])
        case "quit": link?.stop(); pairing?.stop(); manager?.stopAdvertising(); manager?.removeAllServices(); exit(0)
        default: event(["error": "输入 quiet、idle、lanoff 或 quit"])
        }
    }
}

@main struct AndroidBLEPeripheralProbe {
    @MainActor static func main() throws {
        let probe = PeripheralProbe()
        try probe.start()
        DispatchQueue.global().async {
            while let line = readLine() { Task { @MainActor in probe.command(line) } }
        }
        RunLoop.main.run()
    }
}
