import Foundation
import NearbyAudioCore
import XCTest

final class ProtocolTests: XCTestCase {
    func testBLEServiceAndCharacteristicIDsStayCompatible() {
        XCTAssertEqual([
            BLEIdentifiers.service, BLEIdentifiers.command, BLEIdentifiers.ack,
            BLEIdentifiers.pairingService, BLEIdentifiers.pairingWrite,
            BLEIdentifiers.pairingResponse, BLEIdentifiers.pairingInfo,
        ], [
            "8A27D37F-A94F-4A53-AD7C-0D48CC8108CF",
            "E1FA496A-299F-4C84-9621-63396F75A3F2",
            "0F20B426-BBC9-48A4-A518-82827239AA9E",
            "C985D59E-9D34-4F37-8F14-03C942690C78",
            "01FA287F-9E5C-4A8A-8B58-23A9808981F4",
            "D56446C2-AB92-43C6-B80F-BE5E964015B4",
            "BF903515-CC03-4056-A7D0-16E3267ABEB4",
        ])
    }

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

    func testSelectedInputSourcesAcrossConcurrentProcessesAndRestart() {
        let koe = "bundle:nz.owo.koe"
        let chat = "bundle:com.example.chat"
        let active: [Int32: Set<String>] = [
            14259: [koe, "path:/Applications/Koe.app/Contents/MacOS/Koe"],
            53878: [chat],
        ]
        XCTAssertEqual(InputSelectionPolicy.activePIDs(active, selected: [koe]), [14259])
        XCTAssertEqual(InputSelectionPolicy.activePIDs(active, selected: [chat]), [53878])
        XCTAssertEqual(InputSelectionPolicy.activePIDs(active, selected: [koe, chat]), [14259, 53878])
        XCTAssertTrue(InputSelectionPolicy.activePIDs(active, selected: []).isEmpty)
        XCTAssertEqual(InputSelectionPolicy.activePIDs([245: [koe]], selected: [koe]), [245])
        XCTAssertEqual(InputSelectionPolicy.activePIDs([246: [koe, "bundle:koe.helper"]], selected: [koe]), [246])
    }
}
