// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Accelerate
import RoomtasticShared

public enum CalibrationAnalyzer {
    public static func makeSweep(sampleRate: Double = 48000, duration: Double = 2, guardInterval: Double = 2.3) throws -> CalibrationSweep {
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate), duration.isFinite, (0.5...10).contains(duration),
              guardInterval.isFinite, (0.35...4.5).contains(guardInterval) else {
            throw CalibrationError.invalidInput("Sweep requires 8–192 kHz, 0.5–10 seconds, and a 0.35–4.5 second guard interval")
        }
        let low = 20.0, high = min(20000, sampleRate * 0.42)
        func chirp(_ seconds: Double, _ from: Double, _ to: Double, _ amplitude: Double) -> [Float] {
            let n = Int(seconds * sampleRate), logRatio = log(to / from)
            return (0..<n).map { i in
                let t = Double(i) / sampleRate
                let phase = 2 * Double.pi * from * seconds / logRatio * (exp(t * logRatio / seconds) - 1)
                let fade = min(1, min(Double(i), Double(n - 1 - i)) / (sampleRate * 0.005))
                return Float(amplitude * sin(phase) * (0.5 - 0.5 * cos(Double.pi * fade)))
            }
        }
        let marker = chirp(0.08, 700, min(6000, sampleRate * 0.35), 0.2)
        let closingMarker = Array(marker.reversed())
        let reference = chirp(duration, low, high, 0.25)
        let first = Int(0.15 * sampleRate)
        let guardFrames = Int(guardInterval * sampleRate)
        let start = first + marker.count + guardFrames
        let second = start + reference.count + guardFrames
        var samples = [Float](repeating: 0, count: second + marker.count + Int(0.2 * sampleRate))
        samples.replaceSubrange(first..<first + marker.count, with: marker)
        samples.replaceSubrange(start..<start + reference.count, with: reference)
        samples.replaceSubrange(second..<second + closingMarker.count, with: closingMarker)
        return CalibrationSweep(sampleRate: sampleRate, samples: samples, reference: reference, acousticMarker: marker,
                                closingAcousticMarker: closingMarker, firstMarkerStart: first, secondMarkerStart: second, sweepStart: start,
                                lowFrequency: low, highFrequency: high)
    }

    /// Arrival is target minus the fixed-reference acoustic arrival, not recording start.
    /// The same fixed reference must be used for every channel in a timing group.
    public static func analyze(recording r: CalibrationRecording, sweep s: CalibrationSweep) throws -> AcousticMeasurement {
        guard r.sampleRate.isFinite, (8000...192000).contains(r.sampleRate), !r.samples.isEmpty,
              r.samples.count <= Int(r.sampleRate * 30), (0...8).contains(r.pointIndex), !r.channelID.isEmpty,
              !r.configurationDigest.isEmpty, !r.activeSpeakerIDs.isEmpty,
              [r.location.x, r.location.y, r.location.z].allSatisfy(\.isFinite) else {
            throw CalibrationError.invalidInput("Invalid capture format or missing acquisition identity")
        }
        guard !r.interrupted else { throw CalibrationError.rejected("Recording was interrupted. Keep Roomtastic open during the sweep and try again.") }
        guard let translation = r.maximumTranslationMeters, let rotation = r.maximumRotationRadians,
              HandheldCapturePolicy.acceptsMotion(translation: translation, rotation: rotation) else {
            throw CalibrationError.rejected("Motion data is missing or the phone moved substantially. Rest your elbows and repeat the sweep.")
        }
        guard r.samples.allSatisfy(\.isFinite) else { throw CalibrationError.rejected("The microphone recording contains invalid samples. Repeat this measurement.") }
        let clipped = r.samples.reduce(0) { $0 + (abs($1) >= 0.999 ? 1 : 0) }
        guard clipped == 0 else { throw CalibrationError.rejected("The recording was too loud. Lower Measurement Level and try again.") }
        let nominal = resample(r.samples, step: r.sampleRate / s.sampleRate)
        let markerSpacing = s.secondMarkerStart - s.firstMarkerStart
        let timingTolerance = Int(s.sampleRate * 0.15)
        // An opening candidate must leave room for its closing marker. With short
        // guards the old eight-second window also included the sweep and ending.
        let lastOpening = min(Int(s.sampleRate * 8),
                              nominal.count - s.closingAcousticMarker.count - markerSpacing + timingTolerance)
        guard lastOpening >= 0 else {
            throw CalibrationError.incomplete("The recording ended before both timing chirps could be captured. Repeat this measurement.")
        }
        let first = try correlate(nominal, reference: s.acousticMarker, range: 0...lastOpening)
        guard first.coefficient >= 0.15 else {
            throw CalibrationError.rejected("The opening timing chirp was not clear enough. Quiet the room and repeat this measurement.")
        }
        let expectedSecond = first.offset + Double(markerSpacing)
        let second = try correlate(nominal, reference: s.closingAcousticMarker,
                                   range: max(0, Int(expectedSecond) - timingTolerance)...(Int(expectedSecond) + timingTolerance))
        guard first.coefficient >= 0.15, second.coefficient >= 0.15 else {
            throw CalibrationError.rejected("The short timing chirps were not clear enough. Quiet the room and try again; raise Measurement Level slightly if they are hard to hear.")
        }
        let ratio = (second.offset - first.offset) / Double(s.secondMarkerStart - s.firstMarkerStart)
        let ppm = (ratio - 1) * 1_000_000
        guard ppm.isFinite, abs(ppm) <= 2000 else { throw CalibrationError.rejected("Recording timing changed during the sweep. Keep Roomtastic open and repeat this measurement.") }
        let corrected = resample(nominal, step: ratio)
        let markerDelay = first.offset / ratio - Double(s.firstMarkerStart)
        let expected = Double(s.sweepStart) + markerDelay
        let match = try correlate(corrected, reference: s.reference,
                                  range: max(0, Int(expected - 2 * s.sampleRate))...Int(expected + 2 * s.sampleRate))
        guard match.coefficient >= 0.12 else { throw CalibrationError.rejected("The selected speaker’s sweep was not clear enough. Check that speaker is playing, then repeat at a comfortable level.") }
        let quietEnd = min(Int(first.offset - s.sampleRate * 0.03), Int(0.1 * s.sampleRate))
        guard quietEnd >= Int(0.03 * s.sampleRate) else { throw CalibrationError.rejected("Recording started too late to measure the room’s background noise. Repeat this measurement.") }
        let noisePower = nominal.prefix(quietEnd).reduce(0.0) { $0 + Double($1) * Double($1) } / Double(quietEnd)
        let start = Int(match.offset.rounded())
        let tail = Int(s.sampleRate * 0.2)
        guard start >= 0, start + s.reference.count + tail <= corrected.count else {
            throw CalibrationError.incomplete("Recording ended too soon. Keep Roomtastic open until the measurement finishes.")
        }
        let signalPower = corrected[start..<start + s.reference.count].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.reference.count)
        let snr = 10 * log10(max(signalPower - noisePower, 1e-20) / max(noisePower, 1e-16))
        guard signalPower > 1e-10, snr >= 20 else { throw CalibrationError.rejected("The speaker was too quiet compared with background noise. Quiet the room or raise Measurement Level slightly, then try again.") }
        let n = nextPowerOfTwo(s.reference.count + tail)
        let x = try spectrum(s.reference, count: n)
        let y = try spectrum(Array(corrected[start..<start + s.reference.count + tail]), count: n)
        let peakPower = zip(x.real, x.imag).reduce(0.0) { peak, bin in
            max(peak, Double(bin.0) * Double(bin.0) + Double(bin.1) * Double(bin.1))
        }
        let regularizer = max(peakPower * 1e-8, 1e-20)
        let frequencies = (0..<160).map { s.lowFrequency * pow(s.highFrequency / s.lowFrequency, Double($0) / 159) }
        var magnitudes = [Double]()
        magnitudes.reserveCapacity(frequencies.count)
        for frequency in frequencies {
            let bin = max(1, min(n / 2 - 1, Int((frequency * Double(n) / s.sampleRate).rounded())))
            let xp = Double(x.real[bin]) * Double(x.real[bin]) + Double(x.imag[bin]) * Double(x.imag[bin])
            let yp = Double(y.real[bin]) * Double(y.real[bin]) + Double(y.imag[bin]) * Double(y.imag[bin])
            // |Y conj(X)/(X conj(X)+lambda)|: regularized complex deconvolution magnitude.
            magnitudes.append(10 * log10(max(yp * xp / pow(xp + regularizer, 2), 1e-16)))
        }
        guard magnitudes.allSatisfy(\.isFinite) else { throw CalibrationError.rejected("Invalid deconvolution") }
        let gain = median(zip(frequencies, magnitudes).filter { (200...2000).contains($0.0) }.map(\.1))
        return AcousticMeasurement(recordingID: r.id, channelID: r.channelID, pointIndex: r.pointIndex,
            location: r.location, sampleRate: s.sampleRate, origin: r.origin, purpose: r.purpose, capturedAt: r.capturedAt,
            configurationDigest: r.configurationDigest, activeSpeakerIDs: r.activeSpeakerIDs, completeSystem: r.completeSystem,
            arrivalSeconds: (match.offset - expected) / s.sampleRate,
            clockErrorPPM: ppm, signalToNoiseDB: snr, correlation: match.coefficient, gainDB: gain,
            frequencies: frequencies, magnitudeDB: magnitudes)
    }

    struct Spectrum { var real: [Float]; var imag: [Float] }
    static func nextPowerOfTwo(_ value: Int) -> Int { var n = 1; while n < value { n <<= 1 }; return n }
    static func spectrum(_ values: [Float], count: Int) throws -> Spectrum {
        var result = Spectrum(real: [Float](repeating: 0, count: count), imag: [Float](repeating: 0, count: count))
        result.real.replaceSubrange(0..<min(values.count, count), with: values.prefix(count))
        try transform(&result, inverse: false)
        return result
    }
    static func transform(_ data: inout Spectrum, inverse: Bool) throws {
        let n = data.real.count, logN = vDSP_Length(Int(log2(Double(data.real.count))))
        guard let setup = vDSP_create_fftsetup(logN, FFTRadix(kFFTRadix2)) else {
            throw CalibrationError.invalidInput("Unable to allocate FFT plan")
        }
        defer { vDSP_destroy_fftsetup(setup) }
        data.real.withUnsafeMutableBufferPointer { real in
            data.imag.withUnsafeMutableBufferPointer { imag in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, logN, FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
            }
        }
        if inverse { let scale = Float(1) / Float(n); for i in 0..<n { data.real[i] *= scale; data.imag[i] *= scale } }
    }
    static func resample(_ samples: [Float], step: Double) -> [Float] {
        if step == 1 { return samples }
        let count = Int(Double(samples.count - 1) / step) + 1
        return (0..<count).map { i in
            let position = Double(i) * step, index = Int(position), fraction = Float(position - Double(index))
            return samples[index] * (1 - fraction) + samples[min(index + 1, samples.count - 1)] * fraction
        }
    }
    static func correlate(_ samples: [Float], reference: [Float], range: ClosedRange<Int>) throws -> (offset: Double, coefficient: Double) {
        let lo = max(0, range.lowerBound), hi = min(samples.count - reference.count, range.upperBound)
        guard !reference.isEmpty, hi >= lo else {
            throw CalibrationError.incomplete("The recording does not contain the expected timing or sweep segment. Repeat this measurement.")
        }
        // Crop before FFT: a ten-second sweep does not require a whole thirty-second recording transform.
        let window = Array(samples[lo..<hi + reference.count])
        let n = nextPowerOfTwo(window.count + reference.count - 1)
        var y = try spectrum(window, count: n)
        let x = try spectrum(reference, count: n)
        for i in 0..<n {
            let real = y.real[i] * x.real[i] + y.imag[i] * x.imag[i]
            y.imag[i] = y.imag[i] * x.real[i] - y.real[i] * x.imag[i]
            y.real[i] = real
        }
        try transform(&y, inverse: true)
        var best = 0
        if hi > lo {
            for i in 1...(hi - lo) where abs(y.real[i]) > abs(y.real[best]) { best = i }
        }
        let a = Double(abs(y.real[max(0, best - 1)])), b = Double(abs(y.real[best])), c = Double(abs(y.real[min(hi - lo, best + 1)]))
        let denominator = a - 2 * b + c
        let fractional = abs(denominator) > 1e-15 && best > 0 && best < hi-lo ? max(-0.5, min(0.5, 0.5 * (a-c) / denominator)) : 0
        let refPower = reference.reduce(0.0) { $0 + Double($1) * Double($1) }
        let inputPower = window[best..<best + reference.count].reduce(0.0) { $0 + Double($1) * Double($1) }
        return (Double(lo + best) + fractional, min(1, b / sqrt(max(refPower * inputPower, 1e-30))))
    }
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle-1] + sorted[middle]) / 2 : sorted[middle]
    }
}
