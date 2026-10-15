import Foundation

// 探针必须注入自己的序号，不能写正式 App 的偏好或密钥链。
enum MacCredentials {
    static func nextSequence() -> UInt64 { preconditionFailure("探针遗漏序号注入") }
}

// 隔离测试 peer 使用实际共享传输；quiet/idle 仅模拟需求，不访问本机音频或密钥链。
@MainActor private final class Probe {
    var server: WiFiPairServer?
    var client: WiFiPairClient?
    var ble: BLEClient?
    var enableBLE = false
    var link: WiFiPeer?
    var revision: UInt64 = 0
    var quiet = false
    var timer: Timer?

    func event(_ values: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: values) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }

    func start(platform: PeerPlatform, browse: Bool) throws {
        if browse {
            client = WiFiPairClient(localName: "声邻互操作探针", platform: platform,
                onDevices: { [weak self] peers in self?.event(["devices": peers.map(\.id)]) },
                onStatus: { [weak self] text in self?.event(["status": text]) },
                onReadyForCode: { [weak self] in self?.event(["readyForCode": true]) },
                onComplete: { [weak self] peer in self?.paired(peer) })
            client?.start()
            return
        }
        server = try WiFiPairServer(localName: "声邻互操作探针", platform: platform,
            onStatus: { [weak self] text in self?.event(["status": text]) },
            onComplete: { [weak self] peer in self?.paired(peer) })
        try server!.start()
        event(["code": server!.code, "name": "声邻互操作探针", "platform": platform.rawValue])
    }

    func paired(_ peer: PairedPeer) {
        event(["paired": peer.platform.rawValue])
        let update: () -> PeerQuietUpdate = { [unowned self] in
            revision += 1
            return PeerQuietUpdate(origin: peer.localRole.rawValue, revision: revision,
                quiet: quiet, validUntil: Int64(Date().timeIntervalSince1970) + 20, key: peer.key)
        }
        link = WiFiPeer(localOrigin: peer.localRole.rawValue,
            remoteOrigin: peer.localRole.remote.rawValue, listens: peer.localRole == .initiator,
            key: peer.key, localUpdate: update, localName: { "声邻互操作探针" }, receiveName: { [weak self] _ in
                self?.event(["nameVerified": true])
            }, receiveUpdate: { [weak self] update in
                self?.event(["receivedQuiet": update.quiet, "known": update.known])
                return ("alreadyRestored", nil)
            }, receiveAck: { [weak self] ack in
                self?.event(["ack": ack.result, "quiet": ack.quiet])
            }, verifiedChanged: { [weak self] verified in
                self?.event(["verified": verified])
                if verified {
                    self?.link?.sendCurrentState()
                    if let self, self.enableBLE, self.ble == nil {
                        self.ble = BLEClient(key: peer.key, localRole: peer.localRole,
                            localUpdate: update,
                            onStatus: { [weak self] status in self?.event(["bleStatus": status.text]) },
                            onPeerAck: { [weak self] ack in self?.event(["bleAck": ack.result, "quiet": ack.quiet]) },
                            onPeerState: { [weak self] state, done in
                                self?.event(["bleReceivedQuiet": state.quiet, "known": state.known])
                                done("alreadyRestored")
                            }, onAuthenticated: { [weak self] _ in self?.event(["bleAuthenticated": true]) })
                    }
                }
            }, networkScope: .lan, wifiEvidenceChanged: { [weak self] verified in
                self?.event(["wifiVerified": verified])
            }, onIssue: { [weak self] issue in
                if let issue { self?.event(["issue": issue]) }
            })
        link?.start()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.link?.sendCurrentState() }
        }
    }

    func command(_ value: String) {
        if value.hasPrefix("choose ") { client?.choose(String(value.dropFirst(7))); return }
        if value.hasPrefix("code ") {
            do { try client?.enterCode(String(value.dropFirst(5))) }
            catch { event(["error": error.localizedDescription]) }
            return
        }
        switch value {
        case "quiet": quiet = true; link?.sendCurrentState(); ble?.setDesired(true)
        case "idle": quiet = false; link?.sendCurrentState(); ble?.setDesired(false)
        case "lanoff": link?.stop(); timer?.invalidate(); event(["lanStopped": true])
        case "bleoff": enableBLE = false; ble?.stop(); ble = nil; event(["bleStopped": true])
        case "scope wifi": link?.setNetworkScope(.wifi); event(["networkScope": "wifi"])
        case "scope lan": link?.setNetworkScope(.lan); event(["networkScope": "lan"])
        case "quit": link?.stop(); server?.stop(); client?.stop(); ble?.stop(); exit(0)
        default: event(["error": "输入 quiet、idle、choose 设备名、code 验证码 或 quit"])
        }
    }
}

@main struct AndroidWiFiProbe {
    @MainActor static func main() throws {
        let platform = CommandLine.arguments.dropFirst().first.flatMap(PeerPlatform.init(rawValue:)) ?? .mac
        let probe = Probe()
        probe.enableBLE = CommandLine.arguments.contains("--ble")
        guard !probe.enableBLE || platform == .mac else {
            probe.event(["error": "--ble 使用真实 Mac central，仅支持 mac 平台标签"])
            exit(2)
        }
        try probe.start(platform: platform, browse: CommandLine.arguments.contains("--client"))
        DispatchQueue.global().async {
            while let line = readLine() {
                Task { @MainActor in probe.command(line) }
            }
        }
        RunLoop.main.run()
    }
}
