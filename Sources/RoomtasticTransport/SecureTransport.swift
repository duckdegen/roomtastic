// SPDX-License-Identifier: MIT
import Foundation
import Network
import Security
import RoomtasticShared

public struct PeerCredentials: Codable, Sendable {
    public var peerID: UUID; public var host: String; public var port: UInt16; public var secret: Data
    public init(peerID: UUID, host: String, port: UInt16, secret: Data) { self.peerID = peerID; self.host = host; self.port = port; self.secret = secret }
}
public enum PeerKeychain {
    private static let service = "org.roomtastic.authenticated-peers"
    public static func save(_ credentials: PeerCredentials) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: credentials.peerID.uuidString]
        let data = try JSONEncoder().encode(credentials)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil); guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        } else if result != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }
    public static func load(peerID: UUID) throws -> PeerCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: peerID.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return try JSONDecoder().decode(PeerCredentials.self, from: data)
    }
    public static func remove(peerID: UUID) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: peerID.uuidString] as CFDictionary) }
}
private func parameters(secret: Data, identity: UUID) throws -> NWParameters {
    guard secret.count == 32 else { throw WireError.invalidPairingCode }
    let tls = NWProtocolTLS.Options()
    // Apple TN3213: Network.framework PSK is TLS 1.2 only, not TLS 1.3.
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    let psk = secret.withUnsafeBytes { DispatchData(bytes: $0) }
    let name = Data(identity.uuidString.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, name as __DispatchData)
    // Reject certificate fallback: possession of the QR PSK is the only pairing authority.
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(false) }, DispatchQueue(label: "org.roomtastic.reject-certificate-fallback"))
    sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
    sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
    let result = NWParameters(tls: tls, tcp: NWProtocolTCP.Options()); result.includePeerToPeer = true
    return result
}
public final class SecurePeer: @unchecked Sendable {
    private let handlerLock = NSLock()
    private var messageHandler: (@Sendable (WireMessage) -> Void)?
    private var readyHandler: (@Sendable () -> Void)?
    private var errorHandler: (@Sendable (Error) -> Void)?
    private var pendingMessages: [WireMessage] = []
    public var onMessage: (@Sendable (WireMessage) -> Void)? {
        get { handlerLock.withLock { messageHandler } }
        set {
            handlerLock.withLock { messageHandler = newValue }
            queue.async { [weak self] in
                guard let self, let handler = self.onMessage else { return }
                let messages = self.pendingMessages; self.pendingMessages.removeAll()
                messages.forEach(handler)
            }
        }
    }
    public var onReady: (@Sendable () -> Void)? {
        get { handlerLock.withLock { readyHandler } }
        set { handlerLock.withLock { readyHandler = newValue } }
    }
    public var onError: (@Sendable (Error) -> Void)? {
        get { handlerLock.withLock { errorHandler } }
        set { handlerLock.withLock { errorHandler = newValue } }
    }
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.roomtastic.secure-peer")
    private let peerID: UUID
    private var greeted = false
    private var closed = false
    public init(credentials: PeerCredentials) throws {
        guard let port = NWEndpoint.Port(rawValue: credentials.port) else { throw WireError.invalidPairingCode }
        peerID = credentials.peerID
        let configuration = try parameters(secret: credentials.secret, identity: credentials.peerID)
        #if os(iOS)
        // Do not bind calibration to a temporary USB/developer or peer-to-peer link.
        configuration.requiredInterfaceType = .wifi
        configuration.includePeerToPeer = false
        #endif
        connection = NWConnection(host: NWEndpoint.Host(credentials.host), port: port, using: configuration)
    }
    fileprivate init(connection: NWConnection, peerID: UUID) { self.connection = connection; self.peerID = peerID }
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send(.hello(version: RoomtasticProtocol.version, peerID: self.peerID)) { [weak self] error in if let error { self?.fail(error) } }
                self.readHeader()
            case .failed(let error): self.fail(error)
            case .cancelled: if !self.closed { self.fail(WireError.disconnected) }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in guard let self, !self.greeted, !self.closed else { return }; self.fail(WireError.disconnected) }
    }
    public func cancel() { queue.async { self.closed = true; self.connection.cancel() } }
    public func send(_ message: WireMessage, completion: @escaping @Sendable (Error?) -> Void = { _ in }) {
        do {
            let payload = try JSONEncoder().encode(message)
            guard !payload.isEmpty, payload.count <= RoomtasticProtocol.maxFrameBytes else { throw WireError.invalidFrame }
            var size = UInt32(payload.count).bigEndian
            var frame = withUnsafeBytes(of: &size) { Data($0) }; frame.append(payload)
            connection.send(content: frame, completion: .contentProcessed { error in completion(error) })
        } catch { completion(error) }
    }
    public func send(_ message: WireMessage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(message) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
    }
    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.fail(error); return }
            guard let data, data.count == 4, !complete else { self.fail(WireError.disconnected); return }
            let size = data.reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= RoomtasticProtocol.maxFrameBytes else { self.fail(WireError.invalidFrame); return }
            self.readPayload(size)
        }
    }
    private func readPayload(_ size: Int) {
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.fail(error); return }
            guard let data, data.count == size else { self.fail(WireError.disconnected); return }
            do {
                let message = try JSONDecoder().decode(WireMessage.self, from: data)
                if !self.greeted {
                    guard case .hello(let version, let peerID) = message, version == RoomtasticProtocol.version, peerID == self.peerID else { throw WireError.protocolMismatch }
                    self.greeted = true; self.onReady?()
                } else {
                    if case .hello = message { throw WireError.unexpectedMessage }
                    if case .captureChunk(_, let offset, let bytes) = message { guard offset >= 0, bytes.count <= RoomtasticProtocol.maxChunkBytes else { throw WireError.captureLimit } }
                    if let handler = self.onMessage { handler(message) }
                    else {
                        guard self.pendingMessages.count < 4 else { throw WireError.unexpectedMessage }
                        self.pendingMessages.append(message)
                    }
                }
                if complete { self.fail(WireError.disconnected) } else { self.readHeader() }
            } catch { self.fail(error) }
        }
    }
    private func fail(_ error: Error) { guard !closed else { return }; closed = true; connection.cancel(); onError?(error) }
}
public final class PairingListener: @unchecked Sendable {
    public var onReady: (@Sendable () -> Void)?
    public var onPeer: (@Sendable (SecurePeer) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    public let credentials: PeerCredentials
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.roomtastic.pairing")
    private let expiration: Date?
    private var consumed = false
    private var candidates: [SecurePeer] = []
    public static func makeCode(host: String, port: UInt16) throws -> PairingCode {
        var secret = Data(count: 32)
        let result = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        return PairingCode(host: host, port: port, peerID: UUID(), secret: secret, expiresAt: Date().addingTimeInterval(300))
    }
    public convenience init(code: PairingCode) throws {
        try code.validate(); try self.init(credentials: PeerCredentials(peerID: code.peerID, host: code.host, port: code.port, secret: code.secret), expiration: code.expiresAt)
    }
    public init(credentials: PeerCredentials, expiration: Date? = nil) throws {
        self.credentials = credentials; self.expiration = expiration
        guard let port = NWEndpoint.Port(rawValue: credentials.port) else { throw WireError.invalidPairingCode }
        let configuration = try parameters(secret: credentials.secret, identity: credentials.peerID)
        configuration.allowLocalEndpointReuse = true
        listener = try NWListener(using: configuration, on: port)
    }
    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed(let error): self?.onError?(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.consumed, self.expiration.map({ $0 > Date() }) ?? true, self.candidates.count < 4 else { connection.cancel(); return }
            let peer = SecurePeer(connection: connection, peerID: self.credentials.peerID)
            self.candidates.append(peer)
            peer.onReady = { [weak self, weak peer] in
                guard let self, let peer else { return }
                self.queue.async {
                    guard !self.consumed, self.candidates.contains(where: { $0 === peer }),
                          self.expiration.map({ $0 > Date() }) ?? true else { peer.cancel(); return }
                    // A QR is single-use; a saved-key listener stays available for reconnects.
                    if self.expiration != nil { self.consumed = true; self.listener.cancel() }
                    self.candidates.filter { $0 !== peer }.forEach { $0.cancel() }; self.candidates.removeAll()
                    self.onPeer?(peer)
                }
            }
            peer.onError = { [weak self, weak peer] error in
                guard let self, let peer else { return }
                self.queue.async {
                    guard self.candidates.contains(where: { $0 === peer }) else { return }
                    self.candidates.removeAll { $0 === peer }; self.onError?(error)
                }
            }
            peer.start()
        }
        listener.start(queue: queue)
        if let expiration { queue.asyncAfter(deadline: .now() + max(0, expiration.timeIntervalSinceNow)) { [weak self] in self?.consumed = true; self?.listener.cancel(); self?.candidates.forEach { $0.cancel() }; self?.candidates.removeAll() } }
    }
    public func stop() { queue.async { self.consumed = true; self.listener.cancel(); self.candidates.forEach { $0.cancel() }; self.candidates.removeAll() } }
}
