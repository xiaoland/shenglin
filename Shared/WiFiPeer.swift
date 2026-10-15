import Foundation
import Network
#if canImport(ShenglinRust)
import ShenglinRust
#endif

public enum WiFiProof {
    public static func sign(role: String, nonce: String, key: Data) -> String {
        wifiProofSign(role: role, nonce: nonce, key: key)
    }

    public static func valid(_ signature: String, role: String, nonce: String, key: Data) -> Bool {
        wifiProofValid(signature: signature, role: role, nonce: nonce, key: key)
    }
}

public enum NetworkMedium: String, Codable, Sendable {
    case wifi
    case ethernet
}

public enum NetworkMediumProof {
    public static func sign(role: String, nonce: String, medium: NetworkMedium, key: Data) -> String {
        try! networkMediumProofSign(role: role, nonce: nonce, medium: medium.rawValue, key: key)
    }

    public static func valid(_ signature: String, role: String, nonce: String,
                             medium: NetworkMedium, key: Data) -> Bool {
        networkMediumProofValid(signature: signature, role: role, nonce: nonce, medium: medium.rawValue, key: key)
    }
}

/// One paired Mac/iPad link. Bonjour finds candidates; the pairing key proves identity.
@MainActor final class WiFiPeer {
    struct Frame: Codable {
        enum Kind: String, Codable { case challenge, proof, ready, update, ack, name }
        let kind: Kind
        var nonce: String? = nil
        var signature: String? = nil
        var medium: String? = nil
        var mediumSignature: String? = nil
        var update: PeerQuietUpdate? = nil
        var ack: PeerStateAck? = nil
        var name: PeerNameClaim? = nil

        enum CodingKeys: String, CodingKey {
            case kind, nonce, signature, medium, mediumSignature, update, ack, name
        }

        init(kind: Kind, nonce: String? = nil, signature: String? = nil,
             medium: String? = nil, mediumSignature: String? = nil,
             update: PeerQuietUpdate? = nil, ack: PeerStateAck? = nil, name: PeerNameClaim? = nil) {
            self.kind = kind; self.nonce = nonce; self.signature = signature
            self.medium = medium; self.mediumSignature = mediumSignature
            self.update = update; self.ack = ack; self.name = name
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decode(Kind.self, forKey: .kind)
            nonce = try values.decodeIfPresent(String.self, forKey: .nonce)
            signature = try values.decodeIfPresent(String.self, forKey: .signature)
            // Optional evidence must not invalidate an otherwise valid identity proof.
            medium = try? values.decodeIfPresent(String.self, forKey: .medium)
            mediumSignature = try? values.decodeIfPresent(String.self, forKey: .mediumSignature)
            update = try values.decodeIfPresent(PeerQuietUpdate.self, forKey: .update)
            ack = try values.decodeIfPresent(PeerStateAck.self, forKey: .ack)
            name = try values.decodeIfPresent(PeerNameClaim.self, forKey: .name)
        }
    }

    private static let service = "_shenglin._tcp"
    private let localOrigin: String
    private let remoteOrigin: String
    private let listens: Bool
    private let serviceName: String
    private let key: Data
    private let localUpdate: () -> PeerQuietUpdate
    private let localName: () -> String
    private let receiveName: (String) -> Void
    private let receiveUpdate: (PeerQuietUpdate) -> (String, Int?)
    private let receiveAck: (PeerStateAck) -> Void
    private let verifiedChanged: (Bool) -> Void
    private let wifiEvidenceChanged: (Bool) -> Void
    private var networkScope: NetworkScope
    private var localMedium: NetworkMedium?
    private var remoteMedium: NetworkMedium?
    private var wifiEvidence = false
    private let onIssue: (String?) -> Void
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints = [NWEndpoint]()
    private var nextEndpoint = 0
    private var connection: NWConnection?
    private var buffer = Data()
    private var nonce: String?
    private var remoteProven = false
    private var verified = false
    private var lastAckAt = Date.distantPast
    private var pendingRevisions = Set<UInt64>()
    private var lastSentName: String?
    private var timer: Timer?
    private var stopped = false

    init(localOrigin: String, remoteOrigin: String, listens: Bool, key: Data,
         localUpdate: @escaping () -> PeerQuietUpdate,
         localName: @escaping () -> String,
         receiveName: @escaping (String) -> Void,
         receiveUpdate: @escaping (PeerQuietUpdate) -> (String, Int?),
         receiveAck: @escaping (PeerStateAck) -> Void = { _ in },
         verifiedChanged: @escaping (Bool) -> Void,
         networkScope: NetworkScope = .wifi,
         wifiEvidenceChanged: @escaping (Bool) -> Void = { _ in },
         onIssue: @escaping (String?) -> Void = { _ in }) {
        self.localOrigin = localOrigin
        self.remoteOrigin = remoteOrigin
        self.listens = listens
        self.key = key
        self.serviceName = rustServiceName(key)
        self.localUpdate = localUpdate
        self.localName = localName
        self.receiveName = receiveName
        self.receiveUpdate = receiveUpdate
        self.receiveAck = receiveAck
        self.verifiedChanged = verifiedChanged
        self.networkScope = networkScope
        self.wifiEvidenceChanged = wifiEvidenceChanged
        self.onIssue = onIssue
    }

    func start() {
        stopped = false
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .other, .loopback]
        parameters.includePeerToPeer = false
        if listens {
            do {
                let listener = try NWListener(using: parameters)
                listener.service = NWListener.Service(name: serviceName, type: Self.service)
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
                    self.endpoints = results.flatMap { result -> [NWEndpoint] in
                        guard case .service(let name, let type, let domain, _) = result.endpoint,
                              name == self.serviceName else { return [] }
                        return result.interfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }.map {
                            .service(name: name, type: type, domain: domain, interface: $0)
                        }
                    }
                    self.preferWiFiEndpoints()
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

    func setNetworkScope(_ scope: NetworkScope) {
        networkScope = scope
        preferWiFiEndpoints()
        // Keep the authenticated LAN channel for identity and metadata even if it is outside the chosen space.
        if scope == .wifi, localMedium != .wifi,
           endpoints.contains(where: { interfaceType(of: $0) == .wifi }) { connection?.cancel() }
    }

    private func interfaceType(of endpoint: NWEndpoint) -> NWInterface.InterfaceType? {
        if case .service(_, _, _, let interface) = endpoint { return interface?.type }
        return nil
    }

    private func preferWiFiEndpoints() {
        guard networkScope == .wifi else { return }
        endpoints.sort { interfaceType(of: $0) == .wifi && interfaceType(of: $1) != .wifi }
        nextEndpoint = 0
    }

    private func medium(on connection: NWConnection) -> NetworkMedium? {
        guard let path = connection.currentPath else { return nil }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return nil
    }

    private func refreshWiFiEvidence() {
        let value = rustWiFiEvidence(verified, localMedium?.rawValue, remoteMedium?.rawValue, remoteMedium != nil)
        guard value != wifiEvidence else { return }
        wifiEvidence = value
        wifiEvidenceChanged(value)
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
        sendCurrentName(on: connection)
        let update = localUpdate()
        pendingRevisions.insert(update.revision)
        if pendingRevisions.count > 8, let oldest = pendingRevisions.min() {
            pendingRevisions.remove(oldest)
        }
        send(Frame(kind: .update, update: update), on: connection)
    }

    private func sendCurrentName(on connection: NWConnection) {
        let claim = PeerNameClaim(name: localName(), key: key)
        guard claim.name != lastSentName else { return }
        lastSentName = claim.name
        send(Frame(kind: .name, name: claim), on: connection)
    }

    private func connectNext() {
        guard !stopped, !listens, connection == nil, !endpoints.isEmpty else { return }
        let endpoint = endpoints[nextEndpoint % endpoints.count]
        nextEndpoint += 1
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .other, .loopback]
        parameters.includePeerToPeer = false
        // Unscoped Bonjour resolution can follow the default VPN route despite excluded interface types.
        if case .service(_, _, _, let interface) = endpoint { parameters.requiredInterface = interface }
        attach(NWConnection(to: endpoint, using: parameters))
    }

    private func attach(_ connection: NWConnection) {
        self.connection = connection
        buffer.removeAll()
        nonce = nil
        remoteProven = false
        localMedium = nil
        remoteMedium = nil
        pendingRevisions.removeAll()
        lastSentName = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection, !self.verified else { return }
            connection.cancel()
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.localMedium = self.medium(on: connection)
                    self.nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
                    self.send(Frame(kind: .challenge, nonce: self.nonce), on: connection)
                    self.read(connection)
                case .failed, .cancelled:
                    self.detach(connection)
                default: break
                }
            }
        }
        connection.pathUpdateHandler = { [weak self, weak connection] _ in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.connection === connection,
                      self.nonce != nil || self.remoteProven || self.verified else { return }
                // A signed medium describes this connection, never a later route after migration.
                if self.medium(on: connection) != self.localMedium {
                    self.setVerified(false)
                    connection.cancel()
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
        remoteProven = false
        localMedium = nil
        remoteMedium = nil
        pendingRevisions.removeAll()
        lastSentName = nil
        setVerified(false)
        if !listens && !stopped {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectNext() }
        }
    }

    private func setVerified(_ value: Bool) {
        guard verified != value else { return }
        verified = value
        if value { lastAckAt = Date() }
        refreshWiFiEvidence()
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
        switch frame.kind {
        case .challenge:
            guard let nonce = frame.nonce, Data(base64Encoded: nonce)?.count == 16 else { return false }
            send(Frame(kind: .proof, nonce: nonce,
                       signature: WiFiProof.sign(role: localOrigin, nonce: nonce, key: key),
                       medium: localMedium?.rawValue,
                       mediumSignature: localMedium.map { NetworkMediumProof.sign(role: localOrigin, nonce: nonce, medium: $0, key: key) }),
                 on: connection)
        case .proof:
            guard let nonce, frame.nonce == nonce, let signature = frame.signature,
                  WiFiProof.valid(signature, role: remoteOrigin, nonce: nonce, key: key) else { return false }
            remoteMedium = nil
            if let raw = frame.medium, let medium = NetworkMedium(rawValue: raw),
               let signature = frame.mediumSignature,
               NetworkMediumProof.valid(signature, role: remoteOrigin, nonce: nonce, medium: medium, key: key) {
                remoteMedium = medium
            }
            self.nonce = nil
            remoteProven = true
            send(Frame(kind: .ready), on: connection)
        case .ready:
            guard remoteProven else { return false }
            setVerified(true)
            sendCurrentName(on: connection)
        case .name:
            guard verified, let claim = frame.name, claim.valid(key: key) else { return false }
            receiveName(claim.name)
        case .update:
            guard verified, let update = frame.update,
                  update.valid(key: key, expectedOrigin: remoteOrigin,
                               now: Int64(Date().timeIntervalSince1970)) else { return false }
            let (result, targetMilli) = receiveUpdate(update)
            send(Frame(kind: .ack, ack: PeerStateAck(origin: localOrigin,
                 revision: update.revision, quiet: update.quiet, result: result,
                 targetMilli: targetMilli, key: key)), on: connection)
        case .ack:
            guard verified, let ack = frame.ack, ack.valid(key: key, expectedOrigin: remoteOrigin),
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

private func rustServiceName(_ key: Data) -> String { serviceName(key: key) }

private let rustWiFiEvidence = wifiEvidence
