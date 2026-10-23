import Foundation
import CryptoKit
#if canImport(ShenglinCore)
import ShenglinCore
#endif

enum RemoteMicrophoneMount {
    static func peer(_ id: String) throws -> PairedPeer {
        guard let peer = try MacCredentials.peers().first(where: { MicrophoneProtocol.peerID($0) == id }) else {
            throw MicrophoneProtocol.failure("找不到已配对设备")
        }
        return peer
    }
    static func add(peerID: String, microphone: PeerMicrophone) throws -> DedicatedMicrophone {
        let peer = try peer(peerID)
        guard VirtualMicrophone.pluginID != nil else { throw MicrophoneProtocol.failure("请先安装声邻麦克风驱动") }
        let source = RemoteMicrophoneSource(peerID: peerID, sourceID: microphone.id)
        guard source.valid, microphone.sampleRate == 48000, microphone.channels == 1 else { throw MicrophoneProtocol.failure("远端麦克风配置无效") }
        let digest = SHA256.hash(data: Data("\(peerID)\0\(microphone.id)".utf8)).map { String(format: "%02x", $0) }.joined()
        let device = DedicatedMicrophone(bundle: "remote.\(digest)", name: String("\(peer.name) · \(microphone.name)".prefix(36)),
            sampleRate: 48000, channels: 1, remoteSource: source)
        var devices = try MicrophoneStore.load()
        if let existing = devices.first(where: { $0.remoteSource == source }) { return existing }
        devices.append(device); try MicrophoneStore.save(devices)
        return device
    }
    static func remove(_ selector: String) throws {
        var devices = try MicrophoneStore.load()
        guard let device = devices.first(where: { $0.selector == selector && $0.remoteSource != nil }) else { throw MicrophoneProtocol.failure("远端麦克风不存在") }
        if let id = VirtualMicrophone.deviceID(uid: device.uid), activeInputPIDs(on: id)?.isEmpty != true {
            throw MicrophoneProtocol.failure("请先停止使用远端麦克风，再移除挂载")
        }
        devices.removeAll { $0.selector == selector }; try MicrophoneStore.save(devices)
        try MuteStore.change(selector, add: false)
    }
}
