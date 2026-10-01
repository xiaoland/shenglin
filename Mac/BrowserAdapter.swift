import AppKit
import Foundation
#if canImport(ShenglinCore)
import ShenglinCore
#endif

struct BrowserPage: Codable {
    let id: String
    let role: String
    let input: String
    let controllable: Bool
}
struct BrowserSnapshot: Codable {
    var connection: String
    let pages: [BrowserPage]
}
struct BrowserReply: Codable {
    let gain: Float
    let leaseSeconds: Int
    let message: String
}

@MainActor final class BrowserAdapter {
    private struct Client { let pages: [BrowserPage]; let expires: TimeInterval }
    private var clients = [String: Client]()
    var pages: [BrowserPage] { clients.values.flatMap(\.pages) }
    var needsQuiet: Bool { pages.contains { $0.role == "conversation" && $0.input == "active" } }
    var known: Bool { !pages.contains { $0.role == "conversation" && $0.input == "unknown" } }
    var summary: String {
        let calls = pages.filter { $0.role == "conversation" }.count
        let background = pages.filter { $0.role == "background" && $0.controllable }.count
        return "\(calls) 个网页保留输出，\(background) 个背景网页可调音" + (known ? "" : "；请在开启 Voice 前调用扩展")
    }
    func expire(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        clients = clients.filter { $0.value.expires > now }
    }
    func accept(_ snapshot: BrowserSnapshot) throws {
        guard UUID(uuidString: snapshot.connection) != nil, snapshot.pages.count <= 64,
              Set(snapshot.pages.map(\.id)).count == snapshot.pages.count,
              snapshot.pages.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 &&
                  ["conversation", "background"].contains($0.role) &&
                  ["active", "idle", "unknown"].contains($0.input) &&
                  ($0.role != "background" || $0.input == "idle") }) else {
            throw NSError(domain: "ShenglinBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "网页状态无效或超过 64 页上限"])
        }
        expire()
        guard clients[snapshot.connection] != nil || clients.count < 16 else {
            throw NSError(domain: "ShenglinBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "浏览器连接数量超过上限"])
        }
        clients[snapshot.connection] = Client(pages: snapshot.pages, expires: ProcessInfo.processInfo.systemUptime + 5)
    }
}

enum BrowserNativeHost {
    static let name = "local.shenglin.browser"
    // Fixed public manifest key binds Native Messaging to this extension, across browser profiles.
    static let extensionID = "gidpincnbffkmhoeadfbfhcipbmpakie"

    static func run() -> Never {
        guard CommandLine.arguments.contains("chrome-extension://\(extensionID)/") else { exit(2) }
        let connection = UUID().uuidString
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        do {
            while let prefix = try readExactly(4, from: input, allowEOF: true) {
                let bytes = Array(prefix)
                let length = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                guard length > 0, length <= 32_768, let data = try readExactly(Int(length), from: input) else { exit(2) }
                var snapshot = try JSONDecoder().decode(BrowserSnapshot.self, from: data)
                snapshot.connection = connection
                let response = try ControlIPC.exchange(ControlRequest(command: "browser.state", browser: snapshot))
                let browserResponse = ControlResponse(ok: response.ok && response.browser != nil,
                    message: response.browser == nil ? "请启动支持网页协同的声邻版本" : response.message,
                    status: nil, browser: response.browser)
                let payload = try JSONEncoder().encode(browserResponse)
                guard payload.count <= 32_768 else { exit(2) }
                var size = UInt32(payload.count).littleEndian
                output.write(withUnsafeBytes(of: &size) { Data($0) })
                output.write(payload)
            }
            exit(0)
        } catch {
            // stdout is exclusively the Native Messaging frame stream.
            fputs("声邻浏览器桥接失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    private static func readExactly(_ count: Int, from handle: FileHandle, allowEOF: Bool = false) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else {
                if allowEOF && data.isEmpty { return nil }
                throw NSError(domain: "ShenglinBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "浏览器消息不完整"])
            }
            data.append(next)
        }
        return data
    }

    @MainActor static func install() throws -> URL {
        guard Bundle.main.bundleIdentifier == "local.shenglin.mac", let executable = Bundle.main.executableURL,
              let resource = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
              FileManager.default.fileExists(atPath: resource.appendingPathComponent("manifest.json").path) else {
            throw NSError(domain: "ShenglinBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "请使用已打包的声邻 App 安装浏览器连接"])
        }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        // Chrome launches a native host without custom arguments; a tiny launcher selects this App's host mode.
        let own = support.appendingPathComponent("Shenglin/Browser")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let launcher = own.appendingPathComponent("native-host")
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try Data("#!/bin/sh\nexec \(quoted) --browser-native-host \"$@\"\n".utf8).write(to: launcher, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let manifest: [String: Any] = ["name": name, "description": "声邻本机网页音频协调", "path": launcher.path,
                                     "type": "stdio", "allowed_origins": ["chrome-extension://\(extensionID)/"]]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        for browser in ["Google/Chrome", "Chromium", "net.imput.helium", "Helium"] {
            let directory = support.appendingPathComponent("\(browser)/NativeMessagingHosts")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
        }
        // Copy to a stable user-owned location; App replacement must not invalidate the loaded extension path.
        let extensionFolder = own.appendingPathComponent("extension")
        if FileManager.default.fileExists(atPath: extensionFolder.path) { try FileManager.default.removeItem(at: extensionFolder) }
        try FileManager.default.copyItem(at: resource, to: extensionFolder)
        return extensionFolder
    }
}
