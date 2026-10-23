import Foundation
@testable import ShenglinCore
import XCTest

final class MicrophoneSamplesTests: XCTestCase {
    func testPacketBoundariesPreserveSamples() throws {
        let samples = MicrophoneSamples()
        let first = Data(repeating: 7, count: 960 * 4)
        let second = Data(repeating: 9, count: 960 * 4)
        samples.append(first.prefix(100))
        samples.append(first.dropFirst(100) + second)
        XCTAssertEqual(try samples.next(), first)
        XCTAssertEqual(try samples.next(), second)
    }

    func testSlowReceiverCannotAccumulateUnboundedAudio() {
        let samples = MicrophoneSamples()
        samples.append(Data(count: 960 * 4 * 10))
        samples.append(Data([0]))
        XCTAssertThrowsError(try samples.next())
    }

    func testRevocationDiscardsBufferedAudioAndWakesReader() {
        let samples = MicrophoneSamples()
        samples.append(Data(count: 100))
        let stopped = expectation(description: "blocked reader released")
        DispatchQueue.global().async {
            do { _ = try samples.next(); XCTFail("closed reader returned audio") } catch { }
            stopped.fulfill()
        }
        samples.close()
        samples.append(Data(count: 960 * 4))
        wait(for: [stopped], timeout: 0.5)
        XCTAssertThrowsError(try samples.next())
    }
}
