import AppKit
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
    var id: String { selector }
}

func availableSources() throws -> [SourceCandidate] {
    let excluded = try ExclusionStore.load()
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
    for selector in excluded where rows[selector] == nil {
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
                        isExcluded: excluded.contains(selector))
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func printSources() throws {
    for source in try availableSources() {
        print("\(source.isActive ? "●" : " ") \(source.isExcluded ? "×" : " ") \(source.name)\t\(source.selector)")
    }
    print("● 正在采集输入；× 已排除。使用 nearby-audio exclude add <bundle:标识或path:绝对路径>。")
}
