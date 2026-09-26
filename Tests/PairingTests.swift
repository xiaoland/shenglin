import Foundation
import NearbyAudioCore
import XCTest

final class PairingTests: XCTestCase {
    func testOneTimeCodeAuthenticatesBothSidesBeforeKeyIsUsable() throws {
        let mac = try PairingInitiator(code: "004219", macName: "My Mac")
        let pad = try PairingResponder(start: mac.startFrame, code: "004219", padName: "My iPad")
        XCTAssertNil(pad.confirmedKey)
        let proof = try mac.receiveOffer(pad.offerFrame)
        XCTAssertNil(pad.confirmedKey)
        let finish = try pad.receiveConfirm(proof)
        XCTAssertEqual(try mac.receiveFinish(finish), pad.confirmedKey)
        XCTAssertEqual(pad.confirmedKey?.count, 32)
    }

    func testWrongCodeAndModifiedTranscriptNeverConfirmKey() throws {
        let mac = try PairingInitiator(code: "123456", macName: "Mac")
        let pad = try PairingResponder(start: mac.startFrame, code: "654321", padName: "iPad")
        XCTAssertThrowsError(try pad.receiveConfirm(mac.receiveOffer(pad.offerFrame))) {
            XCTAssertEqual($0 as? PairingError, .wrongCode)
        }
        XCTAssertNil(pad.confirmedKey)

        let honestMac = try PairingInitiator(code: "123456", macName: "Mac")
        let honestPad = try PairingResponder(start: honestMac.startFrame, code: "123456", padName: "iPad")
        let changedOffer = PairingFrame(kind: .offer, session: honestPad.session,
                                        message: honestPad.offerFrame.message, name: "Other iPad")
        XCTAssertThrowsError(try honestPad.receiveConfirm(honestMac.receiveOffer(changedOffer))) {
            XCTAssertEqual($0 as? PairingError, .wrongCode)
        }
        XCTAssertNil(honestPad.confirmedKey)
    }

    func testSessionReplayAndExpiryAreRejected() throws {
        let start = Date(timeIntervalSince1970: 100)
        let mac = try PairingInitiator(code: "000000", macName: "Mac", now: start)
        let pad = try PairingResponder(start: mac.startFrame, code: "000000", padName: "iPad", now: start)
        let anotherMac = try PairingInitiator(code: "000000", macName: "Mac", now: start)
        XCTAssertThrowsError(try anotherMac.receiveOffer(pad.offerFrame, now: start)) {
            XCTAssertEqual($0 as? PairingError, .wrongSession)
        }
        XCTAssertThrowsError(try mac.receiveOffer(pad.offerFrame, now: start.addingTimeInterval(91))) {
            XCTAssertEqual($0 as? PairingError, .expired)
        }
        XCTAssertNil(pad.confirmedKey)
        XCTAssertThrowsError(try PairingInitiator(code: "12x456", macName: "Mac")) {
            XCTAssertEqual($0 as? PairingError, .wrongCode)
        }
    }

    func testDirectMacHandshakeUsesSeparatePairKeys() throws {
        func pair(_ initiatorName: String) throws -> Data {
            let initiator = try PairingInitiator(code: "384620", macName: initiatorName)
            let responder = try PairingResponder(start: initiator.startFrame, code: "384620",
                                                 padName: "Desk Mac")
            let confirmation = try initiator.receiveOffer(responder.offerFrame)
            let finish = try responder.receiveConfirm(confirmation)
            let key = try initiator.receiveFinish(finish)
            XCTAssertEqual(key, responder.confirmedKey)
            return key
        }
        XCTAssertNotEqual(try pair("Travel Mac A"), try pair("Travel Mac B"))
    }
}
