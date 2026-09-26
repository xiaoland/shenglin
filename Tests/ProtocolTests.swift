import Foundation
import NearbyAudioCore
import XCTest

final class ProtocolTests: XCTestCase {
    func testAuthenticatedCommandsAndRestoration() throws {
        let key = Data(repeating: 7, count: 32)
        let command = ControlCommand(sequence: 4, quiet: true, expiresAt: 110, key: key)
        XCTAssertTrue(command.valid(key: key, now: 100))
        XCTAssertFalse(command.valid(key: key, now: 110))
        XCTAssertFalse(command.valid(key: Data(repeating: 8, count: 32), now: 100))
        let targetCommand = ControlCommand(sequence: 5, quiet: true, expiresAt: 110, targetMilli: 150, key: key)
        XCTAssertTrue(targetCommand.valid(key: key, now: 100))
        XCTAssertFalse(ControlCommand(sequence: 5, quiet: true, expiresAt: 110, targetMilli: 501, key: key).valid(key: key, now: 100))
        var forgedCommand = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(targetCommand)) as? [String: Any])
        forgedCommand["targetMilli"] = 200
        XCTAssertFalse(try JSONDecoder().decode(ControlCommand.self, from: JSONSerialization.data(withJSONObject: forgedCommand)).valid(key: key, now: 100))
        let ack = ControlAck(sequence: 4, quiet: true, result: "applied", volumeMilli: 100, targetMilli: 150, key: key)
        XCTAssertTrue(ack.valid(key: key))
        XCTAssertFalse(ack.valid(key: Data(repeating: 8, count: 32)))
        var forgedAck = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ack)) as? [String: Any])
        forgedAck["targetMilli"] = 200
        XCTAssertFalse(try JSONDecoder().decode(ControlAck.self, from: JSONSerialization.data(withJSONObject: forgedAck)).valid(key: key))

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
}
