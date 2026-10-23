import AVFAudio
import Foundation
import Network
import UIKit

@MainActor final class MicrophoneSharing {
    private(set) var enabled = false
    private(set) var status = "共享已关闭"
    var capturing: Bool { capture != nil }
    var changed: () -> Void = {}
    var beforeCapture: () throws -> Void = {}
    var sessionRouteChanged: () -> Void = {}
    private var peers = [String: PairedPeer]()
    private var listeners = [String: NWListener]()
    private struct Client { let peerID: String; let wire: PeerMicrophoneConnection }
    private var clients = [UUID: Client]()
    private var capture: MicrophoneCapture?
    private var captureID: UUID?
    private var notifications = [NSObjectProtocol]()
    private var permissionRequest = 0

    init() {
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            })
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stopCapture(message: "录音已被系统中断，请重新开启共享"); self?.disableAfterInterruption() }
            })
        }
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let capture = self.capture, !capture.routeMatches else { return }
                self.stopCapture(message: "输入路由已变化，请重新开启共享")
                self.disableAfterInterruption()
            }
        })
    }

    func setEnabled(_ value: Bool) {
        permissionRequest += 1
        let request = permissionRequest
        guard value else { enabled = false; stopCapture(); reconcile(); return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.permissionRequest == request else { return }
                self.enabled = granted
                self.reconcile()
                if !granted { self.status = "麦克风权限未授予，请在系统设置中允许"; self.changed() }
            }
        }
    }

    func update(peers: [PairedPeer]) {
        self.peers = Dictionary(uniqueKeysWithValues: peers.filter { $0.microphoneShared == true }.map { (MicrophoneProtocol.peerID($0), $0) })
        for (id, client) in clients where self.peers[client.peerID] == nil {
            client.wire.cancel()
            if id == captureID { stopCapture() }
        }
        reconcile()
    }

    private func disableAfterInterruption() {
        guard enabled else { return }
        enabled = false
        let message = status
        reconcile()
        status = message; changed()
    }

    private func reconcile() {
        let available = enabled && (UIApplication.shared.applicationState == .active || capturing)
        let allowed = available ? Set(peers.keys) : []
        for id in Array(listeners.keys) where !allowed.contains(id) { listeners.removeValue(forKey: id)?.cancel() }
        for (id, client) in clients where !allowed.contains(client.peerID) { client.wire.cancel(); clients.removeValue(forKey: id) }
        for id in allowed where listeners[id] == nil {
            guard let peer = peers[id] else { continue }
            do {
                let parameters = NWParameters.tcp
                parameters.prohibitedInterfaceTypes = [.cellular, .other, .loopback]
                parameters.includePeerToPeer = false
                let listener = try NWListener(using: parameters)
                listener.service = NWListener.Service(name: "\(id)-\(peer.localRole.rawValue)", type: MicrophoneProtocol.service)
                listener.newConnectionHandler = { [weak self] connection in
                    DispatchQueue.main.async { self?.accept(connection, peer: peer) }
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    DispatchQueue.main.async {
                        guard let self, self.listeners[id] === listener else { return }
                        if case .failed(let error) = state {
                            self.listeners.removeValue(forKey: id)?.cancel()
                            self.enabled = false; self.stopCapture()
                            self.reconcile(); self.status = "麦克风服务失败：\(error.localizedDescription)"; self.changed()
                        }
                    }
                }
                listeners[id] = listener
                listener.start(queue: .main)
            } catch { enabled = false; stopCapture(message: "麦克风服务启动失败：\(error.localizedDescription)"); return }
        }
        status = !enabled ? "共享已关闭" : capturing ? "正在共享内置麦克风" :
            !available ? "回到 iPad 后可再次使用" : peers.isEmpty ? "请为接收设备开启麦克风授权" : "等待接收设备使用"
        changed()
    }

    private func accept(_ connection: NWConnection, peer: PairedPeer) {
        let peerID = MicrophoneProtocol.peerID(peer)
        guard enabled, peers[peerID] != nil, clients.count < 8 else { connection.cancel(); return }
        let id = UUID(), wire = PeerMicrophoneConnection()
        clients[id] = Client(peerID: peerID, wire: wire)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                wire.cancel()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.clients.removeValue(forKey: id)
                    if self.captureID == id { self.stopCapture() }
                }
            }
            do {
                try wire.accept(connection, peer: peer)
                let request = try JSONSerialization.jsonObject(with: wire.response()) as? [String: String]
                do {
                    switch request?["operation"] {
                    case "list":
                        try wire.respond(["sources": [["id": "ipad.builtin", "name": "内置麦克风", "sampleRate": 48000, "channels": 1]]])
                    case "stream":
                        guard request?["sourceID"] == "ipad.builtin" else { throw MicrophoneProtocol.failure("麦克风不存在或未授权") }
                        let samples: MicrophoneSamples = try DispatchQueue.main.sync {
                            guard let self, self.enabled, self.clients[id] != nil, self.peers[peerID] != nil else { throw MicrophoneProtocol.failure("共享已停止") }
                            guard UIApplication.shared.applicationState == .active else { throw MicrophoneProtocol.failure("请回到 iPad 恢复共享") }
                            guard self.capture == nil else { throw MicrophoneProtocol.failure("内置麦克风正供另一接收设备使用") }
                            try self.beforeCapture()
                            let capture = MicrophoneCapture()
                            self.captureID = id; self.capture = capture; self.changed()
                            do { try capture.start(); self.sessionRouteChanged() }
                            catch { self.stopCapture(); throw error }
                            self.reconcile()
                            return capture.samples
                        }
                        try wire.respond(["sampleRate": 48000, "channels": 1, "encoding": "f32le", "packetFrames": 960])
                        while true { try wire.send(Data([2]) + samples.next()) }
                    default: throw MicrophoneProtocol.failure("不支持的麦克风请求")
                    }
                } catch {
                    try wire.respond(["error": String(error.localizedDescription.prefix(120))])
                }
            } catch { /* Unauthenticated clients and closed connections receive no detail. */ }
        }
    }

    private func stopCapture(message: String? = nil) {
        if let id = captureID { clients[id]?.wire.cancel() }
        if let capture { capture.stop(); sessionRouteChanged() }
        capture = nil; captureID = nil
        reconcile()
        if let message { status = message; changed() }
    }
}

@MainActor private final class MicrophoneCapture {
    let samples = MicrophoneSamples()
    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private var tapped = false
    private var activated = false
    private var inputUID: String?
    var routeMatches: Bool { session.currentRoute.inputs.count == 1 && session.currentRoute.inputs.first?.uid == inputUID }

    func start() throws {
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true); activated = true
        guard let builtin = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { throw MicrophoneProtocol.failure("内置麦克风不可用") }
        try session.setPreferredInput(builtin); inputUID = builtin.uid
        guard routeMatches else { throw MicrophoneProtocol.failure("无法选择内置麦克风") }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: outputFormat) else { throw MicrophoneProtocol.failure("麦克风格式不受支持") }
        let samples = samples
        input.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 48000 / format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { samples.close(); return }
            var supplied = false, error: NSError?
            let result = converter.convert(to: output, error: &error) { _, status in
                guard !supplied else { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard result != .error, let values = output.floatChannelData?[0] else { samples.close(error ?? MicrophoneProtocol.failure("音频转换失败")); return }
            samples.append(Data(bytes: values, count: Int(output.frameLength) * MemoryLayout<Float>.size))
        }
        tapped = true
        try engine.start()
    }
    func stop() {
        samples.close(); engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        if activated {
            do { try session.setActive(false, options: .notifyOthersOnDeactivation) }
            catch { NSLog("Microphone session release: %@", error.localizedDescription) }
            activated = false
        }
    }
}
