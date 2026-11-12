#!/usr/bin/env python3
"""Compile and exercise the production pending-Mac-peer expiration method."""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "MacGUI/AppModel.swift").read_text()
KEYCHAIN = (ROOT / "Mac/Keychain.swift").read_text()
START = "    private func expirePendingMacPeers() {"
END = "\n    private func refreshMacPeerSpaces()"
if START not in MODEL or END not in MODEL:
    raise SystemExit("Could not locate production expirePendingMacPeers() boundaries")
handler = MODEL.split(START, 1)[1].split(END, 1)[0]
handler = START + handler
handler = handler.replace(
    "Date().timeIntervalSince(lastPendingMacCheck)",
    "now.timeIntervalSince(lastPendingMacCheck)",
)
handler = handler.replace("lastPendingMacCheck = Date()", "lastPendingMacCheck = now")
handler = handler.replace("private func expirePendingMacPeers()", "func expirePendingMacPeers()")

# Pairing writes originate at both pairing completion callbacks. Each successful
# write must immediately reload the staged list into pendingMacIDs.
stage_calls = list(re.finditer(r"try MacCredentials\.stageMacPeer\(peer\)", MODEL))
if len(stage_calls) != 2:
    raise SystemExit(f"Expected two production stageMacPeer call sites, found {len(stage_calls)}")
for match in stage_calls:
    following = MODEL[match.end() : match.end() + 100]
    if not re.search(r"startMacPeers\(\)", following):
        raise SystemExit("A stageMacPeer call does not reload pendingMacIDs")

if "static func stageMacPeer(_ peer: PairedPeer)" not in KEYCHAIN:
    raise SystemExit("Could not find production Keychain staging boundary")

swift = r'''import Foundation

struct Peer { let key: Data }
final class Link {
    private(set) var stopped = false
    func stop() { stopped = true }
}
enum MacCredentials {
    static var pending: [Peer] = []
    static var saved: [Peer] = []
    static var failPending = false
    static var failSaved = false
    static var pendingReads = 0
    static var savedReads = 0
    static func reset(pending: [Peer] = [], saved: [Peer] = []) {
        self.pending = pending; self.saved = saved
        failPending = false; failSaved = false
        pendingReads = 0; savedReads = 0
    }
    static func pendingMacPeers() throws -> [Peer] {
        pendingReads += 1
        if failPending { throw NSError(domain: "fake-keychain", code: 1) }
        return pending
    }
    static func peers() throws -> [Peer] {
        savedReads += 1
        if failSaved { throw NSError(domain: "fake-keychain", code: 2) }
        return saved
    }
}
final class Probe {
    var pendingMacIDs = Set<String>()
    var lastPendingMacCheck = Date.distantPast
    var now = Date(timeIntervalSince1970: 1_000)
    var savedMacPeers = [Peer]()
    var macWifiPeers = [String: Link]()
    var directBLEPeers = [String: Link]()
    var directBLEVerified = Set<String>()
    var macPeerVerified = Set<String>()
    var macPeerWiFiEvidence = Set<String>()
    var macPeerGates = [String: Int]()
    var macPeerAllowed = Set<String>()
    var macPeerCount = 0
    var directMacCount = 0
    var errorMessage: String?
    var refreshCount = 0
    func sourceID(for key: Data) -> String { key.base64EncodedString() }
    func refreshMacPeerSpaces() { refreshCount += 1 }
''' + handler + r'''
}

var failures = [String]()
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { failures.append(label); print("FAIL: \(label)") }
    else { print("PASS: \(label)") }
}
func peer(_ byte: UInt8) -> Peer { Peer(key: Data([byte])) }

// An empty in-memory set must not touch Keychain, even if a fake external
// record exists; the periodic method is only a reaper for known staged IDs.
do {
    let p = Probe(), external = peer(1)
    p.now = Date(timeIntervalSince1970: 1_100)
    p.lastPendingMacCheck = Date(timeIntervalSince1970: 1_000)
    MacCredentials.reset(pending: [external])
    p.expirePendingMacPeers()
    check(MacCredentials.pendingReads == 0 && MacCredentials.savedReads == 0,
          "empty pendingMacIDs skips Keychain reads")
}

// Known staged peers are checked on the existing five-second cadence.
do {
    let p = Probe(), active = peer(2), id = p.sourceID(for: active.key)
    p.pendingMacIDs = [id]
    p.lastPendingMacCheck = Date(timeIntervalSince1970: 1_000)
    p.now = Date(timeIntervalSince1970: 1_004.9)
    MacCredentials.reset(pending: [active])
    p.expirePendingMacPeers()
    check(MacCredentials.pendingReads == 0, "active staged peer is not checked before 5 seconds")
    p.now = Date(timeIntervalSince1970: 1_005)
    p.expirePendingMacPeers()
    check(MacCredentials.pendingReads == 1 && p.pendingMacIDs == [id],
          "active staged peer is checked at 5 seconds and retained")
    p.now = Date(timeIntervalSince1970: 1_009.9)
    p.expirePendingMacPeers()
    check(MacCredentials.pendingReads == 1, "next active check also respects 5 seconds")
    p.now = Date(timeIntervalSince1970: 1_010.01)
    p.expirePendingMacPeers()
    check(MacCredentials.pendingReads == 2, "active staged peer is checked again at 10 seconds")
}

// A staged peer absent from both Keychain records is expired and all live
// transport/authentication/gating state must be discarded while an active peer stays.
do {
    let p = Probe(), expired = peer(3), active = peer(4)
    let oldID = p.sourceID(for: expired.key), activeID = p.sourceID(for: active.key)
    p.pendingMacIDs = [oldID, activeID]
    p.savedMacPeers = [expired, active]
    let oldWiFi = Link(), activeWiFi = Link(), oldBLE = Link(), activeBLE = Link()
    p.macWifiPeers = [oldID: oldWiFi, activeID: activeWiFi]
    p.directBLEPeers = [oldID: oldBLE, activeID: activeBLE]
    p.directBLEVerified = [oldID, activeID]
    p.macPeerVerified = [oldID, activeID]
    p.macPeerWiFiEvidence = [oldID, activeID]
    p.macPeerGates = [oldID: 1, activeID: 2]
    p.macPeerAllowed = [oldID, activeID]
    p.now = Date(timeIntervalSince1970: 1_100)
    MacCredentials.reset(pending: [active])
    p.expirePendingMacPeers()
    check(oldWiFi.stopped && oldBLE.stopped, "expired peer transports are stopped")
    check(p.macWifiPeers[oldID] == nil && p.directBLEPeers[oldID] == nil,
          "expired peer transports are removed")
    check(!p.directBLEVerified.contains(oldID) && !p.macPeerVerified.contains(oldID) &&
          !p.macPeerWiFiEvidence.contains(oldID) && p.macPeerGates[oldID] == nil &&
          !p.macPeerAllowed.contains(oldID), "expired peer verification and space state are removed")
    check(!p.savedMacPeers.contains(where: { p.sourceID(for: $0.key) == oldID }) &&
          p.savedMacPeers.contains(where: { p.sourceID(for: $0.key) == activeID }),
          "only expired unsaved peer leaves the visible peer list")
    check(p.pendingMacIDs == [activeID] && p.directMacCount == 1 && p.refreshCount == 1,
          "active peer remains and display state is refreshed")
}

// Keychain may promote the peer before the next expiration tick. A saved peer
// must be retained even if its pending record has disappeared.
do {
    let p = Probe(), promoted = peer(5), id = p.sourceID(for: promoted.key)
    p.pendingMacIDs = [id]
    p.savedMacPeers = [promoted]
    let wifi = Link(), ble = Link()
    p.macWifiPeers[id] = wifi; p.directBLEPeers[id] = ble
    p.directBLEVerified = [id]; p.macPeerVerified = [id]
    p.macPeerWiFiEvidence = [id]; p.macPeerGates[id] = 3; p.macPeerAllowed = [id]
    p.now = Date(timeIntervalSince1970: 1_100)
    MacCredentials.reset(saved: [promoted])
    p.expirePendingMacPeers()
    check(p.pendingMacIDs.isEmpty && p.savedMacPeers.count == 1,
          "successfully paired peer is removed from pending but retained as saved")
    check(!wifi.stopped && !ble.stopped && p.macWifiPeers[id] != nil &&
          p.directBLEPeers[id] != nil && p.macPeerAllowed.contains(id),
          "successfully paired peer transport and authorization are preserved")
    check(p.macPeerCount == 1, "successfully paired peer is counted as saved")
}

if !failures.isEmpty { exit(1) }
print("All pending Mac peer expiration contracts passed")
'''

with tempfile.TemporaryDirectory(prefix="mac-pending-peers-") as temp:
    harness = Path(temp) / "main.swift"
    binary = Path(temp) / "pending-peer-contracts"
    harness.write_text(swift)
    subprocess.run(["swiftc", str(harness), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
