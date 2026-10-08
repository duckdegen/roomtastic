// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import RoomtasticShared

public enum CalibrationError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput(String)
    case rejected(String)
    case incomplete(String)
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let reason), .rejected(let reason), .incomplete(let reason): return reason
        }
    }
}

public enum MeasurementOrigin: String, Codable, Sendable { case liveMicrophone, synthetic, prediction }
public enum MeasurementPurpose: String, Codable, Sendable { case calibration, verificationBefore, verificationAfter }

public struct MeasurementLocation: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    func distance(to other: Self) -> Double { sqrt(pow(x-other.x, 2) + pow(y-other.y, 2) + pow(z-other.z, 2)) }
}

/// Immutable reference-routed playback. Play both markers on one fixed reference output and
/// `reference` at `sweepStart` on the target output. Preserve all intervening silence.
public struct CalibrationSweep: Sendable {
    public let sampleRate: Double
    public let samples: [Float]
    public let reference: [Float]
    public let acousticMarker: [Float]
    public let closingAcousticMarker: [Float]
    public let firstMarkerStart: Int
    public let secondMarkerStart: Int
    public let sweepStart: Int
    public let lowFrequency: Double
    public let highFrequency: Double
    public var duration: Double { Double(samples.count) / sampleRate }
}

/// Routing is explicit: only a complete-system check can address every output.
public struct CalibrationPlaybackRouting: Sendable {
    public let target: ChannelConnection
    public let mode: SweepSignalMode
    public let referenceConnection: ChannelConnection
    public init(target: ChannelConnection, mode: SweepSignalMode, referenceConnection: ChannelConnection) throws {
        guard !target.outputID.isEmpty, !referenceConnection.outputID.isEmpty,
              (0...1).contains(target.channel), (0...1).contains(referenceConnection.channel) else {
            throw CalibrationError.invalidInput("Choose a valid speaker and channel before measuring.")
        }
        self.target = target; self.mode = mode; self.referenceConnection = referenceConnection
    }
    public func render(_ sweep: CalibrationSweep, from firstFrame: Int, outputID: String, into stereo: UnsafeMutableBufferPointer<Float>) {
        precondition(firstFrame >= 0 && stereo.count.isMultiple(of: 2))
        stereo.update(repeating: 0)
        let count = min(stereo.count / 2, max(0, sweep.samples.count - firstFrame))
        let targetMask: UInt8
        switch mode {
        case .channel: targetMask = outputID == target.outputID ? UInt8(1 << target.channel) : 0
        case .linkedCombined: targetMask = outputID == target.outputID ? 3 : 0
        case .system: targetMask = 3
        }
        let referenceMask: UInt8 = outputID == referenceConnection.outputID ? UInt8(1 << referenceConnection.channel) : 0
        let sweepEnd = sweep.sweepStart + sweep.reference.count
        for frame in 0..<count {
            let index = firstFrame + frame
            let mask = index >= sweep.sweepStart && index < sweepEnd ? targetMask : referenceMask
            let value = sweep.samples[index]
            if mask & 1 != 0 { stereo[frame * 2] = value }
            if mask & 2 != 0 { stereo[frame * 2 + 1] = value }
        }
    }
}

/// The acquisition layer must supply honest hardware provenance and motion/interruption telemetry.
/// Unknown telemetry is rejected, never treated as zero motion. This module never persists PCM.
public struct CalibrationRecording: Sendable {
    public let id: UUID
    public let channelID: String
    public let pointIndex: Int
    public let location: MeasurementLocation
    public let samples: [Float]
    public let sampleRate: Double
    public let origin: MeasurementOrigin
    public let purpose: MeasurementPurpose
    public let capturedAt: Date
    public let configurationDigest: String
    public let activeSpeakerIDs: Set<UUID>
    public let completeSystem: Bool
    public let maximumTranslationMeters: Double?
    public let maximumRotationRadians: Double?
    public let interrupted: Bool
    public init(id: UUID = UUID(), channelID: String, pointIndex: Int, location: MeasurementLocation,
                samples: [Float], sampleRate: Double, origin: MeasurementOrigin, purpose: MeasurementPurpose = .calibration,
                capturedAt: Date = Date(), configurationDigest: String, activeSpeakerIDs: Set<UUID>, completeSystem: Bool = false,
                maximumTranslationMeters: Double?, maximumRotationRadians: Double?, interrupted: Bool) {
        self.id = id; self.channelID = channelID; self.pointIndex = pointIndex; self.location = location
        self.samples = samples; self.sampleRate = sampleRate; self.origin = origin; self.purpose = purpose
        self.capturedAt = capturedAt; self.configurationDigest = configurationDigest; self.activeSpeakerIDs = activeSpeakerIDs
        self.completeSystem = completeSystem; self.maximumTranslationMeters = maximumTranslationMeters
        self.maximumRotationRadians = maximumRotationRadians; self.interrupted = interrupted
    }
}

/// Constructed only by actual numerical analysis, not from caller-supplied predicted responses.
public struct AcousticMeasurement: Sendable {
    public let recordingID: UUID
    public let channelID: String
    public let pointIndex: Int
    public let location: MeasurementLocation
    public let sampleRate: Double
    public let origin: MeasurementOrigin
    public let purpose: MeasurementPurpose
    public let capturedAt: Date
    public let configurationDigest: String
    public let activeSpeakerIDs: Set<UUID>
    public let completeSystem: Bool
    public let arrivalSeconds: Double
    public let clockErrorPPM: Double
    public let signalToNoiseDB: Double
    public let correlation: Double
    public let gainDB: Double
    public let frequencies: [Double]
    public let magnitudeDB: [Double]
}

public struct CorrectionTarget: Codable, Sendable {
    public var bassDB: Double
    public var trebleDB: Double
    public var lowerFrequency: Double
    public var upperFrequency: Double
    public var firLength: Int
    public init(bassDB: Double = 0, trebleDB: Double = 0, lowerFrequency: Double = 30,
                upperFrequency: Double = 16000, firLength: Int = 2049) {
        self.bassDB = bassDB; self.trebleDB = trebleDB; self.lowerFrequency = lowerFrequency
        self.upperFrequency = upperFrequency; self.firLength = firLength
    }
}

public struct ChannelCorrection: Sendable {
    public let channelID: String
    public let sampleRate: Double
    public let fir: [Float]
    /// Causal linear-phase latency; add this to the engine's timing budget, never discard it.
    public let latencySeconds: Double
    public let relativeArrivalSeconds: Double
    public let gainDB: Double
    public let frequencies: [Double]
    public let measuredMagnitudeDB: [Double]
    public let correctionDB: [Double]
    /// Prediction only. This is not verification evidence.
    public let predictedMagnitudeDB: [Double]
}

public struct LinkedStereoCorrection: Sendable {
    public let left: ChannelCorrection
    public let right: ChannelCorrection
    public let commonDelaySeconds: Double
    public let combinedMeasuredMagnitudeDB: [Double]
    public let combinedPredictedMagnitudeDB: [Double]
}

public struct SystemVerificationRequest: Sendable {
    public let selectedSpeakerIDs: Set<UUID>
    public let before: [AcousticMeasurement]
    public let after: [AcousticMeasurement]
    public let baselineConfigurationDigest: String
    public let candidateConfigurationDigest: String
    public let candidateCreatedAt: Date
    public let now: Date
    public let target: CorrectionTarget
    public init(selectedSpeakerIDs: Set<UUID>, before: [AcousticMeasurement], after: [AcousticMeasurement],
                baselineConfigurationDigest: String, candidateConfigurationDigest: String,
                candidateCreatedAt: Date, now: Date = Date(), target: CorrectionTarget = CorrectionTarget()) {
        self.selectedSpeakerIDs = selectedSpeakerIDs; self.before = before; self.after = after
        self.baselineConfigurationDigest = baselineConfigurationDigest; self.candidateConfigurationDigest = candidateConfigurationDigest
        self.candidateCreatedAt = candidateCreatedAt; self.now = now; self.target = target
    }
}

/// A failed result never authorizes replacing an existing profile. No profile is mutated here.
public struct SystemVerificationResult: Sendable {
    public let passed: Bool
    public let reasons: [String]
    public let beforeErrorDB: Double
    public let afterErrorDB: Double
    public let worstPointRegressionDB: Double
    public let evidenceRecordingIDs: [UUID]
}
