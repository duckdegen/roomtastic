// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import RoomtasticCalibration

final class CalibrationTests: XCTestCase {
    let speaker = UUID()
    func location(_ point: Int) -> MeasurementLocation {
        if point == 0 { return MeasurementLocation(x: 0, y: 0, z: 0) }
        let angle = Double(point - 1) * .pi / 4
        return MeasurementLocation(x: 0.15 * cos(angle), y: 0, z: 0.15 * sin(angle))
    }
    func capture(_ sweep: CalibrationSweep, delay: Double = 0.025, ppm: Double = 0,
                 noise: Double = 0.000001, clipped: Bool = false, preRoll: Double = 0.4,
                 translation: Double = 0, rotation: Double = 0) -> CalibrationRecording {
        let ratio = 1 + ppm / 1_000_000
        var played = sweep.samples
        for index in sweep.sweepStart..<sweep.sweepStart + sweep.reference.count { played[index] = 0 }
        let targetStart = sweep.sweepStart + Int((delay * sweep.sampleRate).rounded())
        for index in sweep.reference.indices { played[targetStart + index] += sweep.reference[index] }
        let n = Int((sweep.duration * ratio + preRoll + 0.2) * sweep.sampleRate)
        var samples = (0..<n).map { index -> Float in
            let source = (Double(index) / sweep.sampleRate - preRoll) * sweep.sampleRate / ratio
            let floorIndex = Int(floor(source)), fraction = Float(source - floor(source))
            let value: Float = floorIndex >= 0 && floorIndex + 1 < played.count
                ? played[floorIndex] * (1 - fraction) + played[floorIndex + 1] * fraction : 0
            return value * 0.6 + Float(noise * sin(Double(index) * 1.714))
        }
        if clipped { samples[n / 2] = 1 }
        return CalibrationRecording(channelID: "left", pointIndex: 0, location: location(0), samples: samples,
            sampleRate: sweep.sampleRate, origin: .synthetic, configurationDigest: "baseline", activeSpeakerIDs: [speaker],
            maximumTranslationMeters: translation, maximumRotationRadians: rotation, interrupted: false)
    }
    func testKnownDelayAndClockDriftAreRecovered() throws {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 12000, duration: 0.7)
        for ppm in [-800.0, 0, 800] {
            let result = try CalibrationAnalyzer.analyze(recording: capture(sweep, ppm: ppm), sweep: sweep)
            XCTAssertEqual(result.arrivalSeconds, 0.025, accuracy: 0.0003)
            XCTAssertEqual(result.clockErrorPPM, ppm, accuracy: 70)
            XCTAssertGreaterThan(result.signalToNoiseDB, 60)
            XCTAssertEqual(result.gainDB, 20 * log10(0.6), accuracy: 2)
        }
    }
    func testFixedReferenceEliminatesArbitraryCapturePreRoll() throws {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 12000, duration: 0.7)
        let early = try CalibrationAnalyzer.analyze(recording: capture(sweep, delay: -0.15, ppm: 650, preRoll: 0.2), sweep: sweep)
        let late = try CalibrationAnalyzer.analyze(recording: capture(sweep, delay: -0.15, ppm: 650, preRoll: 5.731), sweep: sweep)
        XCTAssertEqual(early.arrivalSeconds, -0.15, accuracy: 0.0003)
        XCTAssertEqual(late.arrivalSeconds, early.arrivalSeconds, accuracy: 0.0003)
        XCTAssertEqual(late.clockErrorPPM, 650, accuracy: 70)
    }
    func testShortGuardRecoversSignedArrivalAndClockDrift() throws {
        // Warm-route minimum, a modest route offset, and a slower output near the
        // analyzer's two-second arrival limit all retain the measured 300 ms margin.
        for delay in [-1.8, -0.15, -0.025, 0.025, 0.15, 1.8] {
            let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 12000, duration: 1,
                                                         guardInterval: max(0.35, abs(delay) + 0.30))
            for ppm in [-800.0, 800] {
                let result = try CalibrationAnalyzer.analyze(recording: capture(sweep, delay: delay, ppm: ppm, preRoll: 0.45), sweep: sweep)
                XCTAssertEqual(result.arrivalSeconds, delay, accuracy: 0.0003)
                XCTAssertEqual(result.clockErrorPPM, ppm, accuracy: 70)
                XCTAssertGreaterThan(result.signalToNoiseDB, 60)
                XCTAssertGreaterThan(result.correlation, 0.9)
                XCTAssertEqual(result.gainDB, 20 * log10(0.6), accuracy: 2)
            }
        }
    }
    func testGuardIntervalRejectsUnsafeOrNonfiniteValues() {
        for interval in [0.349, 4.501, .nan, .infinity] {
            XCTAssertThrowsError(try CalibrationAnalyzer.makeSweep(guardInterval: interval))
        }
    }
    func testShortSweepDoesNotMistakeLateChirpForOpeningReference() throws {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 12000, duration: 1, guardInterval: 0.35)
        let original = capture(sweep, preRoll: 5.4)
        var samples = original.samples
        let late = samples.count - sweep.acousticMarker.count - 8
        for i in sweep.acousticMarker.indices { samples[late + i] = sweep.acousticMarker[i] * 2 }
        let recording = CalibrationRecording(channelID: original.channelID, pointIndex: original.pointIndex,
            location: original.location, samples: samples, sampleRate: original.sampleRate,
            origin: original.origin, configurationDigest: original.configurationDigest,
            activeSpeakerIDs: original.activeSpeakerIDs, maximumTranslationMeters: 0,
            maximumRotationRadians: 0, interrupted: false)
        let result = try CalibrationAnalyzer.analyze(recording: recording, sweep: sweep)
        XCTAssertEqual(result.arrivalSeconds, 0.025, accuracy: 0.0003)
    }
    func testCorrelationAcceptsExactlyOneCompleteCandidate() throws {
        let marker: [Float] = [0, 0.1, -0.4, 0.2, 0]
        let match = try CalibrationAnalyzer.correlate(marker, reference: marker, range: 0...0)
        XCTAssertEqual(match.offset, 0)
        XCTAssertEqual(match.coefficient, 1, accuracy: 0.00001)
    }
    func testExcessiveClockMismatchRejected() throws {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 12000, duration: 0.7)
        XCTAssertThrowsError(try CalibrationAnalyzer.analyze(recording: capture(sweep, ppm: 10000), sweep: sweep))
    }
    func testClippingAndLowSignalNoiseRejected() throws {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 12000, duration: 0.7)
        XCTAssertThrowsError(try CalibrationAnalyzer.analyze(recording: capture(sweep, clipped: true), sweep: sweep))
        XCTAssertThrowsError(try CalibrationAnalyzer.analyze(recording: capture(sweep, noise: 0.15), sweep: sweep))
    }
    func testMissingMotionAndNonfinitePCMRejected() throws {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 12000, duration: 0.7)
        let original = capture(sweep)
        for missingMotion in [true, false] {
            var pcm = original.samples
            if !missingMotion { pcm[100] = .nan }
            let recording = CalibrationRecording(channelID: "left", pointIndex: 0, location: location(0), samples: pcm,
                sampleRate: sweep.sampleRate, origin: .synthetic, configurationDigest: "baseline", activeSpeakerIDs: [speaker],
                maximumTranslationMeters: missingMotion ? nil : 0, maximumRotationRadians: 0, interrupted: false)
            XCTAssertThrowsError(try CalibrationAnalyzer.analyze(recording: recording, sweep: sweep))
        }
    }
    func testHandheldMotionPreservesArrivalButLargeMovementIsRejected() throws {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 12000, duration: 0.7)
        let handheld = try CalibrationAnalyzer.analyze(recording: capture(sweep, translation: 0.06, rotation: 0.2), sweep: sweep)
        XCTAssertEqual(handheld.arrivalSeconds, 0.025, accuracy: 0.0003)
        XCTAssertThrowsError(try CalibrationAnalyzer.analyze(recording: capture(sweep, translation: 0.4), sweep: sweep))
        XCTAssertThrowsError(try CalibrationAnalyzer.analyze(recording: capture(sweep, rotation: 1), sweep: sweep))
    }
    func fixture(_ seed: AcousticMeasurement, point: Int, origin: MeasurementOrigin = .synthetic,
                 purpose: MeasurementPurpose = .calibration, at: Date = Date(), digest: String = "baseline",
                 speakers: Set<UUID>? = nil, system: Bool = false, magnitude: [Double]? = nil, channel: String = "system") -> AcousticMeasurement {
        AcousticMeasurement(recordingID: UUID(), channelID: channel, pointIndex: point, location: location(point),
            sampleRate: seed.sampleRate, origin: origin, purpose: purpose, capturedAt: at,
            configurationDigest: digest, activeSpeakerIDs: speakers ?? [speaker], completeSystem: system,
            arrivalSeconds: seed.arrivalSeconds, clockErrorPPM: seed.clockErrorPPM, signalToNoiseDB: seed.signalToNoiseDB,
            correlation: seed.correlation, gainDB: seed.gainDB, frequencies: seed.frequencies,
            magnitudeDB: magnitude ?? seed.magnitudeDB)
    }
    func seed() throws -> AcousticMeasurement {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 12000, duration: 0.7)
        return try CalibrationAnalyzer.analyze(recording: capture(sweep), sweep: sweep)
    }
    func testFittingRequiresNineDistinctSpatialMeasurements() throws {
        let measurement = try seed()
        XCTAssertThrowsError(try CalibrationAnalyzer.fit(measurements: [measurement]))
        XCTAssertThrowsError(try CalibrationAnalyzer.fit(measurements: Array(repeating: measurement, count: 9)))
    }
    func testRealizedFilterIsCausalBoundedAndDoesNotBoostDeepNull() throws {
        let measurement = try seed()
        let response = measurement.frequencies.map { frequency -> Double in
            if frequency > 300 && frequency < 800 { return -30 }
            return frequency < 200 ? 12 : 0
        }
        let points = (0..<9).map { fixture(measurement, point: $0, magnitude: response) }
        let result = try CalibrationAnalyzer.fit(measurements: points, target: CorrectionTarget(firLength: 2049))
        let actual = try CalibrationAnalyzer.spectrum(result.fir, count: 16384)
        let magnitudes = zip(actual.real, actual.imag).map { 20 * log10(max(1e-12, hypot(Double($0), Double($1)))) }
        XCTAssertLessThanOrEqual(magnitudes.max()!, 3.001)
        XCTAssertGreaterThanOrEqual(magnitudes.min()!, -12.001)
        XCTAssertEqual(result.latencySeconds, 1024 / result.sampleRate, accuracy: 1e-12)
        for index in result.fir.indices { XCTAssertEqual(result.fir[index], result.fir[result.fir.count - 1 - index], accuracy: 1e-7) }
        let nullBin = result.frequencies.indices.min { abs(result.frequencies[$0] - 500) < abs(result.frequencies[$1] - 500) }!
        XCTAssertLessThanOrEqual(result.correctionDB[nullBin], 0.01)
        XCTAssertLessThanOrEqual(pow(10, result.gainDB / 20) * result.fir.reduce(0.0) { $0 + abs(Double($1)) }, 1)
    }
    func testLinkedStereoKeepsCommonFilterAndDelayAcrossBassCancellation() throws {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 12000, duration: 0.7)
        let leftSeed = try CalibrationAnalyzer.analyze(recording: capture(sweep, delay: 0.02), sweep: sweep)
        let rightSeed = try CalibrationAnalyzer.analyze(recording: capture(sweep, delay: 0.04), sweep: sweep)
        let rightSpeaker = UUID()
        let leftResponse = leftSeed.frequencies.map { $0 < 180 ? 8.0 : 0.0 }
        let rightResponse = rightSeed.frequencies.map { $0 < 180 ? -8.0 : 0.0 }
        let combinedResponse = leftSeed.frequencies.map { (60...120).contains($0) ? -30.0 : 0.0 }
        let left = (0..<9).map { fixture(leftSeed, point: $0, magnitude: leftResponse, channel: "left") }
        let right = (0..<9).map { fixture(rightSeed, point: $0, speakers: [rightSpeaker], magnitude: rightResponse, channel: "right") }
        let combined = (0..<9).map { fixture(leftSeed, point: $0, speakers: [speaker, rightSpeaker], magnitude: combinedResponse, channel: "combined") }
        let result = try CalibrationAnalyzer.fitLinkedStereo(left: left, right: right, combined: combined, alignmentArrivalSeconds: 0.15)
        XCTAssertEqual(result.commonDelaySeconds, 0.11, accuracy: 0.001)
        XCTAssertEqual(result.left.fir, result.right.fir, "Independent L/R EQ would change the linked acoustic bass sum")
        XCTAssertEqual(result.left.gainDB, result.right.gainDB, accuracy: 1e-12)
        let bassNull = result.left.frequencies.indices.min { abs(result.left.frequencies[$0] - 90) < abs(result.left.frequencies[$1] - 90) }!
        XCTAssertLessThanOrEqual(result.left.correctionDB[bassNull], 0.01)
        XCTAssertThrowsError(try CalibrationAnalyzer.fitLinkedStereo(left: left, right: right, combined: Array(combined.dropLast())))
    }
    func testVerificationRejectsPredictionPartialAndReusedEvidence() throws {
        let measurement = try seed(), created = Date(), secondSpeaker = UUID()
        for mode in 0..<3 {
            let before = (0..<9).map { fixture(measurement, point: $0, origin: mode == 0 ? .synthetic : .liveMicrophone,
                purpose: .verificationBefore, at: created.addingTimeInterval(-30), speakers: [speaker], system: true) }
            let after = mode == 2 ? before : (0..<9).map { fixture(measurement, point: $0, origin: .liveMicrophone,
                purpose: .verificationAfter, at: created.addingTimeInterval(30), digest: "candidate", speakers: [speaker], system: true) }
            let request = SystemVerificationRequest(selectedSpeakerIDs: mode == 1 ? [speaker, secondSpeaker] : [speaker],
                before: before, after: after, baselineConfigurationDigest: "baseline", candidateConfigurationDigest: "candidate",
                candidateCreatedAt: created, now: created.addingTimeInterval(60))
            XCTAssertThrowsError(try CalibrationAnalyzer.verify(request: request))
        }
    }
    func testMeasuredRegressionCannotAuthorizeProfileReplacement() throws {
        let measurement = try seed(), created = Date()
        let before = (0..<9).map { fixture(measurement, point: $0, origin: .liveMicrophone, purpose: .verificationBefore,
            at: created.addingTimeInterval(-30), system: true, magnitude: measurement.frequencies.map { _ in 0 }) }
        let after = (0..<9).map { fixture(measurement, point: $0, origin: .liveMicrophone, purpose: .verificationAfter,
            at: created.addingTimeInterval(30), digest: "candidate", system: true,
            magnitude: measurement.frequencies.map { $0 < 200 ? 14 : 0 }) }
        let result = try CalibrationAnalyzer.verify(request: SystemVerificationRequest(selectedSpeakerIDs: [speaker],
            before: before, after: after, baselineConfigurationDigest: "baseline", candidateConfigurationDigest: "candidate",
            candidateCreatedAt: created, now: created.addingTimeInterval(60)))
        XCTAssertFalse(result.passed)
        XCTAssertGreaterThan(result.afterErrorDB, result.beforeErrorDB)
        XCTAssertGreaterThan(result.worstPointRegressionDB, 1)
    }
}
