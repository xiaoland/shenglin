import Foundation
import Network
#if canImport(NearbyAudioCore)
import NearbyAudioCore
#endif

private let macPairService = "_nearbyaudio-pair._tcp"

@MainActor private final class PairSocket {
    let connection: NWConnection
    var onReady: () -> Void = {}
    var onFrame: (PairingFrame) -> Void = { _ in }
    var onClose: () -> Void = {}
    private var buffer = Data()
    private var closed = false

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
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

@MainActor final class MacPairServer {
    let code: String
    private let onStatus: (String) -> Void
    private let onComplete: (Data, String) throws -> Void
    private var listener: NWListener?
    private var socket: PairSocket?
    private var responder: PairingResponder?
    private var peerName = "Mac"
    private var attempts = 0
    private var timer: Timer?
    private var stopped = false

    init(onStatus: @escaping (String) -> Void,
         onComplete: @escaping (Data, String) throws -> Void) throws {
        code = try PairingCode.generate()
        self.onStatus = onStatus
        self.onComplete = onComplete
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: PeerName.display(Host.current().localizedName, fallback: "Mac"), type: macPairService)
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
                case .ready: self.onStatus("正在等待另一台 Mac 输入验证码")
                case .waiting(let error), .failed(let error): self.onStatus("Mac 配对网络不可用：\(error.localizedDescription)")
                default: break
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stop()
                self.onStatus("Mac 配对已超时")
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
                    padName: Host.current().localizedName ?? "Mac", fallbackName: "Mac")
                peerName = PeerName.display(frame.name, fallback: "Mac")
                self.responder = responder
                socket.send(responder.offerFrame)
            } else if frame.kind == .confirm, let responder {
                let finish = try responder.receiveConfirm(frame)
                guard let key = responder.confirmedKey else { throw PairingError.wrongStep }
                try onComplete(key, peerName)
                socket.send(finish) { [weak self] in self?.stop() }
                onStatus("Mac 配对完成")
            } else { throw PairingError.wrongStep }
        } catch {
            onStatus("Mac 配对失败：\(error.localizedDescription)")
            socket.send(PairingFrame(kind: .reject, session: frame.session))
            socket.close()
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        socket?.close()
        socket = nil
        listener?.cancel()
        listener = nil
    }
}

struct NearbyMac: Identifiable {
    let id: String
    let name: String
}

@MainActor final class MacPairClient {
    private let onDevices: ([NearbyMac]) -> Void
    private let onStatus: (String) -> Void
    private let onReadyForCode: () -> Void
    private let onComplete: (Data, String) throws -> Void
    private var browser: NWBrowser?
    private var endpoints = [String: NWEndpoint]()
    private var socket: PairSocket?
    private var handshake: PairingInitiator?
    private var timer: Timer?
    private var stopped = false

    init(onDevices: @escaping ([NearbyMac]) -> Void, onStatus: @escaping (String) -> Void,
         onReadyForCode: @escaping () -> Void,
         onComplete: @escaping (Data, String) throws -> Void) {
        self.onDevices = onDevices
        self.onStatus = onStatus
        self.onReadyForCode = onReadyForCode
        self.onComplete = onComplete
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: macPairService, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.endpoints.removeAll()
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint { self.endpoints[name] = result.endpoint }
                }
                self.onDevices(self.endpoints.keys.sorted().map { NearbyMac(id: $0, name: $0) })
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready: self.onStatus("正在查找附近可配对的 Mac")
                case .waiting(let error), .failed(let error): self.onStatus("Mac 发现失败：\(error.localizedDescription)")
                default: break
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onStatus("Mac 配对已超时")
                self?.stop()
            }
        }
    }

    func choose(_ id: String) {
        guard let endpoint = endpoints[id], socket == nil, !stopped else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.includePeerToPeer = false
        let socket = PairSocket(NWConnection(to: endpoint, using: parameters))
        self.socket = socket
        socket.onReady = { [weak self] in self?.onReadyForCode() }
        socket.onFrame = { [weak self] frame in self?.receive(frame) }
        socket.onClose = { [weak self] in
            guard let self, !self.stopped else { return }
            self.socket = nil
            self.handshake = nil
            self.onStatus("Mac 配对连接中断，可重新选择")
        }
        socket.start()
        onStatus("已选择 \(id)，正在连接")
    }

    func enterCode(_ code: String) throws {
        guard socket != nil, handshake == nil, !stopped else { throw PairingError.wrongStep }
        let handshake = try PairingInitiator(code: code, macName: Host.current().localizedName ?? "Mac")
        self.handshake = handshake
        socket?.send(handshake.startFrame)
        onStatus("正在验证 Mac 配对码")
    }

    private func receive(_ frame: PairingFrame) {
        guard let handshake, !stopped else { return }
        do {
            if frame.kind == .offer {
                socket?.send(try handshake.receiveOffer(frame))
            } else if frame.kind == .finish {
                let key = try handshake.receiveFinish(frame)
                try onComplete(key, handshake.peerName ?? "Mac")
                onStatus("Mac 配对完成")
                stop()
            } else if frame.kind == .reject { throw PairingError.wrongCode }
            else { throw PairingError.wrongStep }
        } catch {
            onStatus("Mac 配对失败：\(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        browser?.cancel()
        browser = nil
        socket?.close()
        socket = nil
    }
}
