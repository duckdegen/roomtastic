// SPDX-License-Identifier: MIT
import XCTest
import Network
import Darwin
import CryptoKit
@testable import RoomtasticTransport
import RoomtasticShared

private final class PeerHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var peer: SecurePeer?
    func store(_ peer: SecurePeer) { lock.withLock { self.peer = peer } }
    func cancel() { lock.withLock { peer?.cancel(); peer = nil } }
}
final class TransportTests: XCTestCase {
    private func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.disconnected }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw WireError.disconnected }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard found == 0 else { throw WireError.disconnected }
        return UInt16(bigEndian: address.sin_port)
    }
    func testAuthenticatedPeerExchangesVersionedMessage() async throws {
        let code = try PairingListener.makeCode(host: "127.0.0.1", port: freePort())
        let listener = try PairingListener(code: code)
        let accepted = expectation(description: "Authenticated peer exchanges room output request")
        let serverPeer = PeerHolder()
        listener.onPeer = { peer in
            serverPeer.store(peer)
            peer.onMessage = { message in if case .requestOutputs = message { accepted.fulfill() } }
        }
        let client = try SecurePeer(credentials: PeerCredentials(peerID: code.peerID, host: code.host, port: code.port, secret: code.secret))
        client.onReady = { [weak client] in client?.send(.requestOutputs) }
        listener.onReady = { client.start() }
        listener.onError = { error in XCTFail("Listener: \(error)") }
        client.onError = { error in XCTFail("Client: \(error)") }
        listener.start()
        await fulfillment(of: [accepted], timeout: 10)
        client.cancel(); serverPeer.cancel(); listener.stop()
    }
    func testLargeRoomFrameDoesNotCancelFollowingRequests() async throws {
        let code = try PairingListener.makeCode(host: "127.0.0.1", port: freePort())
        let listener = try PairingListener(code: code)
        let archive = Data(repeating: 0x61, count: 384_000)
        var room = RoomModel(id: UUID(), name: "Large scan", speakers: [], positions: [])
        room.geometry = ScannedGeometry(surfaces: [], capturedAt: Date(), roomPlanArchive: archive)
        let sentRoom = room
        let receivedRoom = expectation(description: "Complete scanned room arrives")
        let followingRequest = expectation(description: "Next frame remains aligned")
        let server = PeerHolder()
        listener.onPeer = { peer in
            server.store(peer)
            peer.onMessage = { message in
                switch message {
                case .room(let decoded):
                    XCTAssertEqual(decoded.geometry?.roomPlanArchive, archive)
                    receivedRoom.fulfill()
                case .requestOutputs: followingRequest.fulfill()
                default: XCTFail("Unexpected message")
                }
            }
            peer.onError = { error in XCTFail("Receiving large frame: \(error)") }
        }
        let client = try SecurePeer(credentials: listener.credentials)
        client.onReady = { [weak client] in
            client?.send(.room(sentRoom))
            client?.send(.requestOutputs)
        }
        client.onError = { error in XCTFail("Sending large frame: \(error)") }
        listener.onReady = { client.start() }
        listener.start()
        await fulfillment(of: [receivedRoom, followingRequest], timeout: 10, enforceOrder: true)
        client.cancel(); server.cancel(); listener.stop()
    }
    func testSavedPeerReconnectsAfterPairingConnectionCloses() async throws {
        let code = try PairingListener.makeCode(host: "127.0.0.1", port: freePort())
        let saved = PeerCredentials(peerID: code.peerID, host: code.host, port: code.port,
                                    secret: try PairingListener.makeCode(host: code.host, port: code.port).secret)
        let initial = try PairingListener(code: code)
        let paired = expectation(description: "Phone receives its permanent reconnect key")
        let firstServer = PeerHolder()
        initial.onPeer = { peer in
            firstServer.store(peer)
            peer.send(.paired(peerID: saved.peerID, reconnectSecret: saved.secret))
        }
        let firstClient = try SecurePeer(credentials: initial.credentials)
        firstClient.onMessage = { message in
            if case .paired = message { paired.fulfill() }
        }
        firstClient.onError = { error in XCTFail("Initial peer: \(error)") }
        initial.onReady = { firstClient.start() }
        initial.onError = { error in XCTFail("Pairing listener: \(error)") }
        initial.start()
        defer { firstClient.cancel(); firstServer.cancel(); initial.stop() }
        await fulfillment(of: [paired], timeout: 10)
        // NWConnection cancellation is asynchronous. The next listener must bind
        // even while the previous authenticated socket still owns the local port.

        let restored = try PairingListener(credentials: saved)
        let restoredServer = PeerHolder()
        restored.onPeer = { peer in
            restoredServer.store(peer)
            peer.onMessage = { [weak peer] message in
                if case .requestOutputs = message { peer?.send(.outputs([])) }
            }
        }
        let listening = expectation(description: "Saved-key listener is ready")
        restored.onReady = { listening.fulfill() }
        restored.onError = { error in XCTFail("Restored listener: \(error)") }
        restored.start()
        defer { restoredServer.cancel(); restored.stop() }
        await fulfillment(of: [listening], timeout: 5)
        for _ in 0..<2 {
            let reconnected = expectation(description: "Saved peer requests outputs without another QR")
            let returningClient = try SecurePeer(credentials: saved)
            returningClient.onReady = { [weak returningClient] in returningClient?.send(.requestOutputs) }
            returningClient.onMessage = { message in
                if case .outputs = message { reconnected.fulfill() }
            }
            returningClient.onError = { error in XCTFail("Saved peer: \(error)") }
            returningClient.start()
            await fulfillment(of: [reconnected], timeout: 10)
            returningClient.cancel()
        }
    }
    func testWrongSecretCannotAuthenticate() async throws {
        let code = try PairingListener.makeCode(host: "127.0.0.1", port: freePort())
        let listener = try PairingListener(code: code)
        let rejected = expectation(description: "Wrong PSK handshake rejected")
        let accepted = expectation(description: "Wrong PSK must never become a peer"); accepted.isInverted = true
        listener.onPeer = { _ in accepted.fulfill() }
        var wrong = code.secret; wrong[0] ^= 0xff
        let client = try SecurePeer(credentials: PeerCredentials(peerID: code.peerID, host: code.host, port: code.port, secret: wrong))
        client.onError = { _ in rejected.fulfill() }
        listener.onReady = { client.start() }
        listener.start()
        // SecurePeer bounds incomplete TLS handshakes at 15 seconds.
        await fulfillment(of: [rejected, accepted], timeout: 18)
        client.cancel(); listener.stop()
    }
    func testOutOfOrderUploadCannotBeReused() throws {
        let receiver = CaptureReceiver(), id = UUID()
        let samples: [Float] = [0.1, -0.1, 0.2]
        let data = samples.withUnsafeBytes { Data($0) }
        let conditions = MeasurementConditions(microphoneID: "test", microphoneOrientation: "fixed", sampleRate: 48000, outputVolume: 0.5, furnitureRevision: "1", ambientNoiseDBFS: -60)
        let metadata = CaptureMetadata(transactionID: UUID(), captureID: id, pointIndex: 0, sampleRate: 48000, sampleCount: samples.count, conditions: conditions, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), retainRaw: false)
        try receiver.begin(metadata)
        XCTAssertThrowsError(try receiver.append(captureID: id, offset: 4, chunk: data))
        XCTAssertThrowsError(try receiver.finish(captureID: id))
        try receiver.begin(metadata); try receiver.append(captureID: id, offset: 0, chunk: data)
        let (_, decoded) = try receiver.finish(captureID: id)
        XCTAssertEqual(decoded, samples)
        XCTAssertThrowsError(try receiver.finish(captureID: id))
    }
}
