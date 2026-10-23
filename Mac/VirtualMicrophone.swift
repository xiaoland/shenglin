import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
#if canImport(ShenglinCore)
import ShenglinCore
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
    private enum Counter { static let tapped = 0, busy = 1, conversion = 2, pushFailed = 3, pushed = 4, queued = 5 }
    private static let audioPush: AudioObjectPropertySelector = 0x4e414d50 // NAMP
    private static let deviceMute: AudioObjectPropertySelector = 0x4e414d44 // NAMD
    private static let deviceList: AudioObjectPropertySelector = 0x4e414453 // NADS
    private var inputUnit: AudioUnit?
    private var inputBuffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "Shenglin.VirtualMicrophone")
    // Preserve the three 100 ms tap buffers' backlog budget when AUHAL uses smaller callbacks.
    private var pendingFrameLimit: Int64 = 0
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
    private static var configured: [DedicatedMicrophone]?
    private static var configuredPlugin: AudioObjectID?
    private let sourceUID: String?
    private let remoteSource: RemoteMicrophoneSource?
    private var remoteCapture: RemoteMicrophoneCapture?
    private var generation = 0
    var remoteError: String? { remoteCapture?.error }
    private let outputSampleRate: Int
    private let outputChannels: Int
    private let counters = UnsafeMutablePointer<Int64>.allocate(capacity: 6)

    init(sourceUID: String? = nil, sampleRate: Int = 48000, channels: Int = 2,
         remoteSource: RemoteMicrophoneSource? = nil) {
        self.sourceUID = sourceUID
        self.remoteSource = remoteSource
        outputSampleRate = sampleRate
        outputChannels = channels
        counters.initialize(repeating: 0, count: 6)
    }
    deinit { remoteCapture?.stop(); releaseInput(); counters.deinitialize(count: 6); counters.deallocate() }

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
        guard let plugin = objectID(kAudioHardwarePropertyTranslateBundleIDToPlugIn, uid: "local.shenglin.driver") else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: deviceList, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        return AudioObjectHasProperty(plugin, &address) ? plugin : nil
    }

    static func publish(_ devices: [DedicatedMicrophone]) throws {
        guard let plugin = Self.pluginID else {
            configured = nil
            if devices.isEmpty { return }
            throw NSError(domain: "Shenglin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请安装支持专用麦克风的 声邻驱动"])
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
    }

    func update(inputs: [pid_t: Set<AudioObjectID>], devices: [DedicatedMicrophone],
                group: [DedicatedMicrophone], muted: Set<String>) throws -> Set<pid_t> {
        try Self.publish(devices)
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
                throw NSError(domain: "Shenglin", code: 2,
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
            if let remoteSource {
                if !running {
                    try Self.check(primeDestinations(), "无法预充远端麦克风")
                    let epoch = queue.sync { generation += 1; return generation }
                    remoteCapture = RemoteMicrophoneCapture(source: remoteSource) { [weak self] pcm in
                        guard let self else { return }
                        try self.queue.sync {
                            guard self.generation == epoch else { return }
                            let samples = pcm.withUnsafeBytes { bytes in
                                stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
                            }
                            let hostTime = mach_absolute_time()
                            for selector in self.destinationSelectors.values {
                                AudioForensics.shared.recordSource(selector, sampleRate: self.outputSampleRate,
                                    channels: self.outputChannels, hostTime: hostTime, sampleTime: -1, samples: samples)
                            }
                            self.add(Int64(pcm.count / 4), to: Counter.tapped)
                            for destination in self.destinations {
                                let status = Self.setProperty(destination, Self.audioPush, data: pcm as CFData)
                                if status != noErr { self.add(Int64(pcm.count / 4), to: Counter.pushFailed) }
                                try Self.check(status, "无法写入远端麦克风")
                            }
                            self.add(Int64(pcm.count / 4), to: Counter.pushed)
                        }
                    }
                    running = true
                    sourceSampleRate = 48000; sourceChannels = 1; directFormat = true
                    for selector in queue.sync(execute: { Array(destinationSelectors.values) }) {
                        AudioForensics.shared.event(selector, "capture-started", ["remotePeer": remoteSource.peerID,
                            "remoteInput": remoteSource.sourceID, "sourceSampleRate": 48000, "sourceChannels": 1])
                    }
                }
            } else {
                let currentDevice = try physicalInputDevice()
                if running && (!isCapturing || sourceDeviceID != currentDevice) { stop() }
                if !running { try start(device: currentDevice) }
            }
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
                throw NSError(domain: "Shenglin", code: 5,
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
            throw NSError(domain: "Shenglin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请把系统默认输入设为物理麦克风，仅在目标应用中选择其专用 声邻输入"])
        }
        return defaultDevice
    }

    private func isNearbyDevice(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let uid else { return true }
        return (uid.takeRetainedValue() as String).hasPrefix("local.shenglin.virtual-microphone")
    }

    private func start(device: AudioObjectID) throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            if !permissionRequested {
                permissionRequested = true
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            throw NSError(domain: "Shenglin", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "请在系统弹窗中允许声邻使用麦克风"])
        default:
            throw NSError(domain: "Shenglin", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "声邻没有麦克风权限，请在系统设置的“隐私与安全性 → 麦克风”中允许访问"])
        }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NSError(domain: "Shenglin", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建物理麦克风输入"])
        }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created), "无法创建物理麦克风输入")
        guard let unit = created else {
            throw NSError(domain: "Shenglin", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "物理麦克风输入未创建"])
        }
        inputUnit = unit
        do {
            // An input-only AUHAL keeps each selected source independent of the system output route.
            var enabled: UInt32 = 1, disabled: UInt32 = 0
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1, &enabled, UInt32(MemoryLayout<UInt32>.size)), "无法启用物理麦克风")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output, 0, &disabled, UInt32(MemoryLayout<UInt32>.size)), "无法关闭麦克风输出")
            var selected = device
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioObjectID>.size)), "无法选择物理麦克风")
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 1, &hardware, &size), "无法读取物理麦克风格式")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame, interleaved: false),
                  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: Double(outputSampleRate), channels: source.channelCount, interleaved: false) else {
                throw NSError(domain: "Shenglin", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "物理麦克风格式不可用"])
            }
            // AUHAL can change PCM layout, but sample-rate conversion belongs after capture.
            var format = source.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output, 1, &format, size), "无法设置物理麦克风格式")
            let direct = source.sampleRate == Double(outputSampleRate)
            converter = direct ? nil : AVAudioConverter(from: source, to: target)
            guard direct || converter != nil else {
                throw NSError(domain: "Shenglin", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "物理麦克风格式无法转换"])
            }
            targetFormat = target
            var callback = AURenderCallbackStruct(inputProc: { context, flags, time, _, frames, _ in
                Unmanaged<VirtualMicrophone>.fromOpaque(context).takeUnretainedValue()
                    .capture(flags: flags, time: time, frames: frames)
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "无法设置麦克风回调")
            try Self.check(AudioUnitInitialize(unit), "无法初始化物理麦克风")
            var maximumFrames: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &maximumFrames, &size), "无法读取麦克风缓冲大小")
            guard maximumFrames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: maximumFrames) else {
                throw NSError(domain: "Shenglin", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "无法分配麦克风缓冲"])
            }
            inputBuffer = buffer
            pendingFrameLimit = Int64(source.sampleRate * 0.3)
            statusLock.lock()
            pushFailure = nil
            statusLock.unlock()
            try Self.check(primeDestinations(), "无法预充专用麦克风")
            try Self.check(AudioOutputUnitStart(unit), "无法启动物理麦克风")
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
        } catch {
            releaseInput()
            queue.sync {}
            pendingFrameLimit = 0
            throw error
        }
    }

    private var isCapturing: Bool {
        guard let unit = inputUnit else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning,
            kAudioUnitScope_Global, 0, &value, &size) == noErr && value != 0
    }

    private func capture(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         time: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit = inputUnit, let buffer = inputBuffer, let target = targetFormat else {
            return kAudioUnitErr_Uninitialized
        }
        let status: OSStatus
        if frames > buffer.frameCapacity { status = kAudioUnitErr_TooManyFramesToProcess }
        else {
            buffer.frameLength = frames
            status = AudioUnitRender(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        }
        guard status == noErr else {
            statusLock.lock()
            pushFailure = status
            statusLock.unlock()
            return status
        }
        forward(buffer, when: AVAudioTime(audioTimeStamp: time, sampleRate: buffer.format.sampleRate),
                converter: converter, target: target)
        return noErr
    }

    private func releaseInput() {
        if let unit = inputUnit {
            // Stop callbacks before releasing their unretained owner or reusable PCM buffer.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputUnit = nil
        inputBuffer = nil
        converter = nil
        targetFormat = nil
    }

    private func stop() {
        remoteCapture?.stop()
        remoteCapture = nil
        queue.sync { generation += 1 }
        for selector in queue.sync(execute: { Array(destinationSelectors.values) }) {
            AudioForensics.shared.event(selector, "capture-stopped")
        }
        releaseInput()
        queue.sync {}
        pendingFrameLimit = 0
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
        let queued = OSAtomicAdd64Barrier(sourceFrames, counters.advanced(by: Counter.queued))
        guard queued <= pendingFrameLimit else {
            add(-sourceFrames, to: Counter.queued)
            add(sourceFrames, to: Counter.busy)
            return
        }
        var converted: AVAudioPCMBuffer?
        if let converter {
            let capacity = AVAudioFrameCount((Double(input.frameLength) * Double(outputSampleRate) /
                input.format.sampleRate).rounded(.up) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                add(sourceFrames, to: Counter.conversion)
                add(-sourceFrames, to: Counter.queued)
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
            add(-sourceFrames, to: Counter.queued)
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
            defer { self?.add(-sourceFrames, to: Counter.queued) }
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
