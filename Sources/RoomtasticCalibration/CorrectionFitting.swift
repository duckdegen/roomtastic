// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import RoomtasticShared

extension CalibrationAnalyzer {
    public static func fit(measurements: [AcousticMeasurement], target: CorrectionTarget = CorrectionTarget()) throws -> ChannelCorrection {
        try validateTarget(target)
        let measurements = try ninePoints(measurements)
        let response = aggregate(measurements)
        return try makeCorrection(measurements, response: response, constraints: measurements, target: target)
    }

    /// One common equalizer is fitted against L, R and their actually measured acoustic sum.
    /// Applying the same transfer function to both preserves the measured sum; independent
    /// magnitude-only L/R fits cannot predict interference and are intentionally not used.
    /// A physically linked sub remains part of this acoustic system, never an independent delay.
    public static func fitLinkedStereo(left: [AcousticMeasurement], right: [AcousticMeasurement],
                                       combined: [AcousticMeasurement], target: CorrectionTarget = CorrectionTarget(),
                                       alignmentArrivalSeconds: Double? = nil) throws -> LinkedStereoCorrection {
        try validateTarget(target)
        let l = try ninePoints(left), r = try ninePoints(right), c = try ninePoints(combined)
        guard l[0].channelID != r[0].channelID, l[0].sampleRate == r[0].sampleRate,
              l[0].sampleRate == c[0].sampleRate, l[0].frequencies == r[0].frequencies,
              l[0].frequencies == c[0].frequencies,
              l[0].configurationDigest == r[0].configurationDigest,
              l[0].configurationDigest == c[0].configurationDigest,
              l[0].origin == r[0].origin, l[0].origin == c[0].origin,
              l[0].purpose == r[0].purpose, l[0].purpose == c[0].purpose,
              c[0].activeSpeakerIDs == l[0].activeSpeakerIDs.union(r[0].activeSpeakerIDs),
              zip(l, r).allSatisfy({ $0.location.distance(to: $1.location) <= HandheldCapturePolicy.matchingPositionToleranceMeters }),
              zip(l, c).allSatisfy({ $0.location.distance(to: $1.location) <= HandheldCapturePolicy.matchingPositionToleranceMeters }) else {
            throw CalibrationError.incomplete("Linked measurements must share positions, clock, configuration and the full L/R speaker union")
        }
        let la = normalized(aggregate(l), frequencies: l[0].frequencies)
        let ra = normalized(aggregate(r), frequencies: r[0].frequencies)
        let ca = normalized(aggregate(c), frequencies: c[0].frequencies)
        let joint = la.indices.map { (la[$0] + ra[$0] + ca[$0]) / 3 }
        let shared = try makeCorrection(l, response: joint, constraints: l + r + c, target: target)
        let commonArrival = max(median(l.map(\.arrivalSeconds)), median(r.map(\.arrivalSeconds)))
        let alignment = alignmentArrivalSeconds ?? commonArrival
        guard alignment.isFinite, alignment >= commonArrival, alignment - commonArrival <= 2 else {
            throw CalibrationError.invalidInput("Linked alignment must be a causal common delay of at most two seconds")
        }
        func channel(_ points: [AcousticMeasurement]) -> ChannelCorrection {
            let measured = aggregate(points)
            return ChannelCorrection(channelID: points[0].channelID, sampleRate: shared.sampleRate,
                fir: shared.fir, latencySeconds: shared.latencySeconds, relativeArrivalSeconds: commonArrival,
                gainDB: shared.gainDB, frequencies: shared.frequencies, measuredMagnitudeDB: measured,
                correctionDB: shared.correctionDB, predictedMagnitudeDB: zip(measured, shared.correctionDB).map { $0 + $1 + shared.gainDB })
        }
        return LinkedStereoCorrection(left: channel(l), right: channel(r), commonDelaySeconds: alignment - commonArrival,
            combinedMeasuredMagnitudeDB: aggregate(c), combinedPredictedMagnitudeDB: zip(aggregate(c), shared.correctionDB).map { $0 + $1 + shared.gainDB })
    }

    static func validateTarget(_ target: CorrectionTarget) throws {
        guard [target.bassDB, target.trebleDB, target.lowerFrequency, target.upperFrequency].allSatisfy(\.isFinite),
              (-12...3).contains(target.bassDB), (-12...3).contains(target.trebleDB), target.lowerFrequency >= 20,
              target.upperFrequency > target.lowerFrequency, target.firLength >= 257,
              target.firLength <= 16385, !target.firLength.isMultiple(of: 2) else {
            throw CalibrationError.invalidInput("Target requires finite -12…+3 dB shelves and 257…16385 odd FIR taps")
        }
    }
    static func ninePoints(_ values: [AcousticMeasurement]) throws -> [AcousticMeasurement] {
        guard values.count == 9, Set(values.map(\.pointIndex)) == Set(0...8), Set(values.map(\.recordingID)).count == 9 else {
            throw CalibrationError.incomplete("Exactly one center and eight distinct surrounding captures are required")
        }
        let points = values.sorted { $0.pointIndex < $1.pointIndex }, first = values[0]
        guard values.allSatisfy({ $0.channelID == first.channelID && $0.sampleRate == first.sampleRate &&
            $0.frequencies == first.frequencies && $0.configurationDigest == first.configurationDigest &&
            $0.origin == first.origin && $0.purpose == first.purpose && $0.activeSpeakerIDs == first.activeSpeakerIDs &&
            $0.magnitudeDB.count == first.frequencies.count }) else {
            throw CalibrationError.incomplete("Nine points must belong to the same channel, configuration and capture mode")
        }
        for i in 1..<9 {
            guard (0.06...0.6).contains(points[i].location.distance(to: points[0].location)) else {
                throw CalibrationError.incomplete("Surrounding points must be 6–60 cm from center")
            }
            for j in 0..<i where points[i].location.distance(to: points[j].location) < 0.025 {
                throw CalibrationError.incomplete("Nine-point capture repeats a physical location")
            }
        }
        return points
    }
    static func aggregate(_ points: [AcousticMeasurement]) -> [Double] {
        // Spatial log-magnitude median resists a single local null; center retains a 25% weight.
        points[0].magnitudeDB.indices.map { bin in
            0.75 * median(points.map { $0.magnitudeDB[bin] }) + 0.25 * points[0].magnitudeDB[bin]
        }
    }
    static func normalized(_ response: [Double], frequencies: [Double]) -> [Double] {
        let level = median(zip(frequencies, response).filter { (200...2000).contains($0.0) }.map(\.1))
        return response.map { $0 - level }
    }
    static func targetDB(_ frequency: Double, target: CorrectionTarget) -> Double {
        let bassWeight = max(0, min(1, log2(200 / frequency) / 2))
        let trebleWeight = max(0, min(1, log2(frequency / 2000) / 3))
        return bassWeight * target.bassDB + trebleWeight * target.trebleDB
    }
    static func smooth(_ values: [Double], frequencies: [Double]) -> [Double] {
        frequencies.indices.map { i in
            var sum = 0.0, weight = 0.0
            for j in frequencies.indices {
                let octaves = log2(frequencies[j] / frequencies[i])
                if abs(octaves) <= 0.5 {
                    let w = exp(-0.5 * pow(octaves / (1.0 / 6.0), 2))
                    sum += values[j] * w; weight += w
                }
            }
            return sum / weight
        }
    }
    static func makeCorrection(_ measurements: [AcousticMeasurement], response: [Double],
                               constraints: [AcousticMeasurement], target: CorrectionTarget) throws -> ChannelCorrection {
        let first = measurements[0], frequencies = first.frequencies
        let relative = normalized(response, frequencies: frequencies), smoothed = smooth(relative, frequencies: frequencies)
        let individual = constraints.map { normalized($0.magnitudeDB, frequencies: frequencies) }
        let high = min(target.upperFrequency, frequencies.last! * 0.9)
        guard target.lowerFrequency < high else {
            throw CalibrationError.invalidInput("Target lies outside the measured excitation bandwidth")
        }
        let noBoost = frequencies.indices.map { i -> Double in
            relative[i] < -15 || individual.contains(where: { $0[i] < -18 }) || relative[i] < smoothed[i] - 10 ? 1 : 0
        }
        var curve = frequencies.indices.map { i -> Double in
            let f = frequencies[i]
            guard f >= target.lowerFrequency, f <= high else { return 0 }
            var correction = max(-12, min(3, targetDB(f, target: target) - smoothed[i]))
            // Do not pour power into destructive interference, even if spatial averaging hides it.
            if noBoost[i] > 0 {
                correction = min(0, correction)
            }
            let edge = max(0, min(1, min(log2(f / target.lowerFrequency), log2(high / f)) * 2))
            return correction * edge
        }
        // Interpolate the bounded curve onto a uniform FFT grid. Bartlett windowing has a
        // nonnegative spectral kernel, so interpolation/windowing cannot create >3 dB boosts.
        let count = nextPowerOfTwo(target.firLength * 4), center = (target.firLength - 1) / 2
        var frequencyDomain = Spectrum(real: [Float](repeating: 1, count: count), imag: [Float](repeating: 0, count: count))
        for bin in 0...count/2 {
            let frequency = Double(bin) * first.sampleRate / Double(count)
            let db = interpolate(curve, frequencies: frequencies, at: frequency)
            let amplitude = Float(pow(10, db / 20))
            frequencyDomain.real[bin] = amplitude
            if bin > 0 && bin < count/2 { frequencyDomain.real[count-bin] = amplitude }
        }
        try transform(&frequencyDomain, inverse: true)
        var fir = [Float](repeating: 0, count: target.firLength)
        for offset in 0...center {
            let value = frequencyDomain.real[offset] * Float(1 - Double(offset) / Double(center + 1))
            fir[center + offset] = value; fir[center - offset] = value
        }
        // Windowing can leak a small boost into a forbidden region. An affine transform of
        // the zero-phase response removes that leakage while retaining the -12 dB floor.
        // Scaling taps and adding the intercept at the causal center preserves linear phase.
        var actual = try spectrum(fir, count: count)
        var minimum = Double.infinity, forbiddenMaximum = 0.0
        for bin in 0...count/2 {
            let frequency = Double(bin) * first.sampleRate / Double(count)
            let amplitude = hypot(Double(actual.real[bin]), Double(actual.imag[bin]))
            minimum = min(minimum, amplitude)
            if frequency < target.lowerFrequency || frequency > high ||
                interpolate(noBoost, frequencies: frequencies, at: frequency) > 0 {
                forbiddenMaximum = max(forbiddenMaximum, amplitude)
            }
        }
        if forbiddenMaximum > 1 {
            let floor = pow(10.0, -12.0 / 20.0) + 0.00001
            let scale = min(1, (1 - floor) / max(1e-12, forbiddenMaximum - minimum))
            for index in fir.indices { fir[index] *= Float(scale) }
            fir[center] += Float(1 - scale * forbiddenMaximum)
            actual = try spectrum(fir, count: count)
        }
        // Report the actual finite causal filter, not its ideal requested curve.
        curve = frequencies.map { frequency in
            let bin = min(count/2, max(0, Int((frequency * Double(count) / first.sampleRate).rounded())))
            return 20 * log10(max(1e-12, hypot(Double(actual.real[bin]), Double(actual.imag[bin]))))
        }
        let headroomDB = -20 * log10(max(1, fir.reduce(0.0) { $0 + abs(Double($1)) })) - 0.001
        return ChannelCorrection(channelID: first.channelID, sampleRate: first.sampleRate, fir: fir,
            latencySeconds: Double(center) / first.sampleRate, relativeArrivalSeconds: median(measurements.map(\.arrivalSeconds)),
            gainDB: headroomDB, frequencies: frequencies, measuredMagnitudeDB: response, correctionDB: curve,
            predictedMagnitudeDB: zip(response, curve).map { $0 + $1 + headroomDB })
    }
    static func interpolate(_ values: [Double], frequencies: [Double], at frequency: Double) -> Double {
        guard frequency >= frequencies[0], frequency <= frequencies.last! else { return 0 }
        var upper = 1
        while upper < frequencies.count - 1 && frequencies[upper] < frequency { upper += 1 }
        let weight = log(frequency / frequencies[upper-1]) / log(frequencies[upper] / frequencies[upper-1])
        return values[upper-1] * (1 - weight) + values[upper] * weight
    }
}
