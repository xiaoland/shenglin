import AppKit
import Carbon
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
#if canImport(NearbyAudioCore)
import NearbyAudioCore
#endif

enum ExclusionStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NearbyAudio/exclusions.json")
    private static let legacyURL = url.deletingLastPathComponent().appendingPathComponent("selection.json")

    static func load() throws -> Set<String> {
        try InputExclusionStore.load(at: url, legacyURL: legacyURL)
    }

    static func change(_ selector: String, add: Bool) throws {
        try InputExclusionStore.change(selector, add: add, at: url, legacyURL: legacyURL)
    }

    static func normalized(_ argument: String) -> String? {
        guard !argument.isEmpty, !argument.contains(where: \.isWhitespace) else { return nil }
        if argument.hasPrefix("path:") { return argument.dropFirst(5).first == "/" ? argument : nil }
        if argument.hasPrefix("bundle:") { return argument.count > 7 ? argument : nil }
        return argument.contains(".") ? "bundle:\(argument)" : nil
    }
}

enum MuteStore {
    static let url = ExclusionStore.url.deletingLastPathComponent().appendingPathComponent("muted.json")

    static func load() throws -> Set<String> { try InputMuteStore.load(at: url) }
    static func change(_ selector: String, add: Bool) throws {
        try InputMuteStore.change(selector, add: add, at: url)
    }
}

enum MicrophoneStore {
    static let url = ExclusionStore.url.deletingLastPathComponent().appendingPathComponent("microphones.json")
    static func load() throws -> [DedicatedMicrophone] { try DedicatedMicrophoneStore.load(at: url) }
    static func save(_ devices: [DedicatedMicrophone]) throws { try DedicatedMicrophoneStore.save(devices, at: url) }
}

struct PhysicalInputSource: Identifiable {
    let id: String
    let name: String
    let sampleRate: Int
    let channels: Int
    let isDefault: Bool

    static func available() -> [Self] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var defaultID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(system, &defaultAddress, 0, nil, &size, &defaultID)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty, ids.withUnsafeMutableBufferPointer({
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }) == noErr else { return [] }
        return ids.compactMap { device in
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var textSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &textSize, &uid) == noErr,
                  let uid = uid?.takeRetainedValue() as String?,
                  !uid.hasPrefix("local.nearbyaudio.virtual-microphone") else { return nil }
            var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamSize) == noErr,
                  streamSize >= MemoryLayout<AudioObjectID>.size else { return nil }
            var streams = [AudioObjectID](repeating: 0, count: Int(streamSize) / MemoryLayout<AudioObjectID>.size)
            guard streams.withUnsafeMutableBufferPointer({
                AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &streamSize, $0.baseAddress!)
            }) == noErr else { return nil }
            var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(streams[0], &formatAddress, 0, nil, &formatSize, &format) == noErr,
                  format.mSampleRate.isFinite, (8000...192000).contains(Int(format.mSampleRate)),
                  (1...2).contains(Int(format.mChannelsPerFrame)) else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            textSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            _ = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &textSize, &name)
            return Self(id: uid, name: name?.takeRetainedValue() as String? ?? uid,
                sampleRate: Int(format.mSampleRate.rounded()), channels: Int(format.mChannelsPerFrame),
                isDefault: device == defaultID)
        }.sorted { $0.name < $1.name }
    }
}

struct MicrophoneHotKey: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    var title: String {
        "\(modifiers & UInt32(controlKey) != 0 ? "⌃" : "")\(modifiers & UInt32(optionKey) != 0 ? "⌥" : "")\(modifiers & UInt32(shiftKey) != 0 ? "⇧" : "")\(modifiers & UInt32(cmdKey) != 0 ? "⌘" : "")\(key)"
    }

    var systemShortcutWarning: String? {
        guard modifiers == UInt32(optionKey | cmdKey) else { return nil }
        let actions = ["H": "隐藏其他应用", "M": "最小化当前应用的所有窗口", "W": "关闭当前应用的所有窗口"]
        guard let action = actions[key] else { return nil }
        return "\(title) 也是 macOS 的“\(action)”快捷键，建议更换。"
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        let required = [NSEvent.ModifierFlags.control, .option, .command].filter { flags.contains($0) }
        guard required.count >= 2,
              let character = event.charactersIgnoringModifiers?.uppercased(),
              character.count == 1,
              character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
        var bits: UInt32 = 0
        if flags.contains(.control) { bits |= UInt32(controlKey) }
        if flags.contains(.option) { bits |= UInt32(optionKey) }
        if flags.contains(.shift) { bits |= UInt32(shiftKey) }
        if flags.contains(.command) { bits |= UInt32(cmdKey) }
        guard !(bits == UInt32(controlKey | cmdKey) && character == "Q") else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = bits
        key = character
    }
}

enum HotKeyStore {
    private static let key = "microphoneHotKeys"
    static func load() throws -> [String: MicrophoneHotKey] {
        guard let data = MacPreferences.defaults.data(forKey: key) else { return [:] }
        return try JSONDecoder().decode([String: MicrophoneHotKey].self, from: data)
    }
    static func save(_ shortcuts: [String: MicrophoneHotKey]) throws {
        MacPreferences.defaults.set(try JSONEncoder().encode(shortcuts), forKey: key)
    }
}

final class MicrophoneHotKeys {
    private var handler: EventHandlerRef?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var registered = [String: (id: UInt32, ref: EventHotKeyRef)]()
    private var passiveKeys = [String: MicrophoneHotKey]()
    private var selectors = [UInt32: String]()
    private var pressed = Set<UInt32>()
    private var nextID: UInt32 = 1
    private let onPress: (String) -> Void
    var usesPassiveTap: Bool { tap != nil }

    init(usePassiveTap: Bool = false, onPress: @escaping (String) -> Void) throws {
        self.onPress = onPress
        if usePassiveTap {
            guard CGPreflightListenEventAccess() else {
                throw NSError(domain: "NearbyAudio", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "请在系统设置的“隐私与安全性 → 输入监控”中允许 Nearby Audio"])
            }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
               options: .listenOnly,
               eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
               callback: { _, type, event, context in
                   if let context {
                       Unmanaged<MicrophoneHotKeys>.fromOpaque(context).takeUnretainedValue()
                           .handlePassive(type, event: event)
                   }
                   return Unmanaged.passUnretained(event)
               }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                throw NSError(domain: "NearbyAudio", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "输入监控监听器无法启动；请核对授权并重试"])
            }
            self.tap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            tapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        var events = [EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            return Unmanaged<MicrophoneHotKeys>.fromOpaque(context).takeUnretainedValue().handle(event)
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    deinit {
        for selector in Array(registered.keys) { unregister(selector) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ hotKey: MicrophoneHotKey, for selector: String) throws {
        if tap != nil {
            precondition(passiveKeys[selector] == nil)
            guard !passiveKeys.values.contains(where: { $0.keyCode == hotKey.keyCode &&
                $0.modifiers == hotKey.modifiers }) else {
                throw NSError(domain: "NearbyAudio", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "该组合已分配给另一台专用麦克风"])
            }
            passiveKeys[selector] = hotKey
            return
        }
        precondition(registered[selector] == nil)
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers,
            EventHotKeyID(signature: 0x4e42484b, id: id), GetApplicationEventTarget(),
            UInt32(kEventHotKeyNoOptions), &reference)
        guard status == noErr, let reference else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法启用快捷键，请换一个组合（\(status)）"])
        }
        registered[selector] = (id, reference)
        selectors[id] = selector
    }

    func unregister(_ selector: String) {
        if passiveKeys.removeValue(forKey: selector) != nil { return }
        guard let old = registered.removeValue(forKey: selector) else { return }
        UnregisterEventHotKey(old.ref)
        selectors.removeValue(forKey: old.id)
        pressed.remove(old.id)
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKey = EventHotKeyID()
        let status = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
        guard status == noErr, hotKey.signature == 0x4e42484b,
              let selector = selectors[hotKey.id] else { return noErr }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) { pressed.remove(hotKey.id) }
        else if pressed.insert(hotKey.id).inserted { onPress(selector) }
        return noErr
    }

    private func handlePassive(_ type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        for (selector, key) in passiveKeys where key.keyCode == keyCode && key.modifiers == modifiers {
            onPress(selector)
        }
    }

}

func outerApplicationBundleID(path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
}

func executablePath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = buffer.withUnsafeMutableBufferPointer { pointer in
        proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
    }
    return length > 0 ? String(cString: buffer) : nil
}

func sourceIdentities(pid: pid_t) -> Set<String> {
    var identities = Set<String>()
    if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
        identities.insert("bundle:\(bundle)")
    }
    if let path = executablePath(pid: pid) {
        identities.insert("path:\(path)")
        if let bundle = outerApplicationBundleID(path: path) {
            identities.insert("bundle:\(bundle)")
        }
    }
    return identities
}

struct SourceCandidate: Identifiable {
    let selector: String
    let name: String
    let isActive: Bool
    let isExcluded: Bool
    let isMuted: Bool
    let microphoneName: String?
    let microphoneInUse: Bool
    var id: String { selector }
}

func availableSources() throws -> [SourceCandidate] {
    let excluded = try ExclusionStore.load()
    let muted = try MuteStore.load()
    let microphones = try MicrophoneStore.load()
    guard let active = activeInputPIDs() else {
        throw NSError(domain: "NearbyAudio", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Core Audio 输入状态查询失败"])
    }
    let activeIdentities = active.map { sourceIdentities(pid: $0) }
    var rows = [String: String]()
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let selector = app.bundleIdentifier.map({ "bundle:\($0)" })
                ?? app.executableURL.map({ "path:\($0.path)" }) else { continue }
        rows[selector] = app.localizedName ?? selector
    }
    for pid in active {
        let identities = sourceIdentities(pid: pid)
        guard let selector = executablePath(pid: pid).flatMap(outerApplicationBundleID(path:)).map({ "bundle:\($0)" })
                ?? identities.filter({ $0.hasPrefix("bundle:") }).sorted().first
                ?? identities.filter({ $0.hasPrefix("path:") }).sorted().first else { continue }
        rows[selector] = rows[selector]
            ?? NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? executablePath(pid: pid).map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "进程 \(pid)"
    }
    for microphone in microphones { rows[microphone.selector] = rows[microphone.selector] ?? microphone.name }
    for selector in excluded.union(muted) where rows[selector] == nil {
        if selector.hasPrefix("bundle:"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(selector.dropFirst(7))) {
            rows[selector] = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
        } else {
            rows[selector] = selector.hasPrefix("path:")
                ? URL(fileURLWithPath: String(selector.dropFirst(5))).lastPathComponent : selector
        }
    }
    return rows.map { selector, name in
        SourceCandidate(selector: selector, name: name,
                        isActive: activeIdentities.contains { $0.contains(selector) },
                        isExcluded: excluded.contains(selector), isMuted: muted.contains(selector),
                        microphoneName: microphones.first { $0.selector == selector }?.deviceName,
                        microphoneInUse: microphones.first { $0.selector == selector }.flatMap {
                            VirtualMicrophone.deviceID(uid: $0.uid)
                        }.flatMap { activeInputPIDs(on: $0) }.map { !$0.isEmpty } ?? false)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func printSources() throws {
    for source in try availableSources() {
        print("\(source.isActive ? "●" : " ") \(source.isExcluded ? "×" : " ") \(source.name)\t\(source.selector)")
    }
    print("● 正在采集输入；× 已排除。使用 nearby-audio exclude add <bundle:标识或path:绝对路径>。")
}
