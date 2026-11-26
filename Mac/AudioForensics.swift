import AudioToolbox
import CoreAudio
import CoreServices
import Darwin
import Foundation
#if canImport(ShenglinCore)
import ShenglinCore
#endif

struct ForensicStatus: Codable, Equatable {
    let coverageSeconds: Int
    let droppedSourceBlocks: Int64
    let droppedDriverBlocks: UInt64
    let writeErrors: Int
    let warning: String?
}

/// Local recordings of the samples sent to HAL and returned to clients.
final class AudioForensics {
    static let shared = AudioForensics()
    private static let traceSelector: AudioObjectPropertySelector = 0x4e414d41 // NAMA
    private static let metricsSelector: AudioObjectPropertySelector = 0x4e414d54 // NAMT
    private let queue = DispatchQueue(label: "Shenglin.AudioForensics", qos: .utility)
    private let inventoryQueue = DispatchQueue(label: "Shenglin.ForensicInventory", qos: .utility)
    private let sourceSlots = DispatchSemaphore(value: 64)
    private let pollSlot = DispatchSemaphore(value: 1)
    private let dropLock = NSLock()
    private var pendingSourceDrops = [String: Int64]()
    private var directory: URL
    private var storageVolumeID: String?
    private var handles = [String: FileHandle]()
    private var minute = [String: Int]()
    private var known = [String: DedicatedMicrophone]()
    private var lostSource = [String: Int64]()
    private var lostDriver = [String: UInt64]()
    private var writeErrors = [String: Int]()
    private var warnings = [String: String]()
    private var previousMetrics = [String: [UInt64]]()
    private var previousClients = [String: [UInt64: [UInt64]]]()
    private var coverage = [String: (firstBucket: Int, latestWrite: Date)]()
    private struct Entry {
        let bytes: Int64
        let modified: Date
    }
    // Only recorder-owned paths relative to the selected directory are in the inventory.
    private var inventory: [String: Entry]?
    private var retainedBytes: Int64 = 0
    private var inventoryGeneration = 0
    private var writesDuringScan: Set<String>?
    private var needsScan = true
    private var lastScan = Date.distantPast
    private var lastPrune = Date.distantPast
    private var pruneCandidates: ArraySlice<(key: String, bucket: Int)>?
    private var lastLimitGB: Int?
    private var directoryEvents: FSEventStreamRef?
    private var lastPerformance = [String: Date]()
    private var lastDriverPerformance = [String: Date]()

    private init() {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Shenglin/Diagnostics", isDirectory: true)
        let configured = MacPreferences.defaults.string(forKey: "diagnosticsDirectory")
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if configured == nil { try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true) }
        directory = (configured ?? fallback).resolvingSymlinksInPath()
        if let saved = MacPreferences.defaults.string(forKey: "diagnosticsVolumeUUID") {
            storageVolumeID = saved.isEmpty ? nil : saved
        } else {
            storageVolumeID = Self.volumeID(at: directory)
            if configured != nil {
                MacPreferences.defaults.set(storageVolumeID ?? "", forKey: "diagnosticsVolumeUUID")
            }
        }
    }

    var location: URL { queue.sync { directory } }
    var limitGB: Int { max(1, MacPreferences.defaults.integer(forKey: "diagnosticsLimitGB") == 0
        ? 40 : MacPreferences.defaults.integer(forKey: "diagnosticsLimitGB")) }

    func setLocation(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        MacPreferences.defaults.set(resolved.path, forKey: "diagnosticsDirectory")
        let volumeID = Self.volumeID(at: resolved)
        MacPreferences.defaults.set(volumeID ?? "", forKey: "diagnosticsVolumeUUID")
        queue.async { self.useLocation(resolved, volumeID: volumeID) }
    }

    private func useLocation(_ url: URL, volumeID: String?) {
        closeHandles()
        stopWatching()
        directory = url
        storageVolumeID = volumeID
        minute.removeAll()
        previousMetrics.removeAll()
        previousClients.removeAll()
        lastPerformance.removeAll()
        lastDriverPerformance.removeAll()
        coverage.removeAll()
        inventory = nil
        inventoryGeneration += 1
        writesDuringScan = nil
        needsScan = true
        lastScan = .distantPast
        lastPrune = .distantPast
        pruneCandidates = nil
        if volumeID != nil {
            for selector in warnings.filter({ $0.value.hasPrefix("诊断写盘失败：") }).keys {
                warnings.removeValue(forKey: selector)
            }
        }
        for device in known.values { writeManifest(device) }
    }

    func setLimitGB(_ value: Int) {
        MacPreferences.defaults.set(max(1, value), forKey: "diagnosticsLimitGB")
    }

    func status(for selector: String) -> ForensicStatus {
        queue.sync {
            let now = Date()
            let retained = coverage[deviceDirectory(selector).lastPathComponent]
            let seconds = retained.map { now.timeIntervalSince($0.latestWrite) < 5
                ? max(0, Int(now.timeIntervalSince1970) - $0.firstBucket * 60) : 0 } ?? 0
            dropLock.lock()
            let pending = pendingSourceDrops[selector] ?? 0
            dropLock.unlock()
            return ForensicStatus(coverageSeconds: seconds,
                droppedSourceBlocks: (lostSource[selector] ?? 0) + pending,
                droppedDriverBlocks: lostDriver[selector] ?? 0,
                writeErrors: writeErrors[selector] ?? 0,
                warning: warnings[selector])
        }
    }

    func recordSource(_ selector: String, sampleRate: Int, channels: Int,
                      hostTime: UInt64, sampleTime: Int64, samples: [Float]) {
        guard sourceSlots.wait(timeout: .now()) == .success else {
            dropLock.lock()
            pendingSourceDrops[selector, default: 0] += 1
            dropLock.unlock()
            return
        }
        let bytes = samples.withUnsafeBytes { Data($0) }
        queue.async {
            defer { self.sourceSlots.signal() }
            self.dropLock.lock()
            let dropped = self.pendingSourceDrops.removeValue(forKey: selector) ?? 0
            self.dropLock.unlock()
            if dropped > 0 {
                self.lostSource[selector, default: 0] += dropped
                self.warnings[selector] = "上游取证队列发生丢弃"
                self.writeEvent(selector, "source-trace-drop", ["blocks": dropped])
            }
            var batch = Data()
            Self.append(UInt32(0x4e415452), to: &batch)
            Self.append(UInt32(1), to: &batch)
            Self.append(UInt64(0), to: &batch)
            Self.append(UInt32(1), to: &batch)
            Self.append(UInt32(0), to: &batch)
            Self.append(UInt64(0), to: &batch)
            Self.append(hostTime, to: &batch)
            Self.append(sampleTime, to: &batch)
            Self.append(UInt32(0), to: &batch)
            Self.append(UInt32(0), to: &batch)
            Self.append(UInt32(sampleRate), to: &batch)
            Self.append(UInt32(channels), to: &batch)
            Self.append(UInt32(samples.count / channels), to: &batch)
            Self.append(UInt32(0), to: &batch)
            batch.append(bytes)
            self.write(batch, selector: selector, stream: "upstream")
        }
    }

    func poll(_ devices: [DedicatedMicrophone], ids: [String: AudioObjectID]) {
        guard pollSlot.wait(timeout: .now()) == .success else { return }
        queue.async {
            defer { self.pollSlot.signal() }
            let defaults = MacPreferences.defaults
            if let path = defaults.string(forKey: "diagnosticsDirectory") {
                let volumeID = defaults.string(forKey: "diagnosticsVolumeUUID").flatMap { $0.isEmpty ? nil : $0 }
                if path != self.directory.path || volumeID != self.storageVolumeID {
                    self.useLocation(URL(fileURLWithPath: path, isDirectory: true), volumeID: volumeID)
                }
            }
            self.observeConfiguration(devices)
            for device in devices {
                guard let id = ids[device.selector] else { continue }
                self.drain(id, device: device)
            }
            self.maintainInventory()
        }
    }

    func performance(_ devices: [DedicatedMicrophone], capture: CaptureDiagnostics) {
        queue.async {
            for device in devices {
                guard Date().timeIntervalSince(self.lastPerformance[device.selector] ?? .distantPast) >= 5 else { continue }
                self.lastPerformance[device.selector] = Date()
                self.writeEvent(device.selector, "capture-performance", [
                    "sourceSampleRate": capture.sourceSampleRate ?? 0,
                    "sourceChannels": capture.sourceChannels ?? 0,
                    "directFormat": capture.directFormat,
                    "tappedFrames": capture.tappedFrames,
                    "busyDroppedFrames": capture.busyDroppedFrames,
                    "conversionDroppedFrames": capture.conversionDroppedFrames,
                    "pushFailedFrames": capture.pushFailedFrames,
                    "pushedFrames": capture.pushedFrames])
            }
        }
    }

    func event(_ selector: String, _ kind: String, _ details: [String: Any] = [:]) {
        queue.async { self.writeEvent(selector, kind, details) }
    }

    func mark(_ selector: String) {
        queue.async {
            self.writeEvent(selector, "incident-marked", [:])
        }
    }

    func export(to destination: URL, completion: @escaping (Error?) -> Void) {
        queue.async {
            self.closeHandles()
            do { try self.requireStorage() }
            catch { completion(error); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", self.directory.path, destination.path]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    throw NSError(domain: "Shenglin", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "诊断压缩失败"])
                }
                completion(nil)
            } catch { completion(error) }
        }
    }

    private func observeConfiguration(_ devices: [DedicatedMicrophone]) {
        let current = Dictionary(uniqueKeysWithValues: devices.map { ($0.selector, $0) })
        for (selector, old) in known where current[selector] == nil {
            writeEvent(selector, "device-removed", ["sourceUID": old.sourceUID ?? "system-default"])
        }
        for (selector, device) in current {
            if known[selector] != device {
                writeEvent(selector, known[selector] == nil ? "device-created" : "device-changed",
                    ["sourceUID": device.sourceUID ?? "system-default", "sampleRate": device.outputSampleRate,
                     "channels": device.outputChannels])
                writeManifest(device)
            }
        }
        known = current
    }

    private func drain(_ id: AudioObjectID, device: DedicatedMicrophone) {
        let snapshot = Date().timeIntervalSince(lastDriverPerformance[device.selector] ?? .distantPast) >= 5
        var address = AudioObjectPropertyAddress(mSelector: Self.traceSelector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let data = value?.takeRetainedValue() as Data?, data.count >= 24 else {
            warnings[device.selector] = "无法读取驱动音频取证流"
            return
        }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard magic == 0x4e415452 else {
            warnings[device.selector] = "驱动取证格式不匹配"
            return
        }
        let lost = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
        let blocks = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        if lost > 0 {
            lostDriver[device.selector, default: 0] += lost
            warnings[device.selector] = "驱动取证流有 \(lostDriver[device.selector] ?? 0) 个块被覆盖"
            writeEvent(device.selector, "driver-trace-overrun", ["blocks": lost])
        }
        let expected = data.withUnsafeBytes { bytes -> Int? in
            guard blocks <= (bytes.count - 24) / 48 else { return nil }
            var offset = 24
            for _ in 0..<blocks {
                guard offset + 48 <= bytes.count else { return nil }
                let channels = Int(bytes.loadUnaligned(fromByteOffset: offset + 36, as: UInt32.self))
                let frames = Int(bytes.loadUnaligned(fromByteOffset: offset + 40, as: UInt32.self))
                guard (1...2).contains(channels), (1...2048).contains(frames) else { return nil }
                offset += 48 + frames * channels * MemoryLayout<Float>.size
                guard offset <= bytes.count else { return nil }
            }
            return offset
        }
        if expected == data.count {
            if blocks > 0 { write(data, selector: device.selector, stream: "hal-output") }
        } else {
            warnings[device.selector] = "驱动取证数据不完整"
            writeEvent(device.selector, "driver-trace-invalid", [:])
        }
        var metricsAddress = AudioObjectPropertyAddress(mSelector: Self.metricsSelector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        value = nil
        size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        if AudioObjectGetPropertyData(id, &metricsAddress, 0, nil, &size, &value) == noErr,
           let metrics = value?.takeRetainedValue() as Data?, metrics.count >= 40 {
            let numbers = (0..<5).map { index in
                metrics.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self) }
            }
            if let old = previousMetrics[device.selector] {
                let delta = zip(numbers, old).map { $0.0 >= $0.1 ? $0.0 - $0.1 : 0 }
                if delta[0] + delta[1] + delta[2] + delta[4] > 0 {
                    writeEvent(device.selector, "driver-gap", ["staleFrames": delta[0],
                        "primingFrames": delta[1], "aheadFrames": delta[2], "maxGapFrames": numbers[3],
                        "realignments": delta[4]])
                }
            }
            previousMetrics[device.selector] = numbers
            if snapshot {
                writeEvent(device.selector, "driver-performance", [
                    "staleFrames": numbers[0], "primingFrames": numbers[1],
                    "aheadFrames": numbers[2], "maxGapFrames": numbers[3],
                    "realignments": numbers[4]])
            }
        }
        var clientsAddress = AudioObjectPropertyAddress(mSelector: 0x4e414d43, // NAMC
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        value = nil
        size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        if AudioObjectGetPropertyData(id, &clientsAddress, 0, nil, &size, &value) == noErr,
           let clients = value?.takeRetainedValue() as Data?, clients.count % 56 == 0 {
            var current = [UInt64: [UInt64]]()
            var snapshotClients = [[String: Any]]()
            for offset in stride(from: 0, to: clients.count, by: 56) {
                let fields = (0..<7).map { index in clients.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset + index * 8, as: UInt64.self) } }
                let key = fields[0]
                guard key != 0 else { continue }
                let numbers = Array(fields.dropFirst())
                current[key] = numbers
                if snapshot {
                    snapshotClients.append(["pid": UInt32(truncatingIfNeeded: (key >> 32) &- 1),
                        "clientID": UInt32(truncatingIfNeeded: key),
                        "readFrames": numbers[0], "aheadFrames": numbers[1],
                        "staleFrames": numbers[2], "primingFrames": numbers[3],
                        "blockedFrames": numbers[4], "timestampSkips": numbers[5]])
                }
                if let previous = previousClients[device.selector]?[key] {
                    let delta = zip(numbers, previous).map { $0.0 >= $0.1 ? $0.0 - $0.1 : 0 }
                    if delta[4] + delta[5] > 0 {
                        writeEvent(device.selector, "client-read-anomaly", ["pid": UInt32(truncatingIfNeeded: (key >> 32) &- 1),
                            "clientID": UInt32(truncatingIfNeeded: key), "blockedFrames": delta[4],
                            "timestampSkips": delta[5]])
                    }
                }
            }
            previousClients[device.selector] = current
            if snapshot { writeEvent(device.selector, "client-performance", ["clients": snapshotClients]) }
        }
        if snapshot { lastDriverPerformance[device.selector] = Date() }
    }

    private func writeManifest(_ device: DedicatedMicrophone) {
        let folder = deviceDirectory(device.selector)
        do {
            try requireStorage()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let info: [String: Any] = ["version": 1, "selector": device.selector,
                "sourceUID": device.sourceUID ?? "system-default", "sampleRate": device.outputSampleRate,
                "channels": device.outputChannels, "encoding": "interleaved Float32 little-endian",
                "hostTimeClock": "mach_absolute_time", "hostTimeNumer": timebase.numer,
                "hostTimeDenom": timebase.denom,
                "streams": ["upstream": "AVAudioEngine tap after conversion, before HAL push",
                            "hal-output": "bytes returned by OnReadClientInput, with client PID"]]
            let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            let manifest = folder.appendingPathComponent("manifest.json")
            try data.write(to: manifest, options: .atomic)
            noteWrite(manifest, bytes: data.count, replacing: true)
        } catch { recordError(device.selector, error) }
    }

    private func write(_ data: Data, selector: String, stream: String) {
        let bucket = Int(Date().timeIntervalSince1970 / 60)
        let key = "\(selector)/\(stream)"
        let folder = deviceDirectory(selector).appendingPathComponent("rolling", isDirectory: true)
        let file = folder.appendingPathComponent("\(bucket)-0-\(stream).bin")
        do {
            try requireStorage()
            if minute[key] != bucket {
                handles.removeValue(forKey: key)?.closeFile()
                minute[key] = bucket
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let handle: FileHandle
            if let open = handles[key] { handle = open }
            else {
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                handles[key] = handle
            }
            try handle.write(contentsOf: data)
            noteWrite(file, bytes: data.count)
            if !data.isEmpty {
                let name = deviceDirectory(selector).lastPathComponent
                coverage[name] = (min(coverage[name]?.firstBucket ?? bucket, bucket), Date())
            }
        } catch { recordError(selector, error) }
    }

    private func writeEvent(_ selector: String, _ kind: String, _ details: [String: Any]) {
        let folder = deviceDirectory(selector).appendingPathComponent("rolling", isDirectory: true)
        let bucket = Int(Date().timeIntervalSince1970 / 60)
        let file = folder.appendingPathComponent("\(bucket)-0-events.jsonl")
        do {
            try requireStorage()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let event: [String: Any] = ["wallTime": ISO8601DateFormatter().string(from: Date()),
                "hostTime": mach_absolute_time(), "kind": kind, "details": details]
            var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            data.append(0x0a)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            noteWrite(file, bytes: data.count)
            try handle.close()
        } catch { recordError(selector, error) }
    }

    private func recordError(_ selector: String, _ error: Error) {
        writeErrors[selector, default: 0] += 1
        warnings[selector] = "诊断写盘失败：\(error.localizedDescription)"
    }

    private func deviceDirectory(_ selector: String) -> URL {
        directory.appendingPathComponent(selector.replacingOccurrences(of: ":", with: "-"), isDirectory: true)
    }

    private static func volumeID(at url: URL) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeDirectory else { return nil }
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIdentifierKey, .volumeURLKey])
        if url.path.hasPrefix("/Volumes/"), values?.volume?.path.hasPrefix("/Volumes/") != true { return nil }
        if let uuid = values?.volumeUUIDString { return "uuid:\(uuid)" }
        if let identifier = values?.volumeIdentifier as? Data { return "id:\(identifier.base64EncodedString())" }
        return nil
    }

    private func requireStorage() throws {
        guard let expected = storageVolumeID, Self.volumeID(at: directory) == expected else {
            throw NSError(domain: "Shenglin", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "诊断目录所在磁盘不可用或已更换；请重新选择取证目录"])
        }
    }

    private func closeHandles() {
        for handle in handles.values { try? handle.close() }
        handles.removeAll()
    }

    private static func segment(_ name: Substring) -> (bucket: Int, audio: Bool)? {
        let parts = name.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let bucket = Int(parts[0]), bucket >= 0,
              let index = Int(parts[1]), index >= 0 else { return nil }
        switch parts[2] {
        case "upstream.bin", "hal-output.bin": return (bucket, true)
        case "events.jsonl": return (bucket, false)
        default: return nil
        }
    }

    private static func entry(at url: URL) -> Entry? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return Entry(bytes: metadata.st_size, modified: Date(timeIntervalSince1970:
            Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000))
    }

    private static func scanInventory(in directory: URL) throws -> [String: Entry] {
        let manager = FileManager.default
        let folderKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let folders = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(folderKeys),
                                                      options: [.skipsHiddenFiles])
        var entries = [String: Entry]()
        for folder in folders {
            let properties = try folder.resourceValues(forKeys: folderKeys)
            guard properties.isDirectory == true, properties.isSymbolicLink == false else { continue }
            let name = folder.lastPathComponent
            let manifest = folder.appendingPathComponent("manifest.json")
            guard let metadata = entry(at: manifest), metadata.bytes <= 64 * 1024,
                  let data = try? Data(contentsOf: manifest),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  info["version"] as? Int == 1, info["encoding"] as? String == "interleaved Float32 little-endian",
                  let selector = info["selector"] as? String,
                  selector.replacingOccurrences(of: ":", with: "-") == name else { continue }
            entries["\(name)/manifest.json"] = metadata
            let rolling = folder.appendingPathComponent("rolling", isDirectory: true)
            guard let properties = try? rolling.resourceValues(forKeys: folderKeys),
                  properties.isDirectory == true, properties.isSymbolicLink == false else { continue }
            var failure: Error?
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            let walk = manager.enumerator(at: rolling, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) { _, error in
                failure = error
                return false
            }
            while autoreleasepool(invoking: {
                guard let file = walk?.nextObject() as? URL else { return false }
                let filename = file.lastPathComponent
                if segment(filename[...]) != nil, let info = try? file.resourceValues(forKeys: keys),
                   info.isRegularFile == true, let size = info.fileSize, let modified = info.contentModificationDate {
                    entries["\(name)/rolling/\(filename)"] = Entry(bytes: Int64(size), modified: modified)
                }
                return true
            }) {}
            if let failure { throw failure }
        }
        return entries
    }

    private func noteWrite(_ url: URL, bytes: Int, replacing: Bool = false) {
        guard inventory != nil || writesDuringScan != nil else { return }
        let root = directory.path
        let prefixLength = root.count + (root.hasSuffix("/") ? 0 : 1)
        let key = String(url.path.dropFirst(prefixLength))
        writesDuringScan?.insert(key)
        guard inventory != nil else { return }
        guard let old = inventory?[key], !replacing else {
            if let new = Self.entry(at: url) {
                retainedBytes += new.bytes - (inventory?.updateValue(new, forKey: key)?.bytes ?? 0)
            }
            return
        }
        inventory?[key] = Entry(bytes: old.bytes + Int64(bytes), modified: Date())
        retainedBytes += Int64(bytes)
    }

    private func startWatching() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, { _, context, _, _, _, _ in
            guard let context else { return }
            let recorder = Unmanaged<AudioForensics>.fromOpaque(context).takeUnretainedValue()
            recorder.needsScan = true
            // A deleted or replaced segment can still be open. Reopen by name on the next write.
            recorder.closeHandles()
        }, &context, [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, options) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) { directoryEvents = stream }
        else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func stopWatching() {
        guard let directoryEvents else { return }
        FSEventStreamStop(directoryEvents)
        FSEventStreamInvalidate(directoryEvents)
        FSEventStreamRelease(directoryEvents)
        self.directoryEvents = nil
    }

    private func maintainInventory() {
        let now = Date()
        if directoryEvents == nil && now.timeIntervalSince(lastScan) >= 60 {
            needsScan = true
        }
        if needsScan {
            guard writesDuringScan == nil, now.timeIntervalSince(lastScan) >= 2 else { return }
            lastScan = now
            guard (try? requireStorage()) != nil else { return }
            if directoryEvents == nil { startWatching() }
            needsScan = false
            writesDuringScan = []
            let generation = inventoryGeneration
            let directory = directory
            inventoryQueue.async {
                let entries = try? Self.scanInventory(in: directory)
                self.queue.async { self.acceptInventory(entries, generation: generation) }
            }
            return
        }
        let limit = limitGB
        if lastLimitGB != limit {
            lastLimitGB = limit
            lastPrune = .distantPast
        }
        let maximum = Int64(limit) * 1_000_000_000
        guard writesDuringScan == nil, inventory != nil, retainedBytes > maximum,
              now.timeIntervalSince(lastPrune) >= 60, (try? requireStorage()) != nil else { return }
        lastPrune = now
        prune(to: maximum)
    }

    private func acceptInventory(_ entries: [String: Entry]?, generation: Int) {
        guard generation == inventoryGeneration, let writes = writesDuringScan else { return }
        writesDuringScan = nil
        guard var entries, (try? requireStorage()) != nil else {
            needsScan = true
            return
        }
        for key in writes { entries[key] = Self.entry(at: directory.appendingPathComponent(key)) }
        retainedBytes = entries.values.reduce(0) { $0 + $1.bytes }
        inventory = entries
        pruneCandidates = nil
        rebuildCoverage()
    }

    private func rebuildCoverage() {
        coverage.removeAll()
        guard let inventory else { return }
        for (key, entry) in inventory where entry.bytes > 0 && key.hasSuffix(".bin") {
            guard let slash = key.lastIndex(of: "/"),
                  let segment = Self.segment(key[key.index(after: slash)...]), segment.audio,
                  let separator = key.firstIndex(of: "/") else { continue }
            let folder = String(key[..<separator])
            let previous = coverage[folder]
            coverage[folder] = (min(previous?.firstBucket ?? segment.bucket, segment.bucket),
                max(previous?.latestWrite ?? entry.modified, entry.modified))
        }
    }

    private func prune(to maximum: Int64) {
        if pruneCandidates == nil {
            let bucket = Int(Date().timeIntervalSince1970 / 60)
            let candidates = inventory?.keys.compactMap { key -> (key: String, bucket: Int)? in
                guard let slash = key.lastIndex(of: "/"),
                      let segment = Self.segment(key[key.index(after: slash)...]), segment.bucket < bucket else { return nil }
                return (key, segment.bucket)
            }.sorted { $0.bucket == $1.bucket ? $0.key < $1.key : $0.bucket < $1.bucket } ?? []
            pruneCandidates = candidates[...]
        }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { return }
        defer { close(root) }
        var removedAudio = false
        for _ in 0..<256 where retainedBytes > maximum {
            guard let (key, _) = pruneCandidates?.popFirst() else { break }
            let parts = key.split(separator: "/")
            let device = openat(root, String(parts[0]), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard device >= 0 else { needsScan = true; continue }
            let folder = openat(device, "rolling", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(device)
            guard folder >= 0 else { needsScan = true; continue }
            let name = String(parts[2])
            var metadata = stat()
            if fstatat(folder, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
               (metadata.st_mode & S_IFMT != S_IFREG || metadata.st_size != inventory?[key]?.bytes) {
                close(folder)
                needsScan = true
                break
            }
            let removed = unlinkat(folder, name, 0)
            let failure = errno
            close(folder)
            if removed == 0 || failure == ENOENT {
                retainedBytes -= self.inventory?.removeValue(forKey: key)?.bytes ?? 0
                if key.hasSuffix(".bin") { removedAudio = true }
            } else {
                for selector in known.keys { recordError(selector, POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)) }
            }
        }
        if removedAudio { rebuildCoverage() }
        if retainedBytes <= maximum {
            pruneCandidates = nil
        } else if pruneCandidates?.isEmpty == true {
            pruneCandidates = nil
            for selector in known.keys { warnings[selector] = "诊断存储已达上限；请导出或更换存储位置" }
        } else {
            // Yield to the recording queue between batches.
            lastPrune = .distantPast
        }
    }

    private static func append<T>(_ value: T, to data: inout Data) {
        var value = value
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
