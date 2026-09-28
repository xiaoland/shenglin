import Darwin
import Foundation

struct ControlRequest: Codable {
    let command: String
    var value: String?
}

struct ControlStatus: Codable {
    struct Device: Codable { let id: UUID; let name: String }
    struct Source: Codable { let selector: String; let name: String; let excluded: Bool; let muted: Bool; let active: Bool; let microphone: String?; let microphoneInUse: Bool }
    let connection: String
    let paired: Bool
    let enabled: Bool
    let inputCount: Int
    let captureDiagnostics: CaptureDiagnostics?
    let ipadBLEVerified: Bool
    let ipadWiFiVerified: Bool
    let ipadSpaceAllowed: Bool
    let macPairedCount: Int
    let macVerifiedCount: Int
    let macSpaceAllowedCount: Int
    let driverInstalling: Bool
    let driverInstallStatus: String
    let inputError: String?
    let lastAction: String
    let lastAckSequence: UInt64?
    let target: Double?
    let loginEnabled: Bool
    let pairingActive: Bool
    let pairingStatus: String
    let pairingAwaitingCode: Bool
    let pairingPadName: String
    let pairingPendingActivation: Bool
    let nearbyPads: [Device]
    let sources: [Source]
    let error: String
}

struct ControlResponse: Codable {
    let ok: Bool
    let message: String?
    let status: ControlStatus?
}

enum ControlIPC {
    static let path = ExclusionStore.url.deletingLastPathComponent().appendingPathComponent("control.sock").path

    static func address() throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "NearbyAudioIPC", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "本机控制路径过长"])
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map(UInt8.init(bitPattern:))) }
        return address
    }

    static func exchange(_ request: ControlRequest) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError("无法创建本机连接") }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw systemError("无法设置本机控制超时")
        }
        var address = try address()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw systemError("菜单栏 App 未运行或本机控制入口不可用") }
        let payload = try JSONEncoder().encode(request) + Data([10])
        try writeAll(payload, to: fd)
        shutdown(fd, SHUT_WR)
        let response = try readLine(from: fd)
        return try JSONDecoder().decode(ControlResponse.self, from: response)
    }

    static func readLine(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 65_536 {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 { throw systemError("读取本机控制消息失败") }
            if count == 0 { break }
            data.append(contentsOf: buffer[..<count])
            if let newline = data.firstIndex(of: 10) { return data[..<newline] }
        }
        throw error("本机控制消息不完整或过长")
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = write(fd, base.advanced(by: sent), bytes.count - sent)
                guard count > 0 else { throw systemError("发送本机控制消息失败") }
                sent += count
            }
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "NearbyAudioIPC", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func systemError(_ message: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(message)：\(String(cString: strerror(code)))"])
    }
}

final class ControlServer {
    private let fd: Int32
    private let source: DispatchSourceRead
    private let handler: @MainActor (ControlRequest) -> ControlResponse

    init(handler: @escaping @MainActor (ControlRequest) -> ControlResponse) throws {
        self.handler = handler
        let directory = URL(fileURLWithPath: ControlIPC.path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard chmod(directory, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = try ControlIPC.address()
        let listening = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listening >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        unlink(ControlIPC.path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listening, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(ControlIPC.path, 0o600) == 0, listen(listening, 8) == 0 else {
            let problem = errno
            close(listening)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(problem))
        }
        fd = listening
        source = DispatchSource.makeReadSource(fileDescriptor: listening, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
    }

    deinit {
        source.cancel()
        close(fd)
        unlink(ControlIPC.path)
    }

    private func acceptConnection() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        DispatchQueue.global(qos: .utility).async { [handler] in
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard let data = try? ControlIPC.readLine(from: client),
                  let request = try? JSONDecoder().decode(ControlRequest.self, from: data) else {
                close(client)
                return
            }
            Task { @MainActor in
                let response = handler(request)
                DispatchQueue.global(qos: .utility).async {
                    defer { close(client) }
                    if let data = try? JSONEncoder().encode(response) {
                        try? ControlIPC.writeAll(data + Data([10]), to: client)
                    }
                }
            }
        }
    }
}
