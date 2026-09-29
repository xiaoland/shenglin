import Foundation
import ShenglinCore
import XCTest

final class ProtocolTests: XCTestCase {
    func testLocalAndRemoteQuietDemandKeepsTheLowerOutputTarget() {
        XCTAssertNil(VolumePolicy.quietTarget(local: nil, remote: nil))
        XCTAssertEqual(VolumePolicy.quietTarget(local: 0.25, remote: nil), 0.25)
        XCTAssertEqual(VolumePolicy.quietTarget(local: nil, remote: 0.4), 0.4)
        XCTAssertEqual(VolumePolicy.quietTarget(local: 0.25, remote: 0.1), 0.1)
    }

    func testPeerResultsNeverExposeWireCodes() {
        XCTAssertEqual(PeerResult.message("restoring", device: "测试 iPad"),
                       "测试 iPad 音量正在恢复")
        XCTAssertEqual(PeerResult.message("outsideSpace", device: "测试 iPad"),
                       "测试 iPad 未满足空间条件")
        XCTAssertEqual(PeerResult.message("unexpectedCode", device: "测试 iPad"),
                       "测试 iPad 响应异常")
    }

    func testSpaceModesRequireVerifiedTransportEvidence() {
        XCTAssertFalse(SpaceMode.nearbyOrWiFi.allows(ble: false, wifi: false))
        XCTAssertTrue(SpaceMode.nearbyOrWiFi.allows(ble: true, wifi: false))
        XCTAssertTrue(SpaceMode.nearbyOrWiFi.allows(ble: false, wifi: true))
        XCTAssertFalse(SpaceMode.nearbyAndWiFi.allows(ble: true, wifi: false))
        XCTAssertFalse(SpaceMode.nearbyAndWiFi.allows(ble: false, wifi: true))
        XCTAssertTrue(SpaceMode.nearbyAndWiFi.allows(ble: true, wifi: true))
        var gate = SpaceGate()
        XCTAssertFalse(gate.allows(.nearbyAndWiFi, ble: true, wifi: false, at: 100))
        XCTAssertTrue(gate.allows(.nearbyAndWiFi, ble: true, wifi: true, at: 101))
        XCTAssertTrue(gate.allows(.nearbyAndWiFi, ble: true, wifi: false, at: 120))
        XCTAssertFalse(gate.allows(.nearbyAndWiFi, ble: true, wifi: false, at: 121))
        XCTAssertTrue(gate.allows(.nearbyOrWiFi, ble: true, wifi: false, at: 122))
        gate.reset()
        XCTAssertFalse(gate.allows(.nearbyAndWiFi, ble: true, wifi: false, at: 122))
    }

    func testWiFiProofBindsPairingKeyRoleAndFreshChallenge() {
        let key = Data(repeating: 3, count: 32)
        let nonce = Data(repeating: 4, count: 16).base64EncodedString()
        let proof = WiFiProof.sign(role: "ipad", nonce: nonce, key: key)
        XCTAssertTrue(WiFiProof.valid(proof, role: "ipad", nonce: nonce, key: key))
        XCTAssertFalse(WiFiProof.valid(proof, role: "mac", nonce: nonce, key: key))
        XCTAssertFalse(WiFiProof.valid(proof, role: "ipad", nonce: Data(repeating: 5, count: 16).base64EncodedString(), key: key))
        XCTAssertFalse(WiFiProof.valid(proof, role: "ipad", nonce: nonce, key: Data(repeating: 6, count: 32)))
    }

    func testDirectMacPeersKeepKeysAcksAndDemandIndependent() {
        let keyA = Data(repeating: 21, count: 32)
        let keyB = Data(repeating: 22, count: 32)
        let nonce = Data(repeating: 23, count: 16).base64EncodedString()
        let proofA = WiFiProof.sign(role: PeerRole.initiator.rawValue, nonce: nonce, key: keyA)
        XCTAssertTrue(WiFiProof.valid(proofA, role: PeerRole.initiator.rawValue, nonce: nonce, key: keyA))
        XCTAssertFalse(WiFiProof.valid(proofA, role: PeerRole.initiator.rawValue, nonce: nonce, key: keyB))
        XCTAssertFalse(WiFiProof.valid(proofA, role: PeerRole.responder.rawValue, nonce: nonce, key: keyA))

        let a = PeerQuietUpdate(origin: PeerRole.initiator.rawValue, revision: 1, quiet: true,
                                validUntil: 120, key: keyA)
        let b = PeerQuietUpdate(origin: PeerRole.responder.rawValue, revision: 1, quiet: true,
                                validUntil: 120, key: keyB)
        var ledger = PeerDemandLedger()
        XCTAssertTrue(ledger.accept(a, from: "mac-a", expectedOrigin: PeerRole.initiator.rawValue,
                                    key: keyA, at: 100).started)
        XCTAssertEqual(ledger.accept(b, from: "mac-b", expectedOrigin: PeerRole.responder.rawValue,
                                     key: keyB, at: 100).activeCount, 2)
        XCTAssertFalse(ledger.stopResponding(to: "mac-a", at: 101).ended)
        XCTAssertEqual(ledger.activeCount(at: 101), 1)
        let ack = PeerStateAck(origin: PeerRole.responder.rawValue, revision: 1, quiet: true,
                               result: "alreadyQuiet", key: keyA)
        XCTAssertTrue(ack.valid(key: keyA, expectedOrigin: PeerRole.responder.rawValue))
        XCTAssertFalse(ack.valid(key: keyB, expectedOrigin: PeerRole.responder.rawValue))
        XCTAssertTrue(ledger.stopResponding(to: "mac-b", at: 102).ended)
    }

    func testPeerRequestsRemainIndependentAcrossRetriesExpiryAndManualTakeover() throws {
        let key = Data(repeating: 9, count: 32)
        func update(_ revision: UInt64, _ quiet: Bool, _ until: Int64) -> PeerQuietUpdate {
            PeerQuietUpdate(origin: PeerRole.responder.rawValue, revision: revision, quiet: quiet, validUntil: until, key: key)
        }
        var ledger = PeerDemandLedger()
        XCTAssertTrue(ledger.accept(update(1, true, 120), from: "a", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 100).started)
        let replay = ledger.accept(update(1, true, 120), from: "a", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 101)
        XCTAssertEqual(replay.activeCount, 1)
        XCTAssertFalse(replay.accepted)
        XCTAssertEqual(ledger.accept(update(1, true, 125), from: "b", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 105).activeCount, 2)
        XCTAssertEqual(ledger.accept(update(2, false, 120), from: "a", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 106).activeCount, 1)
        XCTAssertFalse(ledger.expire(at: 124).ended)
        XCTAssertTrue(ledger.expire(at: 125).ended)

        XCTAssertTrue(ledger.accept(update(3, true, 145), from: "a", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 130).started)
        ledger.takeOver(at: 130)
        XCTAssertFalse(ledger.accept(update(2, true, 145), from: "b", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 131).started)
        XCTAssertFalse(ledger.accept(update(4, false, 145), from: "a", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 132).ended)
        let ended = ledger.accept(update(3, false, 145), from: "b", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 133)
        XCTAssertTrue(ended.ended && ended.manualAtEnd)
        XCTAssertFalse(ledger.manualTakeover)

        let restored = try JSONDecoder().decode(PeerDemandLedger.self, from: JSONEncoder().encode(ledger))
        var next = restored
        XCTAssertFalse(next.accept(update(2, true, 145), from: "a", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 134).started)
        XCTAssertFalse(next.accept(update(5, true, 145), from: "a", expectedOrigin: PeerRole.initiator.rawValue, key: key, at: 134).started)
        XCTAssertFalse(next.accept(update(5, true, 145), from: "a", expectedOrigin: PeerRole.responder.rawValue, key: Data(repeating: 8, count: 32), at: 134).started)
        XCTAssertTrue(next.accept(update(5, true, 145), from: "a", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 134).started)
        let renewalAfterTimerDelay = next.accept(update(6, true, 160), from: "a", expectedOrigin: PeerRole.responder.rawValue, key: key, at: 146)
        XCTAssertTrue(renewalAfterTimerDelay.accepted)
        XCTAssertFalse(renewalAfterTimerDelay.started || renewalAfterTimerDelay.ended)
        XCTAssertEqual(renewalAfterTimerDelay.activeCount, 1)
        XCTAssertTrue(next.expire(at: 160).ended)
        let ack = PeerStateAck(origin: PeerRole.initiator.rawValue, revision: 5, quiet: true, result: "applied", key: key)
        XCTAssertTrue(ack.valid(key: key, expectedOrigin: PeerRole.initiator.rawValue))
        XCTAssertFalse(ack.valid(key: key, expectedOrigin: PeerRole.responder.rawValue))

        var threeSources = PeerDemandLedger()
        for source in ["mac-a", "mac-b", "ipad-c"] {
            _ = threeSources.accept(update(10, true, 155), from: source,
                                    expectedOrigin: PeerRole.responder.rawValue, key: key, at: 140)
        }
        XCTAssertEqual(threeSources.activeCount(at: 140), 3)
        XCTAssertFalse(threeSources.stopResponding(to: "mac-a", at: 141).ended)
        XCTAssertEqual(threeSources.activeCount(at: 141), 2)
        for source in ["mac-b"] {
            XCTAssertFalse(threeSources.accept(update(11, false, 155), from: source,
                                               expectedOrigin: PeerRole.responder.rawValue, key: key, at: 141).ended)
        }
        XCTAssertEqual(threeSources.activeCount(at: 141), 1)
        XCTAssertTrue(threeSources.accept(update(11, false, 155), from: "ipad-c",
                                          expectedOrigin: PeerRole.responder.rawValue, key: key, at: 141).ended)
    }

    func testVolumeRestoration() {
        XCTAssertEqual(VolumePolicy.target(current: 0.5, configured: 0.1), 0.1)
        XCTAssertNil(VolumePolicy.target(current: 0.05, configured: 0.1))
        let saved = QuietSnapshot(original: 0.5, applied: 0.1, route: "speaker")
        XCTAssertEqual(VolumePolicy.restore(current: 0.1, route: "speaker", snapshot: saved), 0.5)
        XCTAssertNil(VolumePolicy.restore(current: 0.3, route: "speaker", snapshot: saved))
        XCTAssertNil(VolumePolicy.restore(current: 0.1, route: "headphones", snapshot: saved))
    }

    func testExcludedInputSourcesAcrossConcurrentProcessesAndRestart() {
        let koe = "bundle:nz.owo.koe"
        let chat = "bundle:com.example.chat"
        let active: [Int32: Set<String>] = [
            14259: [koe, "path:/Applications/Koe.app/Contents/MacOS/Koe"],
            53878: [chat],
        ]
        XCTAssertEqual(InputExclusionPolicy.activePIDs(active, excluded: []), [14259, 53878])
        XCTAssertEqual(InputExclusionPolicy.activePIDs(active, excluded: [koe]), [53878])
        XCTAssertEqual(InputExclusionPolicy.activePIDs(active, excluded: [chat]), [14259])
        XCTAssertTrue(InputExclusionPolicy.activePIDs(active, excluded: [koe, chat]).isEmpty)
        XCTAssertTrue(InputExclusionPolicy.activePIDs([246: [koe, "bundle:koe.helper"]], excluded: [koe]).isEmpty)
    }

    func testLegacySelectionDoesNotBecomeAnExclusion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("selection.json")
        let exclusions = directory.appendingPathComponent("exclusions.json")
        try Data(#"{"selected":["bundle:nz.owo.koe"]}"#.utf8).write(to: legacy)
        XCTAssertEqual(try InputExclusionStore.load(at: exclusions, legacyURL: legacy), [])
        try InputExclusionStore.change("bundle:com.openai.codex", add: true, at: exclusions, legacyURL: legacy)
        XCTAssertEqual(try InputExclusionStore.load(at: exclusions, legacyURL: legacy), ["bundle:com.openai.codex"])
        try InputExclusionStore.change("bundle:com.openai.codex", add: false, at: exclusions, legacyURL: legacy)
        XCTAssertEqual(try InputExclusionStore.load(at: exclusions, legacyURL: legacy), [])
    }

    func testDedicatedMicrophonesStayStableAndOnlySuppressFullyMutedInputs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("microphones.json")
        let a = DedicatedMicrophone(bundle: "test.a", name: "A")
        let b = DedicatedMicrophone(bundle: "test.b", name: "B")
        XCTAssertEqual(try DedicatedMicrophoneStore.load(at: url), [])
        try DedicatedMicrophoneStore.save([b, a], at: url)
        XCTAssertEqual(try DedicatedMicrophoneStore.load(at: url), [a, b])
        XCTAssertEqual(a.uid, DedicatedMicrophone(bundle: "test.a", name: "Renamed").uid)
        XCTAssertEqual(a.outputSampleRate, 48000)
        XCTAssertEqual(a.outputChannels, 2)
        let selected = DedicatedMicrophone(bundle: "test.a", name: "A", sourceUID: "usb.audio.1",
            sampleRate: 44100, channels: 1)
        try DedicatedMicrophoneStore.save([selected, b], at: url)
        XCTAssertEqual(try DedicatedMicrophoneStore.load(at: url), [selected, b])
        XCTAssertEqual(selected.uid, a.uid)
        XCTAssertThrowsError(try DedicatedMicrophoneStore.save([
            .init(bundle: "test.a", name: "A", sourceUID: "usb.audio.1", sampleRate: 44100, channels: 3)
        ], at: url))
        try DedicatedMicrophoneStore.save([a, b], at: url)
        XCTAssertThrowsError(try DedicatedMicrophoneStore.save([a, a], at: url))
        XCTAssertThrowsError(try DedicatedMicrophoneStore.save([.init(bundle: "bad/id", name: "Bad")], at: url))
        XCTAssertEqual(try DedicatedMicrophoneStore.load(at: url), [a, b])
        try DedicatedMicrophoneStore.save([b], at: url)
        XCTAssertEqual(try DedicatedMicrophoneStore.load(at: url), [b])
        XCTAssertEqual(DedicatedInputPolicy.mutedPIDs([1: [10], 2: [20], 3: [10, 20], 4: []], mutedDevices: [10]), [1])
        XCTAssertEqual(DedicatedInputPolicy.mutedPIDs([1: [10], 2: [20], 3: [10, 20]], mutedDevices: [10, 20]), [1, 2, 3])
    }

    func testMuteChoicesPersistIndependentlyOfExclusions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let muted = directory.appendingPathComponent("muted.json")
        XCTAssertEqual(try InputMuteStore.load(at: muted), [])
        try InputMuteStore.change("bundle:nz.owo.koe", add: true, at: muted)
        try InputMuteStore.change("bundle:com.openai.codex", add: true, at: muted)
        XCTAssertEqual(try InputMuteStore.load(at: muted),
                       ["bundle:nz.owo.koe", "bundle:com.openai.codex"])
        try InputMuteStore.change("bundle:nz.owo.koe", add: false, at: muted)
        XCTAssertEqual(try InputMuteStore.load(at: muted), ["bundle:com.openai.codex"])
    }
}
