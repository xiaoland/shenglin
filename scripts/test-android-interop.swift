import Foundation

// 测试双方交换真实 SPAKE2 消息，仅输出合成测试密钥的证明。
@main struct AndroidInterop {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, let selectedPlatform = PeerPlatform(rawValue: arguments[2]) else {
            throw PairingError.invalidMessage
        }
        let platform: PeerPlatform? = arguments.count > 3 && arguments[3] == "3" ? nil : selectedPlatform
        let deviceName = ProcessInfo.processInfo.environment["SHENGLIN_TEST_PEER_NAME"] ?? "互操作设备"
        func readFrame() throws -> PairingFrame {
            guard let line = readLine(), line.utf8.count <= 1024 else { throw PairingError.invalidMessage }
            return try JSONDecoder().decode(PairingFrame.self, from: Data(line.utf8))
        }
        func writeFrame(_ frame: PairingFrame) throws {
            FileHandle.standardOutput.write(try JSONEncoder().encode(frame) + Data([10]))
        }
        let key: Data
        let peerPlatform: PeerPlatform?
        if arguments[1] == "initiator" {
            let pairing = try PairingInitiator(code: "004219", initiatorName: deviceName, platform: platform)
            try writeFrame(pairing.startFrame)
            try writeFrame(pairing.receiveOffer(readFrame()))
            key = try pairing.receiveFinish(readFrame())
            peerPlatform = pairing.peerPlatform
        } else if arguments[1] == "responder" {
            let pairing = try PairingResponder(start: readFrame(), code: "004219",
                responderName: deviceName, platform: platform)
            try writeFrame(pairing.offerFrame)
            try writeFrame(pairing.receiveConfirm(readFrame()))
            guard let confirmed = pairing.confirmedKey else { throw PairingError.wrongStep }
            key = confirmed
            peerPlatform = pairing.peerPlatform
        } else { throw PairingError.invalidMessage }
        let state = PeerQuietUpdate(origin: "initiator", revision: 42, quiet: true,
                                    validUntil: 2_000_000_000, targetMilli: 200, key: key)
        let ack = PeerStateAck(origin: "responder", revision: 42, quiet: true,
                               result: "protectedLocal", targetMilli: 200, key: key)
        let serviceID = Data(base64Encoded: Authentication.sign("wifi-service", key: key))!.prefix(8)
        let result = ["result": "ok", "proof": Authentication.sign("interop", key: key),
                      "peerPlatform": peerPlatform?.rawValue ?? "", "stateSignature": state.signature,
                      "ackSignature": ack.signature,
                      "serviceName": "Shenglin-" + serviceID.map { String(format: "%02x", $0) }.joined(),
                      "wifiProof": WiFiProof.sign(role: "initiator",
                          nonce: Data(repeating: 0, count: 16).base64EncodedString(), key: key),
                      "networkMediumWifiProof": NetworkMediumProof.sign(role: "initiator",
                          nonce: Data(repeating: 0, count: 16).base64EncodedString(), medium: .wifi, key: key),
                      "networkMediumEthernetProof": NetworkMediumProof.sign(role: "initiator",
                          nonce: Data(repeating: 0, count: 16).base64EncodedString(), medium: .ethernet, key: key)]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result) + Data([10]))
    }
}
