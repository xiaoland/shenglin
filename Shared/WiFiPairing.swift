import Foundation
import Network

private let wifiPairService = "_shenglin-pair4._tcp"
// Discovery identity is local metadata only; pair authentication still uses SPAKE2.
private let localPairAdvertisementID: String = {
    let defaults = UserDefaults.standard
    let key = "shenglin.pairingAdvertisementID"
    if let saved = defaults.string(forKey: key) { return saved }
    let value = UUID().uuidString
    defaults.set(value, forKey: key)
    return value
}()

func isLocalPairAdvertisement(_ metadata: NWBrowser.Result.Metadata, localID: String) -> Bool {
    guard case .bonjour(let record) = metadata else { return false }
    return record.getEntry(for: "instance") == .string(localID)
}

@MainActor private final class PairSocket {
    let connection: NWConnection
    var onReady: () -> Void = {}
    var onFrame: (PairingFrame) -> Void = { _ in }
    var onClose: () -> Void = {}
    private var buffer = Data()
    private var closed = false

    init(_ connection: NWConnection) { self.connection = connection }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                switch state {
                case .ready: self.onReady(); self.read()
                case .failed, .cancelled: self.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ frame: PairingFrame, onComplete: (() -> Void)? = nil) {
        guard var data = try? JSONEncoder().encode(frame), data.count <= 1024 else { close(); return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                if error != nil { self?.close() }
                else { onComplete?() }
            }
        })
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                guard self.buffer.count <= 2048 else { self.close(); return }
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.prefix(upTo: end)
                    self.buffer.removeSubrange(...end)
                    guard line.count <= 1024,
                          let frame = try? JSONDecoder().decode(PairingFrame.self, from: line) else {
                        self.close(); return
                    }
                    self.onFrame(frame)
                }
                if complete || error != nil { self.close() }
                else if !self.closed { self.read() }
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose()
    }
}

@MainActor public final class WiFiPairServer {
    public let code: String
    private let onStatus: (String) -> Void
    private let onComplete: (PairedPeer) throws -> Void
    private let localName: String
    private let platform: PeerPlatform
    private var listener: NWListener?
    private var socket: PairSocket?
    private var responder: PairingResponder?
    private var peerName = "设备"
    private var attempts = 0
    private var timer: Timer?
    private var stopped = false

    public init(localName: String, platform: PeerPlatform, onStatus: @escaping (String) -> Void,
         onComplete: @escaping (PairedPeer) throws -> Void) throws {
        code = try PairingCode.generate()
        self.onStatus = onStatus
        self.onComplete = onComplete
        self.localName = localName
        self.platform = platform
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .other, .loopback]
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: PeerName.display(localName, fallback: platform.displayName), type: wifiPairService,
            txtRecord: NWTXTRecord(["instance": localPairAdvertisementID]))
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.socket == nil else { connection.cancel(); return }
                let socket = PairSocket(connection)
                self.socket = socket
                socket.onFrame = { [weak self] frame in self?.receive(frame) }
                socket.onClose = { [weak self, weak socket] in
                    guard let self, let socket, self.socket === socket else { return }
                    self.socket = nil
                    self.responder = nil
                }
                socket.start()
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready: self.onStatus("正在等待另一台设备输入验证码")
                case .waiting(let error), .failed(let error): self.onStatus("设备配对网络不可用：\(error.localizedDescription)")
                default: break
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.stop()
                self.onStatus("设备配对已超时")
            }
        }
    }

    private func receive(_ frame: PairingFrame) {
        guard let socket, !stopped else { return }
        do {
            if frame.kind == .start {
                guard responder == nil, attempts < 3 else { throw PairingError.wrongStep }
                attempts += 1
                let responder = try PairingResponder(start: frame, code: code,
                    responderName: localName, fallbackName: platform.displayName, platform: platform)
                peerName = PeerName.display(frame.name, fallback: responder.peerPlatform?.displayName ?? "设备")
                self.responder = responder
                socket.send(responder.offerFrame)
            } else if frame.kind == .confirm, let responder {
                let finish = try responder.receiveConfirm(frame)
                guard let key = responder.confirmedKey else { throw PairingError.wrongStep }
                guard let peerPlatform = responder.peerPlatform else { throw PairingError.invalidMessage }
                try onComplete(PairedPeer(key: key, name: peerName, platform: peerPlatform, localRole: .responder, transport: .wifiDirect))
                socket.send(finish) { [weak self] in self?.stop() }
                onStatus("验证码已通过，等待设备连接")
            } else { throw PairingError.wrongStep }
        } catch {
            onStatus("设备配对失败：\(error.localizedDescription)")
            socket.send(PairingFrame(kind: .reject, session: frame.session, version: 4))
            socket.close()
        }
    }

    public func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        socket?.close()
        socket = nil
        listener?.cancel()
        listener = nil
    }
}

public struct NearbyPairingPeer: Identifiable {
    public let id: String
    public let name: String
}

@MainActor public final class WiFiPairClient {
    private let onDevices: ([NearbyPairingPeer]) -> Void
    private let onStatus: (String) -> Void
    private let onReadyForCode: () -> Void
    private let onComplete: (PairedPeer) throws -> Void
    private let localName: String
    private let platform: PeerPlatform
    private var browser: NWBrowser?
    private var endpoints = [String: NWEndpoint]()
    private var socket: PairSocket?
    private var handshake: PairingInitiator?
    private var timer: Timer?
    private var stopped = false

    public init(localName: String, platform: PeerPlatform, onDevices: @escaping ([NearbyPairingPeer]) -> Void, onStatus: @escaping (String) -> Void,
         onReadyForCode: @escaping () -> Void,
         onComplete: @escaping (PairedPeer) throws -> Void) {
        self.onDevices = onDevices
        self.onStatus = onStatus
        self.onReadyForCode = onReadyForCode
        self.onComplete = onComplete
        self.localName = localName
        self.platform = platform
    }

    public func start() {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .other, .loopback]
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: wifiPairService, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.endpoints.removeAll()
                for result in results {
                    guard !isLocalPairAdvertisement(result.metadata, localID: localPairAdvertisementID) else { continue }
                    if case .service(let name, let type, let domain, _) = result.endpoint,
                       let interface = result.interfaces.first(where: { $0.type == .wifi || $0.type == .wiredEthernet }) {
                        self.endpoints[name] = .service(name: name, type: type, domain: domain, interface: interface)
                    }
                }
                self.onDevices(self.endpoints.keys.sorted().map { NearbyPairingPeer(id: $0, name: $0) })
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready: self.onStatus("正在查找附近可配对的设备")
                case .waiting(let error), .failed(let error): self.onStatus("设备发现失败：\(error.localizedDescription)")
                default: break
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.stop()
                self.onStatus("设备配对已超时")
            }
        }
    }

    public func choose(_ id: String) {
        guard let endpoint = endpoints[id], socket == nil, !stopped else { return }
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .other, .loopback]
        parameters.includePeerToPeer = false
        if case .service(_, _, _, let interface) = endpoint { parameters.requiredInterface = interface }
        let socket = PairSocket(NWConnection(to: endpoint, using: parameters))
        self.socket = socket
        socket.onReady = { [weak self] in self?.onReadyForCode() }
        socket.onFrame = { [weak self] frame in self?.receive(frame) }
        socket.onClose = { [weak self] in
            guard let self, !self.stopped else { return }
            self.socket = nil
            self.handshake = nil
            self.onStatus("设备配对连接中断，可重新选择")
        }
        socket.start()
        onStatus("已选择 \(id)，正在连接")
    }

    public func enterCode(_ code: String) throws {
        guard socket != nil, handshake == nil, !stopped else { throw PairingError.wrongStep }
        let handshake = try PairingInitiator(code: code, initiatorName: localName, platform: platform)
        self.handshake = handshake
        socket?.send(handshake.startFrame)
        onStatus("正在验证 设备配对码")
    }

    private func receive(_ frame: PairingFrame) {
        guard let handshake, !stopped else { return }
        do {
            if frame.kind == .offer {
                socket?.send(try handshake.receiveOffer(frame))
            } else if frame.kind == .finish {
                let key = try handshake.receiveFinish(frame)
                guard let peerPlatform = handshake.peerPlatform else { throw PairingError.invalidMessage }
                try onComplete(PairedPeer(key: key, name: handshake.peerName ?? peerPlatform.displayName, platform: peerPlatform, localRole: .initiator, transport: .wifiDirect))
                onStatus("验证码已通过，等待设备连接")
                stop()
            } else if frame.kind == .reject { throw PairingError.wrongCode }
            else { throw PairingError.wrongStep }
        } catch {
            onStatus("设备配对失败：\(error.localizedDescription)")
            stop()
        }
    }

    public func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        browser?.cancel()
        browser = nil
        socket?.close()
        socket = nil
    }
}
