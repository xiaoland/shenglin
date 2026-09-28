import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
#if canImport(NearbyAudioCore)
import NearbyAudioCore
#endif

struct CaptureDiagnostics: Codable {
    let sourceSampleRate: Double?
    let sourceChannels: Int?
    let directFormat: Bool
    let tappedFrames: Int64
    let busyDroppedFrames: Int64
    let conversionDroppedFrames: Int64
    let pushFailedFrames: Int64
    let pushedFrames: Int64
}

final class VirtualMicrophone {
    private enum Counter { static let tapped = 0, busy = 1, conversion = 2, pushFailed = 3, pushed = 4 }
    private static let audioPush: AudioObjectPropertySelector = 0x4e414d50 // NAMP
    private static let deviceMute: AudioObjectPropertySelector = 0x4e414d44 // NAMD
    private static let deviceList: AudioObjectPropertySelector = 0x4e414453 // NADS
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "NearbyAudio.VirtualMicrophone")
    // One push may still be in Core Audio when the next tap arrives.
    private let pending = DispatchSemaphore(value: 3)
    private let statusLock = NSLock()
    private var pushFailure: OSStatus?
    private var running = false
    private var inactiveSince: TimeInterval?
    private var permissionRequested = false
    private var sourceDeviceID: AudioObjectID?
    private var sourceSampleRate: Double?
    private var sourceChannels: Int?
    private var directFormat = false
    private var destinations = [AudioObjectID]()
    private var destinationSelectors = [AudioObjectID: String]()
    private var configured: [DedicatedMicrophone]?
    private var configuredPlugin: AudioObjectID?
    private let sourceUID: String?
    private let outputSampleRate: Int
    private let outputChannels: Int
    private let counters = UnsafeMutablePointer<Int64>.allocate(capacity: 5)

    init(sourceUID: String? = nil, sampleRate: Int = 48000, channels: Int = 2) {
        self.sourceUID = sourceUID
        outputSampleRate = sampleRate
        outputChannels = channels
        counters.initialize(repeating: 0, count: 5)
    }
    deinit { counters.deinitialize(count: 5); counters.deallocate() }

    private func add(_ value: Int64, to index: Int) {
        OSAtomicAdd64Barrier(value, counters.advanced(by: index))
    }

    func diagnostics() -> CaptureDiagnostics {
        CaptureDiagnostics(sourceSampleRate: sourceSampleRate, sourceChannels: sourceChannels,
                           directFormat: directFormat,
                           tappedFrames: OSAtomicAdd64Barrier(0, counters.advanced(by: Counter.tapped)),
                           busyDroppedFrames: OSAtomicAdd64Barrier(0, counters.advanced(by: Counter.busy)),
                           conversionDroppedFrames: OSAtomicAdd64Barrier(0, counters.advanced(by: Counter.conversion)),
                           pushFailedFrames: OSAtomicAdd64Barrier(0, counters.advanced(by: Counter.pushFailed)),
                           pushedFrames: OSAtomicAdd64Barrier(0, counters.advanced(by: Counter.pushed)))
    }

    private static func objectID(_ selector: AudioObjectPropertySelector, uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString = uid as CFString
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &object)
        }
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func deviceID(uid: String) -> AudioObjectID? {
        objectID(kAudioHardwarePropertyTranslateUIDToDevice, uid: uid)
    }
    static var pluginID: AudioObjectID? {
        guard let plugin = objectID(kAudioHardwarePropertyTranslateBundleIDToPlugIn, uid: "local.nearbyaudio.driver") else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: deviceList, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        return AudioObjectHasProperty(plugin, &address) ? plugin : nil
    }

    func update(inputs: [pid_t: Set<AudioObjectID>], devices: [DedicatedMicrophone],
                group: [DedicatedMicrophone], muted: Set<String>) throws -> Set<pid_t> {
        guard let plugin = Self.pluginID else {
            suspend()
            configured = nil
            if devices.isEmpty { return [] }
            throw NSError(domain: "NearbyAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请安装支持专用麦克风的 Nearby 驱动"])
        }
        if configured != devices || configuredPlugin != plugin || devices.contains(where: { Self.deviceID(uid: $0.uid) == nil }) {
            let data = try PropertyListSerialization.data(fromPropertyList: devices.map {
                ["bundle": $0.bundle, "name": $0.name,
                 "sampleRate": $0.outputSampleRate, "channels": $0.outputChannels] as [String: Any]
            }, format: .binary, options: 0)
            try Self.check(Self.setProperty(plugin, Self.deviceList, data: data as CFData), "无法更新专用麦克风列表")
            configured = devices
            configuredPlugin = plugin
        }
        statusLock.lock()
        let failure = pushFailure
        pushFailure = nil
        statusLock.unlock()
        if let failure {
            suspend()
            try Self.check(failure, "无法把物理麦克风送入专用设备")
        }
        var activeDevices = [AudioObjectID]()
        var mutedDevices = Set<AudioObjectID>()
        for device in devices {
            guard let id = Self.deviceID(uid: device.uid) else {
                throw NSError(domain: "NearbyAudio", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "正在发布 \(device.deviceName)，请稍候"])
            }
            var value: UInt32 = muted.contains(device.selector) ? 1 : 0
            let data = withUnsafeBytes(of: &value) { Data($0) }
            try Self.check(Self.setProperty(id, Self.deviceMute, data: data as CFData), "无法设置 \(device.deviceName) 静音")
            if value == 1 { mutedDevices.insert(id) }
            if value == 0 && group.contains(where: { $0.selector == device.selector }) &&
                inputs.values.contains(where: { $0.contains(id) }) { activeDevices.append(id) }
        }
        if activeDevices.isEmpty {
            if running {
                let now = ProcessInfo.processInfo.systemUptime
                let first = inactiveSince ?? now
                inactiveSince = first
                if now - first < 1 {
                    return DedicatedInputPolicy.mutedPIDs(inputs, mutedDevices: mutedDevices)
                }
            }
            queue.sync { destinations = []; destinationSelectors = [:] }
            suspend()
        } else {
            inactiveSince = nil
            queue.sync {
                destinations = activeDevices
                destinationSelectors = Dictionary(uniqueKeysWithValues: group.compactMap { device in
                    Self.deviceID(uid: device.uid).map { ($0, device.selector) }
                })
            }
            let currentDevice = try physicalInputDevice()
            if running && (!engine.isRunning || sourceDeviceID != currentDevice) { stop() }
            if !running { try start(device: currentDevice) }
        }
        return DedicatedInputPolicy.mutedPIDs(inputs, mutedDevices: mutedDevices)
    }

    func suspend() {
        inactiveSince = nil
        if running { stop() }
    }

    private func physicalInputDevice() throws -> AudioObjectID {
        if let sourceUID {
            guard let selected = Self.deviceID(uid: sourceUID), !isNearbyDevice(selected) else {
                throw NSError(domain: "NearbyAudio", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "上游物理麦克风不可用：\(sourceUID)"])
            }
            return selected
        }
        var defaultDevice = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &defaultDevice) == noErr,
              defaultDevice != kAudioObjectUnknown,
              !isNearbyDevice(defaultDevice) else {
            throw NSError(domain: "NearbyAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请把系统默认输入设为物理麦克风，仅在目标应用中选择其专用 Nearby 输入"])
        }
        return defaultDevice
    }

    private func isNearbyDevice(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let uid else { return true }
        return (uid.takeRetainedValue() as String).hasPrefix("local.nearbyaudio.virtual-microphone")
    }

    private func start(device: AudioObjectID) throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            if !permissionRequested {
                permissionRequested = true
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            throw NSError(domain: "NearbyAudio", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "请在系统弹窗中允许 Nearby Audio 使用麦克风"])
        default:
            throw NSError(domain: "NearbyAudio", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Nearby Audio 没有麦克风权限，请在系统设置的“隐私与安全性 → 麦克风”中允许访问"])
        }
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let unit = input.audioUnit {
            var selected = device
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioObjectID>.size)), "无法选择物理麦克风")
        }
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(outputSampleRate), channels: source.channelCount,
                                         interleaved: false) else {
            throw NSError(domain: "NearbyAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "物理麦克风格式不可用"])
        }
        let direct = source.sampleRate == Double(outputSampleRate) &&
            source.commonFormat == .pcmFormatFloat32 && !source.isInterleaved
        let converter = direct ? nil : AVAudioConverter(from: source, to: target)
        guard direct || converter != nil else {
            throw NSError(domain: "NearbyAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "物理麦克风格式无法转换"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self, converter] buffer, when in
            self?.forward(buffer, when: when, converter: converter, target: target)
        }
        do {
            statusLock.lock()
            pushFailure = nil
            statusLock.unlock()
            let pushedAtStart = OSAtomicAdd64Barrier(0, counters.advanced(by: Counter.pushed))
            try engine.start()
            try Self.check(primeDestinations(), "无法预充专用麦克风")
            running = true
            sourceDeviceID = device
            sourceSampleRate = source.sampleRate
            sourceChannels = Int(source.channelCount)
            directFormat = direct
            for selector in queue.sync(execute: { Array(destinationSelectors.values) }) {
                AudioForensics.shared.event(selector, "capture-started", ["sourceUID": sourceUID ?? "system-default",
                    "sourceSampleRate": source.sampleRate, "sourceChannels": source.channelCount,
                    "outputSampleRate": outputSampleRate, "outputChannels": outputChannels])
            }
            // AUHAL may immediately reconfigure a newly started input engine.
            // Refill only if startup churn left the surviving engine without real audio.
            let startedEngine = engine
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.running, self.engine === startedEngine else { return }
                guard OSAtomicAdd64Barrier(0, self.counters.advanced(by: Counter.pushed)) == pushedAtStart else { return }
                let status = self.primeDestinations()
                if status != noErr {
                    self.statusLock.lock()
                    self.pushFailure = status
                    self.statusLock.unlock()
                }
            }
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    private func stop() {
        for selector in queue.sync(execute: { Array(destinationSelectors.values) }) {
            AudioForensics.shared.event(selector, "capture-stopped")
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync {}
        running = false
        sourceDeviceID = nil
        sourceSampleRate = nil
        sourceChannels = nil
        directFormat = false
    }

    private func primeDestinations() -> OSStatus {
        let silence = Data(count: 2048 * outputChannels * MemoryLayout<Float>.size) as CFData
        return queue.sync {
            for destination in destinations {
                for _ in 0..<2 {
                    let status = Self.setProperty(destination, Self.audioPush, data: silence)
                    if status != noErr { return status }
                }
            }
            return noErr
        }
    }

    private func forward(_ input: AVAudioPCMBuffer, when: AVAudioTime,
                         converter: AVAudioConverter?, target: AVAudioFormat) {
        let sourceFrames = Int64(input.frameLength)
        add(sourceFrames, to: Counter.tapped)
        guard pending.wait(timeout: .now()) == .success else {
            add(sourceFrames, to: Counter.busy)
            return
        }
        var converted: AVAudioPCMBuffer?
        if let converter {
            let capacity = AVAudioFrameCount((Double(input.frameLength) * Double(outputSampleRate) /
                input.format.sampleRate).rounded(.up) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                add(sourceFrames, to: Counter.conversion)
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
            if result == .error { converted = nil }
            else { converted = output }
        }
        let output = converter == nil ? input : converted
        guard let output, output.frameLength > 0,
              let channels = output.floatChannelData else {
            add(sourceFrames, to: Counter.conversion)
            pending.signal()
            return
        }
        let frames = Int(output.frameLength)
        var samples = [Float](repeating: 0, count: frames * outputChannels)
        for frame in 0..<frames {
            let left = channels[0][frame]
            let right = channels[Int(min(output.format.channelCount - 1, 1))][frame]
            if outputChannels == 1 {
                samples[frame] = output.format.channelCount == 1 ? left : (left + right) * 0.5
            }
            else {
                samples[frame * 2] = left
                samples[frame * 2 + 1] = right
            }
        }
        queue.async { [weak self] in
            defer { self?.pending.signal() }
            guard let self else { return }
            let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            let sampleTime = when.isSampleTimeValid ? when.sampleTime : -1
            for selector in self.destinationSelectors.values {
                AudioForensics.shared.recordSource(selector, sampleRate: self.outputSampleRate,
                    channels: self.outputChannels, hostTime: hostTime, sampleTime: sampleTime,
                    samples: samples)
            }
            samples.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var frame = 0
                while frame < frames {
                    let count = min(2048, frames - frame)
                    let pointer = base.advanced(by: frame * self.outputChannels * MemoryLayout<Float>.size)
                        .assumingMemoryBound(to: UInt8.self)
                    if let data = CFDataCreate(kCFAllocatorDefault, pointer,
                                               count * self.outputChannels * MemoryLayout<Float>.size) {
                        for destination in self.destinations {
                            let status = Self.setProperty(destination, Self.audioPush, data: data)
                            if status != noErr {
                                self.add(Int64(frames - frame), to: Counter.pushFailed)
                                self.statusLock.lock()
                                self.pushFailure = status
                                self.statusLock.unlock()
                                return
                            }
                        }
                    }
                    frame += count
                }
                if !self.destinations.isEmpty {
                    self.add(Int64(frames), to: Counter.pushed)
                }
            }
        }
    }

    private static func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "\(message)（\(status)）"])
        }
    }

    private static func setProperty(_ deviceID: AudioObjectID, _ selector: AudioObjectPropertySelector, data: CFData) -> OSStatus {
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
