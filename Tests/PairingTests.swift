import Foundation
import ShenglinCore
import XCTest

final class PairingTests: XCTestCase {
    func testPeerRecordKeepsIdentityAndRoleIndependentOfPlatform() throws {
        let key = Data(repeating: 7, count: 32)
        let initiator = try PairedPeer(key: key, name: "  测试 iPad  ", platform: .ipad,
                                       localRole: .initiator)
        let restored = try JSONDecoder().decode(PairedPeer.self, from: JSONEncoder().encode(initiator))
        XCTAssertEqual(restored.name, "测试 iPad")
        XCTAssertEqual(restored.localRole.remote, .responder)
        XCTAssertEqual(restored.platform, .ipad)
        XCTAssertEqual(restored.key, key)
        XCTAssertEqual(try PairedPeer(key: key, name: " ", platform: .mac,
                                      localRole: .responder).name, "Mac")
        XCTAssertThrowsError(try PairedPeer(key: Data(), name: "Mac", platform: .mac,
                                            localRole: .responder))
        let claim = PeerNameClaim(name: "测试 iPad", key: key)
        XCTAssertTrue(claim.valid(key: key))
        XCTAssertFalse(claim.valid(key: Data(repeating: 8, count: 32)))
        let modified = try JSONDecoder().decode(PeerNameClaim.self,
            from: Data("{\"name\":\"other ipad\",\"signature\":\"\(claim.signature)\"}".utf8))
        XCTAssertFalse(modified.valid(key: key))
    }

    func testMicrophoneGrantDefaultsToDeniedAndSurvivesRoundTrip() throws {
        let oldRecord = Data(#"{"key":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=","name":"iPad","platform":"ipad","localRole":"responder"}"#.utf8)
        var peer = try JSONDecoder().decode(PairedPeer.self, from: oldRecord)
        XCTAssertNil(peer.microphoneShared)
        peer.microphoneShared = true
        let restored = try JSONDecoder().decode(PairedPeer.self, from: JSONEncoder().encode(peer))
        XCTAssertEqual(restored.microphoneShared, true)
        XCTAssertEqual(restored.key, peer.key)
    }

    func testOneTimeCodeAuthenticatesBothSidesBeforeKeyIsUsable() throws {
        let mac = try PairingInitiator(code: "004219", initiatorName: "My Mac")
        let pad = try PairingResponder(start: mac.startFrame, code: "004219", responderName: "My iPad")
        XCTAssertNil(pad.confirmedKey)
        let proof = try mac.receiveOffer(pad.offerFrame)
        XCTAssertEqual(mac.peerName, "My iPad")
        XCTAssertEqual(mac.startFrame.name, "My Mac")
        XCTAssertNil(pad.confirmedKey)
        let finish = try pad.receiveConfirm(proof)
        XCTAssertEqual(try mac.receiveFinish(finish), pad.confirmedKey)
        XCTAssertEqual(pad.confirmedKey?.count, 32)
    }

    func testWrongCodeAndModifiedTranscriptNeverConfirmKey() throws {
        let mac = try PairingInitiator(code: "123456", initiatorName: "Mac")
        let pad = try PairingResponder(start: mac.startFrame, code: "654321", responderName: "iPad")
        XCTAssertThrowsError(try pad.receiveConfirm(mac.receiveOffer(pad.offerFrame))) {
            XCTAssertEqual($0 as? PairingError, .wrongCode)
        }
        XCTAssertNil(pad.confirmedKey)

        let honestMac = try PairingInitiator(code: "123456", initiatorName: "Mac")
        let honestPad = try PairingResponder(start: honestMac.startFrame, code: "123456", responderName: "iPad")
        let changedOffer = PairingFrame(kind: .offer, session: honestPad.session,
                                        message: honestPad.offerFrame.message, name: "Other iPad")
        XCTAssertThrowsError(try honestPad.receiveConfirm(honestMac.receiveOffer(changedOffer))) {
            XCTAssertEqual($0 as? PairingError, .wrongCode)
        }
        XCTAssertNil(honestPad.confirmedKey)
    }

    func testSessionReplayAndExpiryAreRejected() throws {
        let start = Date(timeIntervalSince1970: 100)
        let mac = try PairingInitiator(code: "000000", initiatorName: "Mac", now: start)
        let pad = try PairingResponder(start: mac.startFrame, code: "000000", responderName: "iPad", now: start)
        let anotherMac = try PairingInitiator(code: "000000", initiatorName: "Mac", now: start)
        XCTAssertThrowsError(try anotherMac.receiveOffer(pad.offerFrame, now: start)) {
            XCTAssertEqual($0 as? PairingError, .wrongSession)
        }
        XCTAssertThrowsError(try mac.receiveOffer(pad.offerFrame, now: start.addingTimeInterval(91))) {
            XCTAssertEqual($0 as? PairingError, .expired)
        }
        XCTAssertNil(pad.confirmedKey)
        XCTAssertThrowsError(try PairingInitiator(code: "12x456", initiatorName: "Mac")) {
            XCTAssertEqual($0 as? PairingError, .wrongCode)
        }
    }

    func testDirectMacHandshakeUsesSeparatePairKeys() throws {
        func pair(_ initiatorName: String) throws -> Data {
            let initiator = try PairingInitiator(code: "384620", initiatorName: initiatorName)
            let responder = try PairingResponder(start: initiator.startFrame, code: "384620",
                                                 responderName: "Desk Mac")
            let confirmation = try initiator.receiveOffer(responder.offerFrame)
            let finish = try responder.receiveConfirm(confirmation)
            let key = try initiator.receiveFinish(finish)
            XCTAssertEqual(key, responder.confirmedKey)
            return key
        }
        XCTAssertNotEqual(try pair("Travel Mac A"), try pair("Travel Mac B"))
    }

    func testPairingNamesNeverBecomeBlank() throws {
        XCTAssertEqual(PeerName.display(nil, fallback: "iPad"), "iPad")
        XCTAssertEqual(PeerName.display("  ", fallback: "Mac"), "Mac")
        let mac = try PairingInitiator(code: "123456", initiatorName: "  ")
        XCTAssertEqual(mac.startFrame.name, "Mac")
        let pad = try PairingResponder(start: mac.startFrame, code: "123456", responderName: " \n ")
        XCTAssertEqual(pad.offerFrame.name, "iPad")
        XCTAssertThrowsError(try PairingResponder(
            start: PairingFrame(kind: .start, session: mac.session,
                                message: mac.startFrame.message, name: "  "),
            code: "123456", responderName: "iPad"))
        XCTAssertThrowsError(try mac.receiveOffer(PairingFrame(
            kind: .offer, session: mac.session,
            message: pad.offerFrame.message, name: "")))
    }
    func testV4AuthenticatesEveryPlatformInEitherRole() throws {
        for local in [PeerPlatform.mac, .ipad, .android, .windows] {
            for remote in [PeerPlatform.mac, .ipad, .android, .windows] {
                let initiator = try PairingInitiator(code: "123456", initiatorName: "First", platform: local)
                let responder = try PairingResponder(start: initiator.startFrame, code: "123456",
                                                      responderName: "Second", platform: remote)
                XCTAssertEqual(initiator.startFrame.version, 4)
                let confirm = try initiator.receiveOffer(responder.offerFrame)
                let finish = try responder.receiveConfirm(confirm)
                XCTAssertEqual(try initiator.receiveFinish(finish), responder.confirmedKey)
                XCTAssertEqual(initiator.peerPlatform, remote)
                XCTAssertEqual(responder.peerPlatform, local)
            }
        }
    }

    func testV4PlatformTamperingAndDowngradeAreRejected() throws {
        let initiator = try PairingInitiator(code: "123456", initiatorName: "First", platform: .android)
        let responder = try PairingResponder(start: initiator.startFrame, code: "123456",
                                              responderName: "Second", platform: .ipad)
        let offer = responder.offerFrame
        let changed = PairingFrame(kind: .offer, session: offer.session, message: offer.message,
                                   name: offer.name, platform: .mac, version: 4)
        XCTAssertThrowsError(try responder.receiveConfirm(initiator.receiveOffer(changed)))
        XCTAssertNil(responder.confirmedKey)
        let legacy = try PairingInitiator(code: "123456", initiatorName: "Old")
        XCTAssertThrowsError(try PairingResponder(start: legacy.startFrame, code: "123456",
                                                 responderName: "New", platform: .android))
        XCTAssertThrowsError(try PairingResponder(start: initiator.startFrame, code: "123456",
                                                 responderName: "Old"))
    }

    func testLegacyPeerRecordsKeepTheirTransportAndNewRecordsKeepPlatforms() throws {
        let legacy = try PairedPeer(key: Data(repeating: 1, count: 32), name: "Old", platform: .ipad,
                                    localRole: .initiator)
        let oldJSON = try JSONEncoder().encode(legacy)
        XCTAssertNil(try JSONDecoder().decode(PairedPeer.self, from: oldJSON).transport)
        let direct = try PairedPeer(key: Data(repeating: 2, count: 32), name: "", platform: .android,
                                    localRole: .responder, transport: .wifiDirect)
        let restored = try JSONDecoder().decode(PairedPeer.self, from: JSONEncoder().encode(direct))
        XCTAssertEqual(restored.transport, .wifiDirect)
        XCTAssertEqual(restored.platform, .android)
        XCTAssertEqual(restored.name, "Android")
    }

    func testBLELongWritesPreserveOneBoundedFrame() throws {
        let value = Data((0..<256).map(UInt8.init))
        XCTAssertEqual(BLEAttributeWrite.assemble([(0, value.prefix(20)), (20, value.dropFirst(20))]), value)
        XCTAssertNil(BLEAttributeWrite.assemble([]))
        XCTAssertNil(BLEAttributeWrite.assemble([(1, value)]))
        XCTAssertNil(BLEAttributeWrite.assemble([(0, value), (255, value)]))
        XCTAssertNil(BLEAttributeWrite.assemble([(0, value), (257, value)]))
        XCTAssertNotNil(BLEAttributeWrite.assemble([(0, value), (256, value)]))
        XCTAssertNil(BLEAttributeWrite.assemble([(0, value), (256, value + Data([1]))]))
    }

}
