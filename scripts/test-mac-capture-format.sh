#!/bin/sh
# Captures the selected physical microphone without changing the system input or writing to the driver.
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "用法：$0 <物理麦克风 UID> [第二物理麦克风 UID]" >&2
    exit 2
fi
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/stubs.swift" <<'SWIFT'
import CoreAudio
import Foundation

enum MicrophoneProtocol { static func failure(_ message: String) -> NSError { NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
enum MicrophoneGain { static func apply(_ samples: [Float], gain: Float) -> [Float] { samples } }
struct RemoteMicrophoneSource { let peerID: String; let sourceID: String }
final class RemoteMicrophoneCapture {
    var error: String? { nil }
    init(source: RemoteMicrophoneSource, receive: @escaping (Data) throws -> Void) {
        preconditionFailure("本机采集回归不应启动远端输入")
    }
    func stop() {}
}

struct DedicatedMicrophone: Equatable {
    let bundle: String
    let name: String
    let uid: String
    let selector: String
    let outputSampleRate: Int
    let outputChannels: Int
    var inputGain: Float { 1 }
    var deviceName: String { name }
}
enum DedicatedInputPolicy {
    static func mutedPIDs(_ inputs: [pid_t: Set<AudioObjectID>], mutedDevices: Set<AudioObjectID>) -> Set<pid_t> {
        []
    }
}
final class AudioForensics {
    static let shared = AudioForensics()
    private let lock = NSLock()
    private var frames = [String: Int64]()
    func event(_ selector: String, _ event: String, _ values: [String: Any] = [:]) {}
    func recordSource(_ selector: String, sampleRate: Int, channels: Int, hostTime: UInt64,
                      sampleTime: Int64, samples: [Float]) {
        lock.lock()
        frames[selector, default: 0] += Int64(samples.count / channels)
        lock.unlock()
    }
    func frameCount(_ selector: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return frames[selector, default: 0]
    }
}
SWIFT
cat "$repo/Mac/VirtualMicrophone.swift" > "$work/main.swift"
cat >> "$work/main.swift" <<'SWIFT'

extension VirtualMicrophone {
    static func verifyQueueBudget() {
        let capture = VirtualMicrophone(sampleRate: 48000, channels: 1)
        capture.pendingFrameLimit = 14400
        capture.destinationSelectors = [0: "queue-budget"]
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        buffer.floatChannelData![0].initialize(repeating: 0, count: 512)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        capture.queue.async { entered.signal(); release.wait() }
        entered.wait()
        // A blocked driver must not shrink the old 300 ms tolerance to three 512-frame callbacks.
        for _ in 0..<28 {
            capture.forward(buffer, when: AVAudioTime(hostTime: mach_absolute_time()),
                            converter: nil, target: format)
        }
        precondition(capture.diagnostics().busyDroppedFrames == 0, "小回调不能缩短既有缓冲时间窗")
        capture.forward(buffer, when: AVAudioTime(hostTime: mach_absolute_time()),
                        converter: nil, target: format)
        precondition(capture.diagnostics().busyDroppedFrames == 512, "缓冲达到时间上限后必须丢弃而非无限增长")
        release.signal()
        capture.queue.sync {}
        precondition(AudioForensics.shared.frameCount("queue-budget") == 28 * 512,
                     "恢复后的队列必须转发所有预算内音频")
        precondition(OSAtomicAdd64Barrier(0, capture.counters.advanced(by: Counter.queued)) == 0,
                     "转发或丢弃音频后必须归还全部预算")
        // An unusable PCM result must return its nonzero reservation as well.
        let integerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000,
                                          channels: 1, interleaved: false)!
        let unusable = AVAudioPCMBuffer(pcmFormat: integerFormat, frameCapacity: 512)!
        unusable.frameLength = 512
        capture.forward(unusable, when: AVAudioTime(hostTime: mach_absolute_time()),
                        converter: nil, target: format)
        precondition(capture.diagnostics().conversionDroppedFrames == 512)
        precondition(OSAtomicAdd64Barrier(0, capture.counters.advanced(by: Counter.queued)) == 0,
                     "转换失败必须归还源帧预算")
    }

    static func verifyCaptureFormat(uids: [String]) throws {
        let primary = uids[0]
        let captures = [VirtualMicrophone(sourceUID: primary, sampleRate: 48000, channels: 1),
                        VirtualMicrophone(sourceUID: primary, sampleRate: 44100, channels: 2)] +
            uids.dropFirst().map { VirtualMicrophone(sourceUID: $0, sampleRate: 48000, channels: 1) }
        defer { for capture in captures { capture.suspend() } }
        for (index, capture) in captures.enumerated() {
            capture.destinationSelectors = [0: "test-\(index)"]
            do {
                try capture.start(device: AudioObjectID.max)
                fatalError("无效设备不得启动成功")
            } catch {
                precondition(capture.inputUnit == nil && capture.inputBuffer == nil &&
                    capture.converter == nil && capture.targetFormat == nil && capture.pendingFrameLimit == 0,
                    "启动失败后必须释放捕获资源与预算")
            }
        }
        // Fail after format, callback, and buffer setup, then reuse that same instance below.
        let failedCapture = captures[0]
        failedCapture.destinations = [AudioObjectID.max]
        do {
            try failedCapture.start(device: deviceID(uid: primary)!)
            fatalError("无效目的设备不得启动成功")
        } catch {
            precondition(failedCapture.inputUnit == nil && failedCapture.inputBuffer == nil &&
                failedCapture.converter == nil && failedCapture.targetFormat == nil && failedCapture.pendingFrameLimit == 0,
                "初始化后的启动失败必须释放全部捕获资源")
        }
        failedCapture.destinations = []
        for round in 1...2 {
            for capture in captures {
                guard let device = deviceID(uid: capture.sourceUID!) else {
                    fatalError("物理麦克风不存在：\(capture.sourceUID!)")
                }
                precondition(!capture.isNearbyDevice(device), "测试必须使用物理麦克风")
                try capture.start(device: device)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            for second in 1...5 {
                let before = captures.map { $0.diagnostics().tappedFrames }
                let forwarded = captures.indices.map { AudioForensics.shared.frameCount("test-\($0)") }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                for (index, capture) in captures.enumerated() {
                    let diagnostics = capture.diagnostics()
                    precondition(capture.isCapturing, "采集意外停止")
                    var actualDevice = AudioObjectID(kAudioObjectUnknown)
                    var size = UInt32(MemoryLayout<AudioObjectID>.size)
                    let status = AudioUnitGetProperty(capture.inputUnit!, kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global, 0, &actualDevice, &size)
                    precondition(status == noErr && actualDevice == capture.sourceDeviceID,
                                 "捕获必须保持绑定所选物理麦克风")
                    let incoming = diagnostics.tappedFrames - before[index]
                    let outgoing = AudioForensics.shared.frameCount("test-\(index)") - forwarded[index]
                    let sourceRate = diagnostics.sourceSampleRate!
                    precondition(Double(incoming) > sourceRate * 0.8 && Double(incoming) < sourceRate * 1.2,
                                 "物理采集必须逐秒持续供音")
                    precondition(Double(outgoing) > Double(capture.outputSampleRate) * 0.8 &&
                                 Double(outgoing) < Double(capture.outputSampleRate) * 1.2,
                                 "转换后的输出必须逐秒持续供音")
                    precondition(diagnostics.pushFailedFrames == 0 && diagnostics.conversionDroppedFrames == 0,
                                 "采集与转换不能丢失音频")
                    print("第 \(round) 轮第 \(second) 秒，源 \(actualDevice)：\(sourceRate) Hz 收到 \(incoming) 帧 → \(capture.outputSampleRate) Hz 输出 \(outgoing) 帧")
                }
            }
            for capture in captures {
                capture.suspend()
                precondition(capture.inputUnit == nil && capture.inputBuffer == nil && capture.pendingFrameLimit == 0,
                             "停止后必须释放捕获资源与预算")
                precondition(OSAtomicAdd64Barrier(0, capture.counters.advanced(by: Counter.queued)) == 0,
                             "停止后必须排空队列并归还全部预算")
            }
        }
    }
}
VirtualMicrophone.verifyQueueBudget()
try VirtualMicrophone.verifyCaptureFormat(uids: Array(CommandLine.arguments.dropFirst()))
SWIFT
xcrun swiftc "$work/stubs.swift" "$work/main.swift" -o "$work/capture-format"
"$work/capture-format" "$@"
