import AppKit
import CoreAudio
import Darwin
import Foundation
#if canImport(ShenglinCore)
import ShenglinCore
#endif

func isBrowser(_ identities: Set<String>) -> Bool {
    // WebKit helpers may be shared by several hosts; never treat their mix as one native app.
    let fixed: Set<String> = ["com.apple.Safari", "com.apple.WebKit.WebContent", "com.apple.WebKit.GPU",
        "com.google.Chrome", "org.chromium.Chromium", "net.imput.helium", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "company.thebrowser.Browser"]
    return identities.contains { identity in
        identity.hasPrefix("bundle:") && fixed.contains { browser in
            String(identity.dropFirst(7)) == browser || String(identity.dropFirst(7)).hasPrefix(browser + ".")
        }
    }
        || identities.contains { $0.contains("/Safari.app/") || $0.contains("/Helium.app/") }
}

private func outputAddress(_ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private struct OutputRoute {
    let id: AudioObjectID
    let uid: String
    let volume: Float?

    static func current() throws -> Self {
        guard let id = audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice), id != 0 else {
            throw outputError("默认输出设备不可用")
        }
        var address = outputAddress(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try outputCheck(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid), "读取输出设备标识")
        guard let uid = uid?.takeRetainedValue() as String? else { throw outputError("输出设备标识不可用") }
        address = outputAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
        var volume: Float = -1
        size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &volume)
        return Self(id: id, uid: uid, volume: status == noErr && volume.isFinite && (0...1).contains(volume) ? volume : nil)
    }
}

private func outputError(_ message: String) -> NSError {
    NSError(domain: "ShenglinOutput", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
private func outputCheck(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw outputError("\(operation)失败（\(status)）") }
}

private struct OutputProcess: Hashable {
    let object: AudioObjectID
    let pid: pid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let identities: Set<String>

    static func read(_ object: AudioObjectID) -> Self? {
        guard let rawPID = audioProperty(object, kAudioProcessPropertyPID), rawPID > 0 else { return nil }
        let pid = pid_t(rawPID)
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Self(object: object, pid: pid, startedSeconds: info.pbi_start_tvsec,
                    startedMicroseconds: info.pbi_start_tvusec, identities: sourceIdentities(pid: pid))
    }

    static func active(on device: AudioObjectID) throws -> [Self] {
        var address = outputAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try outputCheck(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "读取播放进程")
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if objects.isEmpty { return [] }
        try objects.withUnsafeMutableBufferPointer {
            try outputCheck(AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!), "读取播放进程")
        }
        return objects.compactMap { object in
            guard audioProperty(object, kAudioProcessPropertyIsRunningOutput) == 1 else { return nil }
            var devicesAddress = outputAddress(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
            var devicesSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(object, &devicesAddress, 0, nil, &devicesSize) == noErr,
                  devicesSize == MemoryLayout<AudioObjectID>.size else { return nil }
            var onlyDevice = AudioObjectID(0)
            guard AudioObjectGetPropertyData(object, &devicesAddress, 0, nil, &devicesSize, &onlyDevice) == noErr,
                  onlyDevice == device else { return nil }
            return read(object)
        }
    }
}

func applyOutputGain(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>,
                     gain: Float) -> Bool {
    let outputs = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard gain.isFinite, (0...1).contains(gain), inputs.count == 1, outputs.count == 1,
          inputs[0].mNumberChannels == 2, outputs[0].mNumberChannels == 2,
          inputs[0].mDataByteSize == outputs[0].mDataByteSize, inputs[0].mDataByteSize % 8 == 0,
          let source = inputs[0].mData?.assumingMemoryBound(to: Float.self),
          let destination = outputs[0].mData?.assumingMemoryBound(to: Float.self) else { return false }
    for index in 0..<Int(inputs[0].mDataByteSize) / MemoryLayout<Float>.size {
        destination[index] = source[index] * gain
    }
    return true
}

@available(macOS 14.2, *)
private final class NativeOutputRelay {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var running = false
    private let faults = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let callbacks = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var lastCallbacks: Int64 = 0
    var healthy: Bool {
        let count = OSAtomicAdd64Barrier(0, callbacks)
        if count != lastCallbacks {
            lastCallbacks = count
            lastProgress = ProcessInfo.processInfo.systemUptime
        }
        return OSAtomicAdd64Barrier(0, faults) == 0 && ProcessInfo.processInfo.systemUptime - lastProgress < 2
    }

    init(processes: [OutputProcess], route: OutputRoute, gain: Float) throws {
        faults.initialize(to: 0)
        callbacks.initialize(to: 0)
        do {
            guard gain.isFinite, (0...1).contains(gain), !processes.isEmpty,
                  processes.allSatisfy({ OutputProcess.read($0.object) == $0 }) else {
                throw outputError("播放进程已经更换，未接管输出")
            }
            // First release accepts only the measured output-only, single stereo-stream path.
            // ponytail: duplex/multistream routes need an explicitly verified channel map before capture.
            var address = outputAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var size: UInt32 = 0
            try outputCheck(AudioObjectGetPropertyDataSize(route.id, &address, 0, nil, &size), "检查输出设备")
            guard size == 0 else { throw outputError("此输出设备含输入流，暂不支持应用调音") }
            address = outputAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            try outputCheck(AudioObjectGetPropertyDataSize(route.id, &address, 0, nil, &size), "检查输出流")
            guard size == MemoryLayout<AudioObjectID>.size else { throw outputError("暂不支持多输出流设备") }
            let description = CATapDescription(processes: processes.map(\.object), deviceUID: route.uid, stream: 0)
            description.name = "声邻其他应用输出"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try outputCheck(AudioHardwareCreateProcessTap(description, &tap), "创建应用输出 Tap（请检查系统音频录制授权）")
            address = outputAddress(kAudioTapPropertyFormat)
            var format = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try outputCheck(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "读取输出格式")
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2,
                  format.mBytesPerFrame == 8, format.mSampleRate.isFinite, (8000...192000).contains(format.mSampleRate) else {
                throw outputError("暂不支持此输出音频格式")
            }
            let composition: [String: Any] = [kAudioAggregateDeviceNameKey: "声邻应用调音（临时）",
                kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: route.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: route.uid]],
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                  kAudioSubTapDriftCompensationKey: true]]]
            try outputCheck(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "创建应用重放设备")
            let faultCount = faults, callbackCount = callbacks
            try outputCheck(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { _, input, _, output, _ in
                guard applyOutputGain(input, output, gain: gain) else {
                    OSAtomicAdd64Barrier(1, faultCount)
                    return
                }
                OSAtomicAdd64Barrier(1, callbackCount)
            }, "创建应用重放回调")
            try outputCheck(AudioDeviceStart(aggregate, io), "启动应用重放")
            running = true
        } catch {
            stop()
            throw error
        }
    }
    deinit {
        stop()
        faults.deinitialize(count: 1); faults.deallocate()
        callbacks.deinitialize(count: 1); callbacks.deallocate()
    }
    private func stop() {
        if running { AudioDeviceStop(aggregate, io) }
        if let io { AudioDeviceDestroyIOProcID(aggregate, io) }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        io = nil; aggregate = 0; tap = 0; running = false
    }
}

@MainActor final class ApplicationOutput {
    private var relay: AnyObject?
    private var selected = Set<OutputProcess>()
    private var gain: Float?
    private var baseline: OutputRoute?
    private var manual = false
    private var failed = false
    private let onManual: () -> Void
    private(set) var status = "应用输出保持原状"
    init(onManual: @escaping () -> Void) { self.onManual = onManual }

    var yielded: Bool { manual }
    func update(requested: Float?, protected: Set<String>, inputKnown: Bool, manualOverride: Bool = false) -> String {
        guard let requested else {
            let hadRelay = relay != nil
            relay = nil; selected = []; gain = nil; baseline = nil; manual = false; failed = false
            status = "应用输出保持原状"
            return hadRelay ? "restored" : "alreadyRestored"
        }
        if manualOverride { manual = true }
        do {
            let route = try OutputRoute.current()
            if let baseline, route.uid != baseline.uid ||
                (route.volume != nil && baseline.volume != nil && abs(route.volume! - baseline.volume!) > 0.005) {
                if !manual { manual = true; onManual() }
            }
            if baseline == nil { baseline = route }
            if manual { relay = nil; status = "已解除本轮衰减，保留手动音量或新输出设备"; return "preservedManual" }
            guard inputKnown else { relay = nil; selected = []; status = "输入状态未知，应用输出保持原状"; return "unknown" }
            guard #available(macOS 14.2, *) else { status = "应用调音需要 macOS 14.2 或更新版本"; return "outputUnsupported" }
            if let relay = relay as? NativeOutputRelay, !relay.healthy {
                failed = true; self.relay = nil
                status = "应用重放中断，已解除本轮原生衰减"
            }
            guard !failed else { return "outputUnsupported" }
            let processes = try OutputProcess.active(on: route.id).filter {
                $0.pid != getpid() && $0.pid != MicrophoneAgentStatus.current()?.pid &&
                VolumePolicy.outputGain(identities: $0.identities, protected: protected,
                                        browser: isBrowser($0.identities), requested: requested) < 1
            }
            let next = Set(processes)
            if next != selected || gain != requested {
                relay = nil
                selected = next; gain = requested
                if !processes.isEmpty { relay = try NativeOutputRelay(processes: processes, route: route, gain: requested) }
            }
            let names = Set(processes.compactMap { process in
                NSWorkspace.shared.runningApplications.first { app in
                    app.activationPolicy == .regular && app.bundleIdentifier.map { process.identities.contains("bundle:\($0)") } == true
                }?.localizedName ?? NSRunningApplication(processIdentifier: process.pid)?.localizedName
                    ?? executablePath(pid: process.pid).map { URL(fileURLWithPath: $0).lastPathComponent }
            }).sorted()
            status = processes.isEmpty ? "输入应用的输出保持原状，暂无可调低的原生应用" : "已调低：\(names.joined(separator: "、"))"
            return processes.isEmpty ? "alreadyQuiet" : "selectiveApplied"
        } catch {
            relay = nil; selected = []; failed = true
            status = error.localizedDescription
            return "outputUnsupported"
        }
    }
}

// Bounded hardware validation uses this exact relay implementation and a single disposable afplay source.
// It doesn't start coordination, register the microphone service, or change system volume.
enum ApplicationOutputValidation {
    static func run() -> Never {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--output-validation"), arguments.count == index + 4,
              let pid = pid_t(arguments[index + 1]), pid > 0,
              let seconds = Int(arguments[index + 2]), (1...60).contains(seconds),
              let gain = Float(arguments[index + 3]), gain.isFinite, (0...1).contains(gain),
              executablePath(pid: pid) == "/usr/bin/afplay", #available(macOS 14.2, *) else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.global(qos: .userInitiated).async {
            var relay: NativeOutputRelay?
            do {
                var target = pid
                var object = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
                var address = outputAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
                try outputCheck(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                    UInt32(MemoryLayout<pid_t>.size), &target, &size, &object), "读取实验音源")
                guard let process = OutputProcess.read(object), process.pid == pid else { throw outputError("实验音源已经退出") }
                let route = try OutputRoute.current()
                relay = try NativeOutputRelay(processes: [process], route: route, gain: gain)
                print("OUTPUT_VALIDATION_READY target=\(pid) gain=\(gain) device=\(route.uid)"); fflush(stdout)
                for _ in 0..<(seconds * 20) {
                    guard relay?.healthy == true, try OutputRoute.current().uid == route.uid,
                          OutputProcess.read(object) == process else { throw outputError("实验音源、路由或重放状态发生变化") }
                    usleep(50_000)
                }
                relay = nil
                print("OUTPUT_VALIDATION_RELEASED"); fflush(stdout)
                exit(0)
            } catch {
                relay = nil
                fputs("输出验证失败：\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
        exit(1)
    }
}
