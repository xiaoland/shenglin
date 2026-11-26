#!/usr/bin/env python3
"""Run Mac promotion, recovery and revocation against an in-memory Keychain with failed writes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
store = (root / "Mac/Keychain.swift").read_text()
types = (root / "Shared/PairingProtocol.swift").read_text()
peer_types = types[types.index("public enum PeerName {"):types.index("public struct PeerNameClaim:")]
# Replace only the Security adapter, exercising the production account names and record encodings.
start = store.index("    private static func query(")
end = store.index("    private static func storedPendingPairing(", start)
store = store[:start] + """
    static var values = [String: Data]()
    static var failedWrite: String?
    static func read(_ account: String) throws -> Data? { values[account] }
    static func save(_ data: Data, account: String) throws {
        if account == failedWrite { throw TestError.write }
        values[account] = data
    }
    static func delete(_ account: String) throws {
        if account == failedWrite { throw TestError.write }
        values[account] = nil
    }
""" + store[end:]

probe = r'''
enum PairingError: Error { case invalidMessage, expired }
enum TestError: Error { case write }
func check(_ result: Bool, _ message: String) { precondition(result, message) }
func expectWriteFailure(_ operation: () throws -> Void) throws {
    do { try operation(); preconditionFailure("storage failure must propagate before commit") }
    catch TestError.write {}
}
let wifi = try PairedPeer(key: Data(repeating: 1, count: 32), name: "Wi-Fi", platform: .android,
                          localRole: .initiator, transport: .wifiDirect)
let other = try PairedPeer(key: Data(repeating: 2, count: 32), name: "Other", platform: .windows,
                           localRole: .responder, transport: .wifiDirect)
let legacy = Data(repeating: 3, count: 32)
let peripheral = UUID()
_ = try MacCredentials.stagePairing(legacy, name: "iPad", peripheralID: peripheral)
try MacCredentials.stageMacPeer(wifi)
try MacCredentials.stageMacPeer(other)
MacCredentials.failedWrite = "pairedPeersV3"
try expectWriteFailure { try MacCredentials.promoteMacPeer(wifi.key) }
try check(MacCredentials.peers().isEmpty, "failed commit must not create a saved peer")
try check(MacCredentials.pendingMacPeers().count == 2, "failed commit must be retryable")
MacCredentials.failedWrite = "pendingMacPeersV3"
try MacCredentials.promoteMacPeer(wifi.key)
try check(MacCredentials.pendingMacPeers().map(\.key) == [other.key], "stale cleanup cannot hide other peers")
try MacCredentials.updatePeerName(wifi.key, name: "Renamed")
try MacCredentials.promoteMacPeer(wifi.key)
try check(MacCredentials.peers().first?.name == "Renamed", "duplicate promotion must keep saved metadata")
try expectWriteFailure { try MacCredentials.removePeer(wifi.key) }
try check(MacCredentials.peers().map(\.key) == [wifi.key], "failed revocation must preserve the saved key")
MacCredentials.failedWrite = nil
try MacCredentials.removePeer(wifi.key)
try check(MacCredentials.peers().isEmpty && MacCredentials.pendingMacPeers().map(\.key) == [other.key],
          "revocation must not revive the target or clear another Wi-Fi pairing")
try check(MacCredentials.pendingPairing(excluding: MacCredentials.peers())?.key == legacy,
          "removing a Wi-Fi peer must preserve another iPad pairing")
MacCredentials.failedWrite = "pendingPeerV3"
try MacCredentials.promotePairing(legacy, name: "iPad", peripheralID: peripheral)
try check(MacCredentials.peers().map(\.key) == [legacy], "iPad promotion commits before cleanup")
try check(MacCredentials.pendingPairing(excluding: MacCredentials.peers()) == nil,
          "startup must not restore a promoted iPad as pending")
try expectWriteFailure { try MacCredentials.removePeer(legacy) }
try check(MacCredentials.peers().map(\.key) == [legacy], "failed iPad cleanup must preserve the saved key")
MacCredentials.failedWrite = nil
try MacCredentials.removePeer(legacy)
try check(MacCredentials.pendingPairing(excluding: MacCredentials.peers()) == nil &&
          MacCredentials.pendingMacPeers().map(\.key) == [other.key], "iPad revocation must survive reload")
print("Mac 配对存储通过：提交、清理失败、重试、恢复和单设备撤销。")
'''

with tempfile.TemporaryDirectory(prefix="shenglin-mac-pairing-") as temporary:
    path = Path(temporary)
    source = path / "main.swift"
    source.write_text(store + peer_types + probe)
    executable = path / "check"
    subprocess.run(["swiftc", "-j1", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
