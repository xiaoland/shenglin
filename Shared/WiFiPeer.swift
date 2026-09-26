import Foundation
import Network

public enum WiFiProof {
    public static func sign(role: String, nonce: String, key: Data) -> String {
        Authentication.sign("wifi-proof|\(role)|\(nonce)", key: key)
    }

    public static func valid(_ signature: String, role: String, nonce: String, key: Data) -> Bool {
        Data(base64Encoded: nonce)?.count == 16 &&
        Authentication.matches(signature, expected: sign(role: role, nonce: nonce, key: key))
    }
}

/// One paired Mac/iPad link. Bonjour finds candidates; the pairing key proves identity.
@MainActor final class WiFiPeer {
    enum Role: String { case mac, ipad }

    private struct Frame: Codable {
        enum Kind: String, Codable { case challenge, proof, update, ack }
        let kind: Kind
        var nonce: String? = nil
        var signature: String? = nil
        var update: PeerQuietUpdate? = nil
        var ack: PeerStateAck? = nil
    }

    private static let service = "_nearbyaudio._tcp"
    private let role: Role
    private let key: Data
    private let localUpdate: () -> PeerQuietUpdate
    private let receiveUpdate: (PeerQuietUpdate) -> (String, Int?)
    private let receiveAck: (PeerStateAck) -> Void
    private let verifiedChanged: (Bool) -> Void
    private let onIssue: (String?) -> Void
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints = [NWEndpoint]()
    private var nextEndpoint = 0
    private var connection: NWConnection?
    private var buffer = Data()
    private var nonce: String?
    private var verified = false
    private var lastAckAt = Date.distantPast
    private var pendingRevisions = Set<UInt64>()
    private var timer: Timer?
    private var stopped = false

    init(role: Role, key: Data, localUpdate: @escaping () -> PeerQuietUpdate,
         receiveUpdate: @escaping (PeerQuietUpdate) -> (String, Int?),
         receiveAck: @escaping (PeerStateAck) -> Void = { _ in },
         verifiedChanged: @escaping (Bool) -> Void,
         onIssue: @escaping (String?) -> Void = { _ in }) {
        self.role = role
        self.key = key
        self.localUpdate = localUpdate
        self.receiveUpdate = receiveUpdate
        self.receiveAck = receiveAck
        self.verifiedChanged = verifiedChanged
        self.onIssue = onIssue
    }

    func start() {
        stopped = false
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.includePeerToPeer = false
        if role == .mac {
            do {
                let listener = try NWListener(using: parameters)
                listener.service = NWListener.Service(name: "Nearby Audio", type: Self.service)
                listener.newConnectionHandler = { [weak self] candidate in
                    Task { @MainActor [weak self] in
                        guard let self, !self.stopped else { candidate.cancel(); return }
                        if self.connection != nil { candidate.cancel(); return }
                        self.attach(candidate)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self, !self.stopped else { return }
                        switch state {
                        case .ready: self.onIssue(nil)
                        case .waiting(let error), .failed(let error): self.onIssue(error.localizedDescription)
                        default: break
                        }
                    }
                }
                self.listener = listener
                listener.start(queue: .main)
            } catch { onIssue(error.localizedDescription); return }
        } else {
            let browser = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    self.endpoints = results.map(\.endpoint)
                    self.connectNext()
                }
            }
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    switch state {
                    case .ready: self.onIssue(nil)
                    case .waiting(let error), .failed(let error): self.onIssue(error.localizedDescription)
                    default: break
                    }
                }
            }
            self.browser = browser
            browser.start(queue: .main)
        }
        timer = Timer.scheduledTimer(withTimeInterval: PeerTiming.renewalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if self.verified && Date().timeIntervalSince(self.lastAckAt) >= Double(PeerTiming.leaseSeconds) {
                    self.connection?.cancel()
                } else { self.sendCurrentState() }
            }
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        setVerified(false)
    }

    func sendCurrentState() {
        guard verified, let connection else { return }
        let update = localUpdate()
        pendingRevisions.insert(update.revision)
        if pendingRevisions.count > 8, let oldest = pendingRevisions.min() {
            pendingRevisions.remove(oldest)
        }
        send(Frame(kind: .update, update: update), on: connection)
    }

    private func connectNext() {
        guard !stopped, role == .ipad, connection == nil, !endpoints.isEmpty else { return }
        let endpoint = endpoints[nextEndpoint % endpoints.count]
        nextEndpoint += 1
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.includePeerToPeer = false
        attach(NWConnection(to: endpoint, using: parameters))
    }

    private func attach(_ connection: NWConnection) {
        self.connection = connection
        buffer.removeAll()
        nonce = nil
        pendingRevisions.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection, !self.verified else { return }
            connection.cancel()
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
                    self.send(Frame(kind: .challenge, nonce: self.nonce), on: connection)
                    self.read(connection)
                case .failed, .cancelled:
                    self.detach(connection)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func detach(_ connection: NWConnection) {
        guard self.connection === connection else { return }
        self.connection = nil
        buffer.removeAll()
        nonce = nil
        pendingRevisions.removeAll()
        setVerified(false)
        if role == .ipad && !stopped {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectNext() }
        }
    }

    private func setVerified(_ value: Bool) {
        guard verified != value else { return }
        verified = value
        if value { lastAckAt = Date() }
        verifiedChanged(value)
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak connection] data, _, complete, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                if let data { self.buffer.append(data) }
                guard self.buffer.count <= 2048 else { connection.cancel(); return }
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.prefix(upTo: end)
                    self.buffer.removeSubrange(...end)
                    guard line.count <= 1024, let frame = try? JSONDecoder().decode(Frame.self, from: line),
                          self.handle(frame, on: connection) else { connection.cancel(); return }
                }
                if complete || error != nil { connection.cancel() }
                else { self.read(connection) }
            }
        }
    }

    private func handle(_ frame: Frame, on connection: NWConnection) -> Bool {
        let other: Role = role == .mac ? .ipad : .mac
        switch frame.kind {
        case .challenge:
            guard let nonce = frame.nonce, Data(base64Encoded: nonce)?.count == 16 else { return false }
            send(Frame(kind: .proof, nonce: nonce,
                       signature: WiFiProof.sign(role: role.rawValue, nonce: nonce, key: key)),
                 on: connection)
        case .proof:
            guard let nonce, frame.nonce == nonce, let signature = frame.signature,
                  WiFiProof.valid(signature, role: other.rawValue, nonce: nonce, key: key) else { return false }
            self.nonce = nil
            setVerified(true)
        case .update:
            guard verified, let update = frame.update,
                  update.valid(key: key, expectedOrigin: other.rawValue,
                               now: Int64(Date().timeIntervalSince1970)) else { return false }
            let (result, targetMilli) = receiveUpdate(update)
            send(Frame(kind: .ack, ack: PeerStateAck(origin: role.rawValue,
                 revision: update.revision, quiet: update.quiet, result: result,
                 targetMilli: targetMilli, key: key)), on: connection)
        case .ack:
            guard verified, let ack = frame.ack, ack.valid(key: key, expectedOrigin: other.rawValue),
                  pendingRevisions.remove(ack.revision) != nil else { return false }
            lastAckAt = Date()
            receiveAck(ack)
        }
        return true
    }

    private func send(_ frame: Frame, on connection: NWConnection) {
        guard var data = try? JSONEncoder().encode(frame), data.count <= 1024 else { connection.cancel(); return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }
}
