#!/usr/bin/env python3
"""Compile unchanged shipping state methods with a fake media-volume boundary, without private API calls."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
volume = (root / 'iPad/Volume.swift').read_text()
server = (root / 'iPad/BLEServer.swift').read_text()
# Only replace platform I/O and persistence, as in the existing Mac presentation check.
volume_methods = volume[volume.index('    private func save()'):volume.rindex('\n}')].replace('UserDefaults.standard', 'preferences')
server_methods = server[server.index('    private func coordinateOutput('):server.index('    private func receivePeerUpdate(')].replace('UserDefaults.standard', 'preferences')
source = r'''import Foundation
@MainActor final class VolumeCoordinator {
 let preferences = UserDefaults(suiteName: "shenglin-output-boundary-test-\(UUID())")!
 let stateKey = "snapshot"
 var value: Float = 0.6
 var readFails = false
 var writeFails = false
 var routeID = "speaker"
 var writes = 0
 private var snapshot: QuietSnapshot?
 private var restoreTimer: Timer?
 private var restoreStepCount = 0
 private var restoreStart: Float = 0
 private var roundBaseline: QuietSnapshot?
 var hasSnapshot: Bool { snapshot != nil }
 var isRestoring: Bool { restoreTimer != nil }
 var original: Float? { snapshot?.original }
 func current() -> Float? { readFails ? nil : value }
 private func route() -> String { routeID }
 private func write(_ value: Float) -> Bool {
   if writeFails { return false }
   self.value = value; writes += 1; return true
 }
 func finishRamp() { for _ in 0..<8 where restoreTimer != nil { restoreStep() } }
'''+volume_methods+r'''
}
@MainActor final class Receiver {
 let preferences = UserDefaults(suiteName: "shenglin-receiver-boundary-test-\(UUID())")!
 var volume: VolumeCoordinator? = VolumeCoordinator()
 var enabled = true
 var peerLedger = PeerDemandLedger()
 var outputDemandActive = false
 var outputPausedForInput = false
 var recording: Bool? = false
 var lastAction = ""
 let key = Data(repeating: 7, count: 32)
 let deviceName = "iPad"
 init() { preferences.set(0.2, forKey: "targetVolume") }
 func sampleRecording() -> Bool? { recording }
 func persistPeerLedger() {}
 func request(revision: UInt64, at now: Int64) {
   let update = PeerQuietUpdate(origin: "mac", revision: revision, quiet: true,
                               validUntil: now + 20, key: key)
   _ = peerLedger.accept(update, from: "source", expectedOrigin: "mac", key: key, at: now)
 }
 func end(at now: Int64) -> String {
   let change = peerLedger.stopResponding(at: now)
   return coordinateOutput(at: now, manualAtEnd: change.manualAtEnd).0
 }
 func tick(_ now: Int64) -> String { observeManualTakeover(at: now); return coordinateOutput(at: now).0 }
 func direct(_ now: Int64) -> String { coordinateOutput(at: now).0 }
'''+server_methods+r'''
}
@main struct Check {
 @MainActor static func main() {
   let a = Receiver(), va = a.volume!
   a.request(revision: 1, at: 100)
   assert(a.tick(100) == "applied" && abs(va.value - 0.2) < 0.001)
   a.recording = true; va.writeFails = true
   assert(a.tick(101) == "restoreFailed")
   assert(va.original == 0.6 && !a.peerLedger.manualTakeover)
   va.writeFails = false
   assert(a.tick(102) == "protectedLocal" && va.value == 0.6)
   va.value = 0.7; assert(a.tick(103) == "alreadyRestored")
   a.recording = false; _ = a.tick(104)
   assert(a.peerLedger.manualTakeover && va.value == 0.7)
   _ = a.end(at: 105); assert(va.value == 0.7)

   let b = Receiver(), vb = b.volume!
   b.request(revision: 1, at: 100); _ = b.tick(100)
   assert(b.end(at: 101) == "restoring")
   vb.value = 0.5
   // processPeerUpdate checks manual before accepting, when no request is yet active.
   b.request(revision: 2, at: 102)
   assert(b.direct(102) == "preservedManualOrRoute")
   assert(b.peerLedger.manualTakeover && vb.value == 0.5)
   _ = b.tick(103); assert(vb.value == 0.5)

   let c = Receiver(), vc = c.volume!
   vc.value = 0.1; c.request(revision: 1, at: 100)
   assert(c.tick(100) == "alreadyBelowTarget" && vc.writes == 0)
   vc.value = 0.5; _ = c.tick(101)
   assert(c.peerLedger.manualTakeover && vc.value == 0.5 && vc.writes == 0)

   let d = Receiver(), vd = d.volume!
   d.request(revision: 1, at: 100); _ = d.tick(100)
   d.recording = nil; assert(d.tick(101) == "unknown" && vd.value == 0.6)
   d.recording = false; assert(d.tick(102) == "applied" && vd.original == 0.6)
   vd.readFails = true; assert(d.end(at: 103) == "readFailed" && vd.hasSnapshot)
   vd.readFails = false; assert(d.tick(104) == "restoring")
   vd.finishRamp(); assert(abs(vd.value - 0.6) < 0.001 && !vd.hasSnapshot)
   print("通过：iPad 暂停恢复失败重试、暂停期间手调、恢复中手调、新请求、低于目标基线、未知状态及到期恢复。")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='shenglin-ipad-output-') as directory:
    target = Path(directory)
    swift = target / 'Check.swift'
    swift.write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', str(root / 'Shared/Protocol.swift'),
                    str(root / 'Shared/PeerState.swift'), str(swift), '-o', str(target / 'check')], check=True)
    subprocess.run([str(target / 'check')], check=True)
