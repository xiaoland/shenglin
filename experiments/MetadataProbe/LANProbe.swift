import Foundation
import Network
import UIKit
import Darwin

@MainActor final class LANProbe: ObservableObject {
    @Published var status = "网络未启动"
    private var listener: NWListener?
    private var heartbeat: DispatchSourceTimer?
    private var peers: [UUID: NWConnection] = [:]
    private var testing = false
    private let duck = DuckProbe()
    private let token = UUID().uuidString
    func note(_ text: String) {
        FileHandle.standardOutput.write(Data(("LAN \(Date().timeIntervalSince1970) state=\(UIApplication.shared.applicationState.rawValue) \(text)\n").utf8))
    }
    func startHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now()+1, repeating: 1)
        timer.setEventHandler {
            FileHandle.standardOutput.write(Data("HEARTBEAT \(Date().timeIntervalSince1970)\n".utf8))
        }
        heartbeat = timer
        timer.resume()
    }
    func start() {
        guard listener == nil else { return }
        duck.log = { [weak self] text in self?.note(text) }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0 {
            var cursor = interfaces
            while let item = cursor {
                let entry = item.pointee
                if String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr, address.pointee.sa_family == AF_INET {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        note("WIFI_IPV4 \(String(cString: host))")
                    }
                }
                cursor = entry.ifa_next
            }
            freeifaddrs(interfaces)
        }
        do {
            let parameters = NWParameters.udp
            parameters.requiredInterfaceType = .wifi
            let server = try NWListener(using: parameters, on: 49481)
            listener = server
            server.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.status = "Wi-Fi UDP 49481\n令牌：\(self.token)\n\(state)"
                    self.note("LISTENER \(state) token=\(self.token)")
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receive(connection) }
            }
            server.start(queue: .main)
        } catch { note("ERROR \(error)") }
    }
    private func receive(_ connection: NWConnection) {
        guard peers.count < 8 else { connection.cancel(); return }
        let id = UUID()
        peers[id] = connection
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now()+5) { [weak self] in
            connection.cancel(); self?.peers.removeValue(forKey: id)
        }
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, error == nil, let data, data.count <= 192,
                      let command = experimentCommand(data, token: self.token, now: Date().timeIntervalSince1970) else { connection.cancel(); return }
                self.note("RECEIVED \(command)")
                var reply = "pong state=\(UIApplication.shared.applicationState.rawValue)"
                if command == "duck" || command == "hold" {
                    reply = self.duck.start(seconds: command == "duck" ? 3 : 20)
                    self.note(reply)
                } else if command == "stop" {
                    reply = self.duck.stop()
                    self.note(reply)
                } else if command == "volume" {
                    if self.testing { reply = "busy" }
                    else {
                        self.testing = true
                        reply = await testPrivateVolume()
                        self.testing = false
                        self.note(reply)
                    }
                }
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.peers.removeValue(forKey: id)
            }
        }
    }
}
