#!/usr/bin/env python3
"""Exercise the real iPad removal handler with an isolated failing/successful Keychain boundary."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
server = (root / 'iPad/BLEServer.swift').read_text()
handler = server[server.index('    func removePeer('):server.index('    func restoreNow()')]
source = r'''import Foundation
struct Peer { let key: Data }
struct Proof { let key: Data }
final class Link { var stopped = false; func stop() { stopped = true } }
enum PairingStore {
 static var failure = false
 static var remaining: [Peer] = []
 static func removePeer(_ key: Data) throws -> [Peer] {
  if failure { throw NSError(domain: "Keychain", code: -1) }
  return remaining
 }
}
final class Probe {
 var pairedPeers: [Peer] = []
 var pairedKeys: [Data] = []
 var pairedCount = 0
 var isPaired = true
 var wifiPeers: [String: Link] = [:]
 var wifiVerifiedSources: Set<String> = []
 var wifiEvidenceSources: Set<String> = []
 var wifiIssues: [String: String] = [:]
 var wifiVerified = true
 var bleProofs: [UUID: Proof] = [:]
 var readSnapshots: [UUID: Data] = [:]
 var lastAckByCentral: [UUID: Data] = [:]
 var spaceGates: [String: Bool] = [:]
 var peerRemovalError: String?
 var refreshed = 0
 var persisted = 0
 func sourceID(for key: Data) -> String { key.base64EncodedString() }
 func refreshSpace() { refreshed += 1 }
 func persistPeerLedger() { persisted += 1 }
'''+handler+r'''
}
let android = Peer(key: Data([1])), mac = Peer(key: Data([2]))
let a = android.key.base64EncodedString(), m = mac.key.base64EncodedString()
let aCentral = UUID(), mCentral = UUID()
let aLink = Link(), mLink = Link()
let probe = Probe()
probe.pairedPeers = [android, mac]; probe.pairedKeys = [android.key, mac.key]; probe.pairedCount = 2
probe.wifiPeers = [a:aLink, m:mLink]
probe.wifiVerifiedSources = [a,m]; probe.wifiEvidenceSources = [a,m]
probe.bleProofs = [aCentral:Proof(key: android.key), mCentral:Proof(key:mac.key)]
probe.readSnapshots = [aCentral:Data([1]),mCentral:Data([2])]
probe.lastAckByCentral = probe.readSnapshots
probe.spaceGates = [a:true,m:true]
PairingStore.failure = true
probe.removePeer(a)
assert(probe.pairedCount == 2 && probe.pairedKeys == [android.key,mac.key])
assert(!aLink.stopped && !mLink.stopped && probe.refreshed == 0 && probe.persisted == 0)
assert(probe.bleProofs.count == 2 && probe.peerRemovalError != nil)
PairingStore.failure = false; PairingStore.remaining = [mac]
probe.removePeer(a)
assert(probe.pairedCount == 1 && probe.pairedKeys == [mac.key] && probe.isPaired)
assert(aLink.stopped && !mLink.stopped && probe.wifiPeers[m] === mLink)
assert(probe.wifiVerifiedSources == [m] && probe.wifiEvidenceSources == [m])
assert(probe.bleProofs[aCentral] == nil && probe.bleProofs[mCentral]?.key == mac.key)
assert(probe.readSnapshots[aCentral] == nil && probe.readSnapshots[mCentral] != nil)
assert(probe.lastAckByCentral[aCentral] == nil && probe.spaceGates[a] == nil && probe.spaceGates[m] == true)
assert(probe.refreshed == 1 && probe.persisted == 1 && probe.peerRemovalError == nil)
print("iPad 单设备取消配对：存储失败保留关系，成功仅撤销指定设备，其他配对和链路保留。")
'''
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp)
    (path / 'main.swift').write_text(source)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
