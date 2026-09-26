import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

final class VirtualMicrophone {
    static let uid = "local.nearbyaudio.virtual-microphone"
    private static let audioPush: AudioObjectPropertySelector = 0x4e414d50 // NAMP
    private static let clientMute: AudioObjectPropertySelector = 0x4e414d4d // NAMM

    let deviceID: AudioObjectID
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "NearbyAudio.VirtualMicrophone")
    private let pending = DispatchSemaphore(value: 1)
    private let statusLock = NSLock()
    private var pushFailure: OSStatus?
    private var running = false
    private var sourceDeviceID: AudioObjectID?
    private var forwardedMutes = Set<pid_t>()

    init?() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = Self.uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        deviceID = device
    }

    func update(activeClients: Set<pid_t>, mutedClients: Set<pid_t>) throws {
        statusLock.lock()
        let failure = pushFailure
        statusLock.unlock()
        if let failure {
            if running { stop() }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(failure),
                          userInfo: [NSLocalizedDescriptionKey: "无法把物理麦克风送入虚拟设备（\(failure)）"])
        }
        for pid in mutedClients.subtracting(forwardedMutes) {
            try setMute(pid, muted: true)
            forwardedMutes.insert(pid)
        }
        for pid in forwardedMutes.subtracting(mutedClients) {
            try setMute(pid, muted: false)
            forwardedMutes.remove(pid)
        }
        if activeClients.isEmpty {
            if running { stop() }
            return
        }
        let currentDevice: AudioObjectID
        do { currentDevice = try physicalInputDevice() }
        catch {
            if running { stop() }
            throw error
        }
        if running && (!engine.isRunning || sourceDeviceID != currentDevice) { stop() }
        if !running { try start(device: currentDevice) }
    }

    func suspend() {
        if running { stop() }
    }

    private func physicalInputDevice() throws -> AudioObjectID {
        var defaultDevice = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &defaultDevice) == noErr,
              defaultDevice != deviceID else {
            throw NSError(domain: "NearbyAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请把系统默认输入设为物理麦克风，仅在目标应用中选择 Nearby Audio Microphone"])
        }
        return defaultDevice
    }

    private func start(device: AudioObjectID) throws {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48000, channels: source.channelCount,
                                         interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw NSError(domain: "NearbyAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "物理麦克风格式不可用"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self, converter] buffer, _ in
            self?.forward(buffer, converter: converter, target: target)
        }
        do {
            statusLock.lock()
            pushFailure = nil
            statusLock.unlock()
            try engine.start()
            running = true
            sourceDeviceID = device
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync {}
        running = false
        sourceDeviceID = nil
    }

    private func forward(_ input: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
        guard pending.wait(timeout: .now()) == .success else { return }
        let capacity = AVAudioFrameCount((Double(input.frameLength) * 48000 / input.format.sampleRate).rounded(.up) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            pending.signal()
            return
        }
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard result != .error, output.frameLength > 0,
              let channels = output.floatChannelData else {
            pending.signal()
            return
        }
        let frames = Int(output.frameLength)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            samples[frame * 2] = channels[0][frame]
            samples[frame * 2 + 1] = channels[Int(min(output.format.channelCount - 1, 1))][frame]
        }
        queue.async { [weak self] in
            defer { self?.pending.signal() }
            guard let self else { return }
            samples.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var frame = 0
                while frame < frames {
                    let count = min(2048, frames - frame)
                    let pointer = base.advanced(by: frame * 2 * MemoryLayout<Float>.size)
                        .assumingMemoryBound(to: UInt8.self)
                    if let data = CFDataCreate(kCFAllocatorDefault, pointer,
                                               count * 2 * MemoryLayout<Float>.size) {
                        let status = self.setProperty(Self.audioPush, data: data)
                        if status != noErr {
                            self.statusLock.lock()
                            self.pushFailure = status
                            self.statusLock.unlock()
                            return
                        }
                    }
                    frame += count
                }
            }
        }
    }

    private func setMute(_ pid: pid_t, muted: Bool) throws {
        var command = (Int32(pid), UInt32(muted ? 1 : 0))
        let data = withUnsafeBytes(of: &command) { bytes in
            CFDataCreate(kCFAllocatorDefault, bytes.bindMemory(to: UInt8.self).baseAddress,
                         bytes.count)!
        }
        let status = setProperty(Self.clientMute, data: data)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法设置虚拟麦克风静音（\(status)）"])
        }
    }

    private func setProperty(_ selector: AudioObjectPropertySelector, data: CFData) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = data
        return withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                       UInt32(MemoryLayout<CFData>.size), pointer)
        }
    }
}
