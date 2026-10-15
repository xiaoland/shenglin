#!/usr/bin/env python3
"""使用实际 iPad GATT 回调与内存边界检查长读快照和原子长写，不启动蓝牙。"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
server = (root / 'iPad/BLEServer.swift').read_text()
protocol = (root / 'Shared/Protocol.swift').read_text()
callbacks = server[server.index('    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead'):server.index('    private func persistPeerLedger()')]
assembler = protocol[protocol.index('public enum BLEAttributeWrite'):protocol.index('public enum Authentication')]
source = r'''import Foundation
typealias CBUUID = String
enum ATTResult { case success, readNotPermitted, invalidOffset, invalidAttributeValueLength, unlikelyError }
struct Central { let identifier: UUID }
struct Characteristic { let uuid: String }
final class CBATTRequest {
 let central: Central
 let characteristic: Characteristic
 let offset: Int
 var value: Data?
 init(_ central: UUID, _ characteristic: String, _ offset: Int = 0, _ value: Data? = nil) {
  self.central = Central(identifier: central); self.characteristic = Characteristic(uuid: characteristic)
  self.offset = offset; self.value = value
 }
}
final class CBPeripheralManager {
 var results = [ATTResult]()
 func respond(to request: CBATTRequest, withResult result: ATTResult) { results.append(result) }
}
struct PairingFrame: Codable {
 enum Kind: String, Codable { case info }
 let kind: Kind; let session: Data; let name: String; let pairingMode: Bool
}
struct PeerQuietUpdate: Codable { let revision: Int }
final class Server {
 static let stateAckID = "ack", peerStateID = "state", pairInfoID = "info", pairResponseID = "pairResponse"
 static let pairWriteID = "pairWrite", peerAckWriteID = "peerAck", stateWriteID = "stateWrite"
 struct Proof { let key: Data }
 var bleProofs = [UUID: Proof]()
 var lastAckByCentral = [UUID: Data]()
 var readSnapshots = [UUID: [CBUUID: Data]]()
 var deviceName = "iPad"
 var pairingMode = false
 var pairingDeadline: Date?
 var pairResponseData: Data?
 var generated = 0
 var writes = [Data]()
 func expirePeerRequests() {}
 func currentLocalState(key: Data) -> Data? { generated += 1; return Data("signed-state-\(generated)".utf8) }
 func receivePairWrite(_ request: CBATTRequest, peripheral: CBPeripheralManager) { writes.append(request.value!); peripheral.respond(to: request, withResult: .success) }
 func receivePeerAck(_ request: CBATTRequest, peripheral: CBPeripheralManager) { writes.append(request.value!); peripheral.respond(to: request, withResult: .success) }
 func receivePeerUpdate(_ update: PeerQuietUpdate, request: CBATTRequest, peripheral: CBPeripheralManager) { writes.append(request.value!); peripheral.respond(to: request, withResult: .success) }
''' + callbacks + r'''}
let server = Server(), manager = CBPeripheralManager(), first = UUID(), second = UUID()
server.bleProofs[first] = .init(key: Data([1])); server.bleProofs[second] = .init(key: Data([2]))
let initial = CBATTRequest(first, Server.peerStateID)
server.peripheralManager(manager, didReceiveRead: initial)
let fragment = CBATTRequest(first, Server.peerStateID, 5)
server.peripheralManager(manager, didReceiveRead: fragment)
assert(server.generated == 1 && fragment.value == initial.value!.dropFirst(5))
server.peripheralManager(manager, didReceiveRead: CBATTRequest(second, Server.peerStateID))
assert(server.generated == 2)
server.peripheralManager(manager, didReceiveRead: fragment)
assert(fragment.value == initial.value!.dropFirst(5))
server.peripheralManager(manager, didReceiveRead: CBATTRequest(first, Server.peerStateID))
assert(server.generated == 3)
server.peripheralManager(manager, didReceiveRead: CBATTRequest(first, Server.peerStateID, 999))
assert(manager.results.last == .invalidOffset)
let value = Data("{\"revision\":42}".utf8)
let start = CBATTRequest(first, Server.stateWriteID, 0, value.prefix(7))
let end = CBATTRequest(first, Server.stateWriteID, 7, value.dropFirst(7))
let responses = manager.results.count
server.peripheralManager(manager, didReceiveWrite: [start, end])
assert(server.writes == [value] && manager.results.count == responses + 1 && manager.results.last == .success)
server.peripheralManager(manager, didReceiveWrite: [CBATTRequest(first, Server.stateWriteID, 0, value.prefix(7)), CBATTRequest(first, Server.stateWriteID, 8, value.dropFirst(7))])
assert(server.writes.count == 1 && manager.results.last == .invalidAttributeValueLength)
server.peripheralManager(manager, didReceiveWrite: [CBATTRequest(first, Server.stateWriteID, 0, value), CBATTRequest(second, Server.stateWriteID, value.count, value)])
assert(server.writes.count == 1 && manager.results.last == .invalidAttributeValueLength)
print("iPad GATT 长读快照隔离、连续长写、一次响应及无效批次不生效检查通过。")
'''
with tempfile.TemporaryDirectory(prefix='shenglin-ipad-ble-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(assembler + source)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
