// SPDX-License-Identifier: MIT
import Foundation

public enum RoomtasticProtocol {
    public static let version = 5
    public static let maxFrameBytes = 1_048_576
    public static let maxChunkBytes = 49_152
    public static let maxRecordingBytes = 48_000 * 4 * 30
    public static let maxSessionCaptures = 16_384
}
public struct PairingCode: Codable, Sendable {
    public var version: Int; public var host: String; public var port: UInt16
    public var peerID: UUID; public var secret: Data; public var expiresAt: Date
    public init(host: String, port: UInt16, peerID: UUID, secret: Data, expiresAt: Date) {
        self.version = RoomtasticProtocol.version; self.host = host; self.port = port; self.peerID = peerID; self.secret = secret; self.expiresAt = expiresAt
    }
    public func validate(now: Date = Date()) throws {
        guard version == RoomtasticProtocol.version, secret.count == 32, !host.isEmpty, host.count <= 253, port > 0, expiresAt > now, expiresAt.timeIntervalSince(now) <= 600 else { throw WireError.invalidPairingCode }
    }
    public func encodedString() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    public static func decode(_ text: String) throws -> PairingCode {
        guard text.utf8.count <= 4096 else { throw WireError.invalidPairingCode }
        let result = try JSONDecoder().decode(Self.self, from: Data(text.utf8)); try result.validate(); return result
    }
}
public enum SweepPurpose: String, Codable, Sendable { case calibration, systemBefore, systemAfter }
public enum SweepSignalMode: String, Codable, Sendable { case channel, linkedCombined, system }
/// Advances only after the Mac accepts a capture. Physical moves remain explicit.
public struct CalibrationSequence: Sendable {
    public enum Next: Equatable, Sendable { case channel, position, finished }
    public let signalCount: Int
    public private(set) var pointIndex = 0
    public private(set) var signalIndex = 0
    public private(set) var purpose: SweepPurpose = .calibration
    public private(set) var isComplete = false
    public init(signalCount: Int) { precondition(signalCount > 0); self.signalCount = signalCount }
    public mutating func acceptCapture() -> Next {
        guard !isComplete else { return .finished }
        if purpose == .calibration && signalIndex + 1 < signalCount {
            signalIndex += 1
            return .channel
        }
        signalIndex = 0
        if pointIndex < 8 {
            pointIndex += 1
            return .position
        }
        switch purpose {
        case .calibration: purpose = .systemBefore; pointIndex = 0
        case .systemBefore: purpose = .systemAfter; pointIndex = 0
        case .systemAfter: isComplete = true; return .finished
        }
        return .position
    }
}
public struct SweepRequest: Codable, Sendable {
    public var transactionID: UUID; public var captureID: UUID; public var positionID: UUID
    public var pointIndex: Int; public var connection: ChannelConnection
    public var purpose: SweepPurpose; public var signalMode: SweepSignalMode
    public init(transactionID: UUID, captureID: UUID, positionID: UUID, pointIndex: Int, connection: ChannelConnection, purpose: SweepPurpose = .calibration, signalMode: SweepSignalMode = .channel) {
        self.transactionID = transactionID; self.captureID = captureID; self.positionID = positionID; self.pointIndex = pointIndex; self.connection = connection
        self.purpose = purpose; self.signalMode = signalMode
    }
}
public struct CaptureMetadata: Codable, Sendable {
    public var transactionID: UUID; public var captureID: UUID; public var pointIndex: Int
    public var sampleRate: Double; public var sampleCount: Int; public var conditions: MeasurementConditions
    public var sha256: String; public var retainRaw: Bool
    public var location: Point3; public var motionMaxTranslationMeters: Double; public var motionMaxRotationRadians: Double; public var interrupted: Bool
    public init(transactionID: UUID, captureID: UUID, pointIndex: Int, sampleRate: Double, sampleCount: Int, conditions: MeasurementConditions, sha256: String, retainRaw: Bool, location: Point3 = Point3(x: 0, y: 0, z: 0), motionMaxTranslationMeters: Double = -1, motionMaxRotationRadians: Double = -1, interrupted: Bool = true) {
        self.transactionID = transactionID; self.captureID = captureID; self.pointIndex = pointIndex; self.sampleRate = sampleRate; self.sampleCount = sampleCount; self.conditions = conditions; self.sha256 = sha256; self.retainRaw = retainRaw
        self.location = location; self.motionMaxTranslationMeters = motionMaxTranslationMeters; self.motionMaxRotationRadians = motionMaxRotationRadians; self.interrupted = interrupted
    }
}
public enum WireMessage: Codable, Sendable {
    case hello(version: Int, peerID: UUID)
    case paired(peerID: UUID, reconnectSecret: Data)
    case requestOutputs
    case outputs([AudioOutput])
    case playbackState(masterVolume: Double)
    case setPlaybackVolume(masterVolume: Double)
    case room(RoomModel)
    case sweepRequest(SweepRequest)
    /// Mac agrees to the request; phone starts its microphone before sending captureArmed.
    case sweepReady(captureID: UUID, durationSeconds: Double, outputVolume: Double)
    case captureArmed(captureID: UUID)
    /// Sent after playback has actually completed, not when queued.
    case sweepFinished(captureID: UUID)
    case captureStart(CaptureMetadata)
    /// IEEE-754 Float32 little endian mono PCM; strict contiguous offset.
    case captureChunk(captureID: UUID, offset: Int, bytes: Data)
    case captureEnd(captureID: UUID)
    case progress(transactionID: UUID, fraction: Double, message: String)
    case result(transactionID: UUID, profile: CalibrationProfile)
    case failure(transactionID: UUID?, reason: String)
    case captureRejected(transactionID: UUID, captureID: UUID, reason: String)
    case cancel(transactionID: UUID)
    case pauseCalibration(transactionID: UUID)
    case resumeCalibration(transactionID: UUID)
    case calibrationResumed(transactionID: UUID, available: Bool, acceptedCaptureIDs: [UUID])
    case deleteRetainedRecordings
}
public enum WireError: Error, LocalizedError, Sendable {
    case invalidPairingCode, invalidFrame, protocolMismatch, unexpectedMessage, captureLimit, checksumMismatch, disconnected, verificationRequired
    public var errorDescription: String? {
        switch self {
        case .invalidPairingCode: return "Pairing code is invalid, expired, or incompatible."
        case .invalidFrame: return "Peer sent an invalid or oversized message."
        case .protocolMismatch: return "The Mac and phone protocol versions differ."
        case .unexpectedMessage: return "Calibration messages arrived out of order."
        case .captureLimit: return "Recording exceeded the bounded capture limit."
        case .checksumMismatch: return "Recording integrity check failed."
        case .disconnected: return "The authenticated connection was closed."
        case .verificationRequired: return "The profile has no passing measured verification. Previous settings are unchanged."
        }
    }
}
/// Pure state machine: a rejected transaction never replaces the last verified profile.
public struct CalibrationTransaction: Sendable {
    public enum Phase: String, Sendable { case idle, requesting, recording, uploading, analyzing, complete, failed }
    public private(set) var phase: Phase = .idle
    public private(set) var request: SweepRequest?
    public private(set) var previousProfile: CalibrationProfile?
    public private(set) var acceptedProfile: CalibrationProfile?
    public init(previousProfile: CalibrationProfile? = nil) { self.previousProfile = previousProfile }
    public mutating func begin(_ request: SweepRequest) throws {
        guard phase == .idle || phase == .complete || phase == .failed else { throw WireError.unexpectedMessage }
        guard (0...8).contains(request.pointIndex), request.connection.channel >= 0 else { throw WireError.unexpectedMessage }
        self.request = request; phase = .requesting
    }
    public mutating func ready(captureID: UUID) throws { guard phase == .requesting, request?.captureID == captureID else { throw WireError.unexpectedMessage }; phase = .recording }
    public mutating func upload() throws { guard phase == .recording else { throw WireError.unexpectedMessage }; phase = .uploading }
    public mutating func uploaded() throws { guard phase == .uploading else { throw WireError.unexpectedMessage }; phase = .analyzing }
    public mutating func accept(transactionID: UUID, profile: CalibrationProfile) throws {
        guard phase == .analyzing, request?.transactionID == transactionID else { throw WireError.unexpectedMessage }
        guard profile.hasMeasuredVerification else { phase = .failed; throw WireError.verificationRequired }
        acceptedProfile = profile; previousProfile = profile; phase = .complete
    }
    public mutating func fail() { phase = .failed; acceptedProfile = nil }
}
