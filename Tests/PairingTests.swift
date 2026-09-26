import Foundation
import NearbyAudioCore
import XCTest

final class PairingTests: XCTestCase {
    func testBothUsersMustConfirmSameShortCodeBeforeControlKeyExists() throws {
        let mac = try PairingInitiator(macName: "My Mac")
        let pad = try PairingResponder(start: mac.startFrame, padName: "My iPad")
        for name in [String(repeating: "测", count: 32), String(repeating: "\\", count: 32)] {
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(PairingInitiator(macName: name).startFrame).count, 182)
        }
        let nonceA = try mac.receiveOffer(pad.offerFrame)
        let nonceB = try pad.receiveNonceA(nonceA)
        try mac.receiveNonceB(nonceB)
        XCTAssertEqual(mac.shortCode, pad.shortCode)
        XCTAssertEqual(mac.shortCode?.count, 6)
        XCTAssertNil(pad.confirmedKey)

        let macProof = try mac.confirm()
        XCTAssertNil(try pad.receiveConfirm(macProof))
        XCTAssertNil(pad.confirmedKey)
        let finish = try XCTUnwrap(pad.confirmLocal())
        let macKey = try mac.receiveFinish(finish)
        XCTAssertEqual(macKey, pad.confirmedKey)
        XCTAssertEqual(macKey.count, 32)
    }

    func testTamperReplayAndFalseConfirmationFail() throws {
        let mac = try PairingInitiator(macName: "Mac")
        let pad = try PairingResponder(start: mac.startFrame, padName: "iPad")
        let anotherMac = try PairingInitiator(macName: "Mac")
        XCTAssertThrowsError(try anotherMac.receiveOffer(pad.offerFrame)) {
            XCTAssertEqual($0 as? PairingError, .wrongSession)
        }
        let forgedOffer = PairingFrame(kind: .offer, session: pad.session,
                                       publicKey: pad.offerFrame.publicKey,
                                       commitment: Data(repeating: 0, count: 32), name: pad.offerFrame.name)
        let nonceA = try mac.receiveOffer(forgedOffer)
        let nonceB = try pad.receiveNonceA(nonceA)
        XCTAssertThrowsError(try mac.receiveNonceB(nonceB)) {
            XCTAssertEqual($0 as? PairingError, .wrongCommitment)
        }

        let honestMac = try PairingInitiator(macName: "Mac")
        let honestPad = try PairingResponder(start: honestMac.startFrame, padName: "iPad")
        try honestMac.receiveNonceB(honestPad.receiveNonceA(honestMac.receiveOffer(honestPad.offerFrame)))
        let forgedProof = PairingFrame(kind: .confirm, session: honestPad.session,
                                       proof: Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try honestPad.receiveConfirm(forgedProof)) {
            XCTAssertEqual($0 as? PairingError, .wrongProof)
        }
        XCTAssertNil(honestPad.confirmedKey)
    }

    func testExpiredOrUnconfirmedSessionCannotFinish() throws {
        let start = Date(timeIntervalSince1970: 100)
        let mac = try PairingInitiator(macName: "Mac", now: start)
        let pad = try PairingResponder(start: mac.startFrame, padName: "iPad", now: start)
        XCTAssertThrowsError(try mac.receiveOffer(pad.offerFrame, now: start.addingTimeInterval(91))) {
            XCTAssertEqual($0 as? PairingError, .expired)
        }
        XCTAssertNil(pad.confirmedKey)

        let freshMac = try PairingInitiator(macName: "Mac")
        let freshPad = try PairingResponder(start: freshMac.startFrame, padName: "iPad")
        try freshMac.receiveNonceB(freshPad.receiveNonceA(freshMac.receiveOffer(freshPad.offerFrame)))
        XCTAssertNil(try freshPad.confirmLocal())
        XCTAssertNil(freshPad.confirmedKey)
        let prematureFinish = PairingFrame(kind: .finish, session: freshMac.session,
                                           proof: Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try freshMac.receiveFinish(prematureFinish)) {
            XCTAssertEqual($0 as? PairingError, .wrongStep)
        }
    }
}
