#!/usr/bin/env python3
"""Exercise the shipping discovery filter and rejected-candidate recovery without Bluetooth."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root/'Mac/BLEClient.swift').read_text()
def section(a,b): return s[s.index(a):s.index(b)]
scan = section('    private func scanForPeer()', '    func centralManager(_ manager: CBCentralManager, didDiscover')
discover = section('    func centralManager(_ manager: CBCentralManager, didDiscover', '    func centralManager(_ manager: CBCentralManager, didConnect')
reject = section('    private func scanAfterRejecting', '    func peripheral(_ found: CBPeripheral, didDiscoverServices')
source = '''import Foundation
class CBPeripheral { let identifier = UUID() }
class CBCentralManager {
 var connections = [UUID](); var scans = 0
 var systemConnected = [CBPeripheral]()
 func retrieveConnectedPeripherals(withServices: [String]) -> [CBPeripheral] { systemConnected }
 func stopScan() {}
 func connect(_ p: CBPeripheral) { connections.append(p.identifier) }
 func cancelPeripheralConnection(_ p: CBPeripheral) {}
 func scanForPeripherals(withServices: [String]) { scans += 1 }
}
enum Status { case message(String) }
final class Probe {
 let serviceID = "service"
 var stopped = false, authenticated = false, rediscoverPeripheral = false
 var attempt = 0
 var excluded = Set<UUID>()
 func otherAuthenticatedPeripherals() -> Set<UUID> { excluded }
 var targetPeripheralID: UUID?
 var peripheral: CBPeripheral?
 var skippedPeripherals = [UUID: Date]()
 var loggedDiscoveries = Set<UUID>()
 let central = CBCentralManager()
 func report(_ s: String) {}
 func onStatus(_ s: Status) {}
'''+scan+discover+reject+'''
 func reject(_ p: CBPeripheral) { scanAfterRejecting(p) }
 func scan() { scanForPeer() }
}
let old = CBPeripheral(), rotated = CBPeripheral()
let p = Probe(); p.targetPeripheralID = old.identifier; p.rediscoverPeripheral = false
p.centralManager(p.central, didDiscover: rotated, advertisementData: [:], rssi: 0)
assert(p.central.connections.isEmpty) // Legacy fixed IDs remain strict.
p.rediscoverPeripheral = true
p.centralManager(p.central, didDiscover: rotated, advertisementData: [:], rssi: 0)
assert(p.central.connections == [rotated.identifier])
assert(!p.authenticated) // A physical connection is never evidence of the key.
p.reject(rotated)
assert(p.peripheral == nil && p.skippedPeripherals[rotated.identifier]! > Date())
p.centralManager(p.central, didDiscover: rotated, advertisementData: [:], rssi: 0)
assert(p.central.connections.count == 1) // Bad candidates cannot monopolize retries.
p.authenticated = true; p.peripheral = old; p.reject(old)
assert(!p.authenticated && p.skippedPeripherals[old.identifier] == nil)
let excluded = Probe(); excluded.rediscoverPeripheral = true; excluded.excluded = [old.identifier]
excluded.centralManager(excluded.central, didDiscover: old, advertisementData: [:], rssi: 0)
assert(excluded.central.connections.isEmpty)
let restored = Probe(); restored.rediscoverPeripheral = true; restored.targetPeripheralID = old.identifier
restored.central.systemConnected = [rotated, old]; restored.scan()
assert(restored.central.connections == [old.identifier])
assert(!restored.authenticated)
restored.reject(old)
assert(restored.central.connections == [old.identifier, rotated.identifier])
assert(!restored.authenticated)
let legacy = Probe(); legacy.targetPeripheralID = old.identifier
legacy.centralManager(legacy.central, didDiscover: rotated, advertisementData: [:], rssi: 0)
assert(legacy.central.connections.isEmpty)
print("BLE rediscovery boundaries passed")
'''
with tempfile.TemporaryDirectory() as td:
 p=Path(td); (p/'main.swift').write_text(source)
 subprocess.run(['swiftc', str(p/'main.swift'), '-o', str(p/'test')], check=True)
 subprocess.run([str(p/'test')], check=True)
