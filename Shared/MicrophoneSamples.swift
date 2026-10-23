import Foundation

/// The tap never waits for the network; a receiver that falls behind must reconnect.
final class MicrophoneSamples {
    private let condition = NSCondition()
    private var bytes = Data()
    private var failure: Error?
    func append(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        guard failure == nil else { return }
        if bytes.count + data.count > 960 * 4 * 10 { failure = MicrophoneProtocol.failure("接收设备未及时读取音频") }
        else { bytes.append(data) }
        condition.signal()
    }
    func close(_ error: Error = MicrophoneProtocol.failure("麦克风采集已停止")) {
        condition.lock(); failure = error; bytes.removeAll(); condition.broadcast(); condition.unlock()
    }
    func next() throws -> Data {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while bytes.count < 960 * 4 && failure == nil {
            if !condition.wait(until: deadline) { failure = MicrophoneProtocol.failure("麦克风没有返回音频") }
        }
        if let failure { throw failure }
        let result = Data(bytes.prefix(960 * 4)); bytes.removeFirst(960 * 4)
        return result
    }
}
