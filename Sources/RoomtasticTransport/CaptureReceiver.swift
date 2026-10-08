// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import RoomtasticShared

/// One bounded recording in flight. Call only from the owner's serial executor.
public final class CaptureReceiver {
    private var metadata: CaptureMetadata?
    private var bytes = Data()
    public init() {}
    public func begin(_ metadata: CaptureMetadata) throws {
        guard self.metadata == nil, metadata.sampleRate.isFinite, (8_000...192_000).contains(metadata.sampleRate), metadata.sampleCount > 0, metadata.sampleCount <= RoomtasticProtocol.maxRecordingBytes / 4, (0...8).contains(metadata.pointIndex), metadata.sha256.count == 64 else { throw WireError.captureLimit }
        self.metadata = metadata; bytes.reserveCapacity(metadata.sampleCount * 4)
    }
    public func append(captureID: UUID, offset: Int, chunk: Data) throws {
        guard let metadata, metadata.captureID == captureID, offset == bytes.count, !chunk.isEmpty, chunk.count <= RoomtasticProtocol.maxChunkBytes, bytes.count + chunk.count <= metadata.sampleCount * 4 else { reset(); throw WireError.captureLimit }
        bytes.append(chunk)
    }
    public func finish(captureID: UUID) throws -> (CaptureMetadata, [Float]) {
        defer { reset() }
        guard let metadata, metadata.captureID == captureID, bytes.count == metadata.sampleCount * 4 else { throw WireError.unexpectedMessage }
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else { throw WireError.checksumMismatch }
        var samples = [Float](); samples.reserveCapacity(metadata.sampleCount)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let bits = bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            let value = Float(bitPattern: bits); guard value.isFinite else { throw WireError.invalidFrame }; samples.append(value)
        }
        return (metadata, samples)
    }
    public func reset() { bytes.resetBytes(in: 0..<bytes.count); bytes.removeAll(keepingCapacity: false); metadata = nil }
    deinit { reset() }
}
