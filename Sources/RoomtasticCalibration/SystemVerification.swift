// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import RoomtasticShared

extension CalibrationAnalyzer {
    public static func verify(request r: SystemVerificationRequest) throws -> SystemVerificationResult {
        try validateTarget(r.target)
        guard !r.selectedSpeakerIDs.isEmpty, !r.baselineConfigurationDigest.isEmpty,
              !r.candidateConfigurationDigest.isEmpty,
              r.baselineConfigurationDigest != r.candidateConfigurationDigest,
              r.candidateCreatedAt <= r.now else {
            throw CalibrationError.invalidInput("Verification requires a selected system and distinct baseline/candidate identities")
        }
        let before = try ninePoints(r.before), after = try ninePoints(r.after)
        guard before[0].frequencies == after[0].frequencies,
              before[0].sampleRate == after[0].sampleRate,
              before[0].channelID == after[0].channelID else {
            throw CalibrationError.incomplete("Before/after must measure the same complete-system excitation")
        }
        let evidence = before + after
        guard Set(evidence.map(\.recordingID)).count == 18,
              evidence.allSatisfy({ $0.origin == .liveMicrophone && $0.completeSystem &&
                  $0.activeSpeakerIDs == r.selectedSpeakerIDs && $0.capturedAt <= r.now &&
                  r.now.timeIntervalSince($0.capturedAt) <= 900 }),
              before.allSatisfy({ $0.purpose == .verificationBefore &&
                  $0.configurationDigest == r.baselineConfigurationDigest && $0.capturedAt <= r.candidateCreatedAt &&
                  r.candidateCreatedAt.timeIntervalSince($0.capturedAt) <= 600 }),
              after.allSatisfy({ $0.purpose == .verificationAfter &&
                  $0.configurationDigest == r.candidateConfigurationDigest && $0.capturedAt >= r.candidateCreatedAt }),
              (before.map(\.capturedAt).max() ?? .distantFuture) < (after.map(\.capturedAt).min() ?? .distantPast) else {
            throw CalibrationError.rejected("Verification needs eighteen fresh, distinct, live-microphone captures of every selected speaker; predictions, partial systems and reused evidence are forbidden")
        }
        guard zip(before, after).allSatisfy({ $0.location.distance(to: $1.location) <= HandheldCapturePolicy.matchingPositionToleranceMeters }) else {
            throw CalibrationError.rejected("Return to the same listening positions for the before-and-after sweeps.")
        }
        let frequencies = before[0].frequencies
        let bins = frequencies.indices.filter { frequencies[$0] >= r.target.lowerFrequency &&
            frequencies[$0] <= min(r.target.upperFrequency, frequencies.last! * 0.9) }
        guard bins.count >= 24 else { throw CalibrationError.incomplete("Verification has insufficient target bandwidth") }
        func error(_ magnitude: [Double]) -> Double {
            let response = smooth(normalized(magnitude, frequencies: frequencies), frequencies: frequencies)
            return sqrt(bins.reduce(0.0) { $0 + pow(response[$1] - targetDB(frequencies[$1], target: r.target), 2) } / Double(bins.count))
        }
        let beforeError = error(aggregate(before)), afterError = error(aggregate(after))
        let worstRegression = zip(before, after).map { error($1.magnitudeDB) - error($0.magnitudeDB) }.max() ?? .infinity
        var reasons = [String]()
        if afterError > 6 { reasons.append("Measured aggregate target error exceeds 6 dB RMS") }
        if beforeError > 2 {
            if beforeError - afterError < 0.5 { reasons.append("Measured improvement is less than 0.5 dB RMS") }
        } else if afterError > beforeError + 0.25 {
            reasons.append("Previously flat response worsened by more than 0.25 dB RMS")
        }
        if worstRegression > 1 { reasons.append("At least one listening point worsened by more than 1 dB RMS") }
        let b = smooth(normalized(aggregate(before), frequencies: frequencies), frequencies: frequencies)
        let a = smooth(normalized(aggregate(after), frequencies: frequencies), frequencies: frequencies)
        if bins.contains(where: { abs(a[$0] - targetDB(frequencies[$0], target: r.target)) -
            abs(b[$0] - targetDB(frequencies[$0], target: r.target)) > 4 }) {
            reasons.append("A smoothed frequency region worsened by more than 4 dB")
        }
        return SystemVerificationResult(passed: reasons.isEmpty, reasons: reasons, beforeErrorDB: beforeError,
            afterErrorDB: afterError, worstPointRegressionDB: worstRegression, evidenceRecordingIDs: evidence.map(\.recordingID))
    }
}
