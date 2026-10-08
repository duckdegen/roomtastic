// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreAudio
import RoomtasticShared
import RoomtasticDSP
import RoomtasticCalibration

final class OutputPipeline {
    let id: String, sourceRate: Double, rate: Double, firstSourceFrame: UInt64, audibleUnix: Double
    var wired: WiredEndpoint?
    var airplay: AirPlaySession?
    private let left: OpaquePointer, right: OpaquePointer, resampler: OpaquePointer
    private let resources: DSPResources
    private var outputFrame: UInt64 = 0
    private let leftStorage = FloatStorage(1024), rightStorage = FloatStorage(1024)
    private let interleavedStorage = FloatStorage(2048), convertedStorage = FloatStorage(4096)
    private(set) var failed = false
    var retiringAt: Double?
    var onStatus: ((String, String) -> Void)?
    var onAuthenticationRequired: ((String, String) -> Void)?
    var onReady: ((String) -> Void)?
    init(output: AudioOutput, device: AudioDeviceID?, receiver: Receiver?, sourceRate: Double, firstFrame: UInt64, origin: Double, unixOrigin: Double, lead: Double, queue: DispatchQueue, useStoredCredentials: Bool = false) throws {
        id = output.id; self.sourceRate = sourceRate; firstSourceFrame = firstFrame
        let offset = Double(firstFrame) / sourceRate + lead
        audibleUnix = unixOrigin + offset
        if let device { let sink = try WiredEndpoint(device: device, startHost: origin + offset); wired = sink; rate = sink.rate }
        else if let receiver { let sink = try AirPlaySession(receiver: receiver, queue: queue, useStoredCredentials: useStoredCredentials); airplay = sink; rate = sink.sampleRate }
        else { throw AudioFailure("Output is unavailable") }
        let resources = DSPResources(); self.resources = resources
        left = try resources.own(rt_processor_create(sourceRate, UInt32(sourceRate * 2), 4097), destroy: rt_processor_destroy)
        right = try resources.own(rt_processor_create(sourceRate, UInt32(sourceRate * 2), 4097), destroy: rt_processor_destroy)
        resampler = try resources.own(rt_resampler_create(8192), destroy: rt_resampler_destroy)
        airplay?.onFailure = { [weak self] error in self?.fail(error) }
        airplay?.onStatus = { [weak self] status in guard let self else { return }; self.onStatus?(self.id, status) }
        airplay?.onAuthenticationRequired = { [weak self] reason in guard let self else { return }; self.onAuthenticationRequired?(self.id, reason) }
        airplay?.onReady = { [weak self] in guard let self else { return }; self.onReady?(self.id) }
        try wired?.start()
    }
    static func validate(mixes: [ChannelMix], rate: Double) throws {
        guard Set(mixes.map(\.connection)).count == mixes.count,
              let probe = rt_processor_create(rate, UInt32(rate * 2), 4097) else { throw AudioFailure("Invalid or duplicated channel configuration") }
        defer { rt_processor_destroy(probe) }
        for mix in mixes {
            guard (0...1).contains(mix.connection.channel), mix.delaySeconds.isFinite, (0...2).contains(mix.delaySeconds) else { throw AudioFailure("Unsupported channel or delay") }
            let valid = mix.fir.withUnsafeBufferPointer { rt_processor_configure(probe, mix.left, mix.right, mix.gainDB, UInt32(mix.delaySeconds * rate), $0.baseAddress, UInt32($0.count)) }
            guard valid != 0 else { throw AudioFailure("Correction exceeds safe headroom or has invalid coefficients") }
        }
    }
    func configure(mixes: [ChannelMix], volume: Float, muted: Bool, bypass: Bool) throws {
        for (channel, processor) in [(0, left), (1, right)] {
            let mix = mixes.first { $0.connection.outputID == id && $0.connection.channel == channel }
            let fir = mix?.fir ?? []
            let valid = fir.withUnsafeBufferPointer { coefficients in
                rt_processor_configure(processor, mix?.left ?? (mixes.isEmpty && channel == 0 ? 1 : 0), mix?.right ?? (mixes.isEmpty && channel == 1 ? 1 : 0), mix?.gainDB ?? 0, UInt32((mix?.delaySeconds ?? 0) * sourceRate), coefficients.baseAddress, UInt32(coefficients.count))
            }
            guard valid != 0 else { throw AudioFailure("Correction exceeds safe headroom or has invalid coefficients") }
            rt_processor_set_controls(processor, volume, muted ? 1 : 0, bypass ? 1 : 0)
        }
    }
    func controls(volume: Float, muted: Bool, bypass: Bool) { for processor in [left, right] { rt_processor_set_controls(processor, volume, muted ? 1 : 0, bypass ? 1 : 0) } }
    func process(_ stereo: UnsafePointer<Float>, frames: Int, sourceRatio: Double) {
        guard !failed else { return }
        let l = leftStorage.pointer, r = rightStorage.pointer
        let interleaved = interleavedStorage.pointer, converted = convertedStorage.pointer
        rt_processor_process(left, stereo, l, UInt32(frames)); rt_processor_process(right, stereo, r, UInt32(frames))
        for i in 0..<frames { interleaved[i * 2] = l[i]; interleaved[i * 2 + 1] = r[i] }
        let sinkRatio = wired.map { Double(bitPattern: rt_atomic_load($0.ratio)) } ?? 1
        var consumed: UInt32 = 0
        let count = rt_resampler_process(resampler, interleaved, UInt32(frames), converted, 2048, sourceRate / rate * sourceRatio / sinkRatio, &consumed)
        guard consumed == frames else { fail("Resampler capacity exceeded; output stopped"); return }
        if let wired {
            if rt_buffer_write(wired.ring, converted, count, outputFrame) != count {
                fail("Wired playback missed its bounded queue deadline"); return
            }
        } else { airplay?.send(converted, frames: Int(count), audibleUnix: audibleUnix + Double(outputFrame) / rate) }
        outputFrame += UInt64(count)
        airplay?.checkDeadline()
    }
    func fail(_ reason: String) { guard !failed else { return }; failed = true; onStatus?(id, reason); stop() }
    func stop() { wired?.stop(); airplay?.stop() }
    deinit { stop() }
}
final class PlaybackEngine {
    let queue = DispatchQueue(label: "org.roomtastic.audio", qos: .userInteractive)
    let lead = 5.0
    private var capture: CaptureEndpoint?
    private var pipelines: [String: OutputPipeline] = [:]
    private var timer: DispatchSourceTimer?
    private var frame: UInt64 = 0
    private var origin = 0.0, unixOrigin = 0.0
    private var selected: [AudioOutput] = [], devices: [String: AudioDeviceID] = [:], receivers: [String: Receiver] = [:]
    private var mixes: [ChannelMix] = []
    private var volume: Float = 0.5, muted = false, bypass = false
    private var retries: [String: Double] = [:]
    private var authenticationRequired: [String: String] = [:]
    private var credentialPermission: Set<String> = []
    private var failures: [String: String] = [:]
    private let scratchStorage = FloatStorage(2048)
    private var playbackActivity: NSObjectProtocol?
    var onStatus: ((String, String) -> Void)?
    var onConfiguration: ((Bool, String) -> Void)?
    var onMeasurementFailure: ((String) -> Void)?
    var onAuthenticationRequired: ((String, String) -> Void)?
    var onOutputReady: ((String) -> Void)?
    private var pending: (ids: Set<String>, deadline: Double, apply: () throws -> Void)?
    var configurationPending: Bool { queue.sync { pending != nil } }
    private var sweep: (reference: CalibrationSweep, index: Int, routing: CalibrationPlaybackRouting, generation: UInt64, completion: () -> Void)?
    private var measurementSession = false, measurementFailed = false, measurementPlaybackPending = false
    private var measurementGeneration: UInt64 = 0
    @discardableResult func beginMeasurementSession() -> Bool {
        queue.sync {
            guard !measurementSession else { return false }
            measurementSession = true; measurementFailed = false
            return true
        }
    }
    func endMeasurementSession() {
        queue.sync { measurementSession = false; measurementFailed = false; measurementPlaybackPending = false; sweep = nil; measurementGeneration &+= 1 }
    }
    func pauseMeasurementPlayback() {
        queue.sync {
            // Keep the measurement session's silence and output-health checks active.
            sweep = nil; measurementPlaybackPending = false; measurementGeneration &+= 1
        }
    }
    private func invalidateMeasurement(_ reason: String) {
        measurementGeneration &+= 1; sweep = nil; measurementPlaybackPending = false
        guard measurementSession, !measurementFailed else { return }
        measurementFailed = true; onMeasurementFailure?(reason)
    }
    var sampleRate: Double { queue.sync { capture?.rate ?? 48000 } }
    func start(driver: AudioDeviceID) throws {
        try queue.sync {
            guard capture == nil else { return }
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Synchronized Roomtastic audio playback")
            do {
                origin = hostSeconds(); unixOrigin = Date().timeIntervalSince1970
                let endpoint = try CaptureEndpoint(device: driver, origin: origin)
                try endpoint.start()
                // Startup can block while HAL acquires the device. Begin at live capture,
                // not at an obsolete pre-start frame that would look like an underrun.
                let liveFrame = UInt64(max(0, (hostSeconds() - origin) * endpoint.rate))
                capture = endpoint; frame = max(rt_atomic_load(endpoint.available), liveFrame); retries.removeAll(); playbackActivity = activity
                let timer = DispatchSource.makeTimerSource(queue: queue); timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.pump() }; self.timer = timer; timer.resume()
            } catch { ProcessInfo.processInfo.endActivity(activity); throw error }
        }
    }
    private func observe(_ pipeline: OutputPipeline) {
        pipeline.onStatus = { [weak self, weak pipeline] id, status in
            guard let self else { return }
            if pipeline?.failed == true { self.failures[id] = status }
            self.onStatus?(id, status)
        }
        pipeline.onAuthenticationRequired = { [weak self] id, reason in
            guard let self else { return }
            self.authenticationRequired[id] = reason; self.credentialPermission.remove(id)
            self.onAuthenticationRequired?(id, reason)
        }
        pipeline.onReady = { [weak self] id in
            guard let self else { return }
            self.authenticationRequired.removeValue(forKey: id); self.failures.removeValue(forKey: id)
            self.onOutputReady?(id)
        }
    }
    func retryAuthentication(outputID: String, useStoredCredentials: Bool) {
        queue.async {
            // Only an explicit challenge may authorize a credential lookup or unblock a retry.
            guard self.authenticationRequired.removeValue(forKey: outputID) != nil else { return }
            if useStoredCredentials { self.credentialPermission.insert(outputID) }
            else { self.credentialPermission.remove(outputID) }
            if self.pipelines[outputID]?.failed == true { self.pipelines.removeValue(forKey: outputID)?.stop() }
            self.retries.removeValue(forKey: outputID)
        }
    }
    func configure(outputs: [AudioOutput], devices: [String: AudioDeviceID], receivers: [String: Receiver], mixes: [ChannelMix], volume: Float, muted: Bool, bypass: Bool) throws {
        try queue.sync {
            guard let capture else { throw AudioFailure("Playback is not active") }
            guard pending == nil else { throw AudioFailure("A coordinated output change is already pending") }
            guard !measurementPlaybackPending else { throw AudioFailure("Wait for measurement playback to finish before changing outputs") }
            let oldIDs = Set(selected.map(\.id)), newIDs = Set(outputs.map(\.id))
            try OutputPipeline.validate(mixes: mixes, rate: capture.rate)
            var staged: [String: OutputPipeline] = [:]
            do {
                for output in outputs where pipelines[output.id] == nil {
                    if let reason = authenticationRequired[output.id] { onStatus?(output.id, reason); throw AudioFailure(reason) }
                    do {
                        let adjustedOrigin = capture.hostTime(forFrame: frame) - Double(frame) / capture.rate
                        let pipeline = try OutputPipeline(output: output, device: devices[output.id], receiver: receivers[output.id], sourceRate: capture.rate, firstFrame: frame, origin: adjustedOrigin, unixOrigin: unixOrigin + adjustedOrigin - origin, lead: lead, queue: queue, useStoredCredentials: credentialPermission.contains(output.id))
                        observe(pipeline); failures.removeValue(forKey: output.id)
                        try pipeline.configure(mixes: mixes, volume: 0, muted: true, bypass: bypass)
                        staged[output.id] = pipeline
                    } catch {
                        failures[output.id] = error.localizedDescription; onStatus?(output.id, error.localizedDescription)
                        throw error
                    }
                }
            } catch { staged.values.forEach { $0.stop() }; throw error }
            pipelines.merge(staged) { _, new in new }
            let commit = { [weak self] () throws -> Void in
                guard let self else { return }
                guard outputs.allSatisfy({ self.pipelines[$0.id]?.failed == false && (self.pipelines[$0.id]?.airplay?.scheduled ?? true) }) else { throw AudioFailure("Prepared output disappeared or lost its playback clock") }
                for id in oldIDs.subtracting(newIDs) {
                    self.pipelines[id]?.controls(volume: 0, muted: true, bypass: bypass)
                    self.pipelines[id]?.retiringAt = capture.hostTime(forFrame: self.frame) + self.lead + 0.05
                }
                for output in outputs {
                    let pipeline = self.pipelines[output.id]!
                    pipeline.retiringAt = nil
                    try pipeline.configure(mixes: mixes, volume: volume, muted: muted, bypass: bypass)
                    if pipeline.wired != nil { self.onOutputReady?(output.id) }
                }
                self.selected = outputs; self.mixes = mixes
                self.volume = volume; self.muted = muted; self.bypass = bypass
            }
            self.devices = devices; self.receivers = receivers
            if staged.values.contains(where: { $0.airplay != nil }) {
                pending = (Set(staged.keys), hostSeconds() + 15, commit)
            } else {
                do { try commit(); onConfiguration?(true, "Configuration committed") }
                catch { for id in staged.keys { pipelines.removeValue(forKey: id)?.stop() }; throw error }
            }
        }
    }
    func setControls(volume: Float, muted: Bool, bypass: Bool) {
        queue.async {
            if self.measurementPlaybackPending && (self.volume != volume || self.muted != muted || self.bypass != bypass) { self.invalidateMeasurement("Playback controls changed during measurement") }
            self.volume = volume; self.muted = muted; self.bypass = bypass
            for pipeline in self.pipelines.values where pipeline.retiringAt == nil && !(self.pending?.ids.contains(pipeline.id) ?? false) { pipeline.controls(volume: volume, muted: muted, bypass: bypass) }
        }
    }
    func playMeasurement(_ reference: CalibrationSweep, target: ChannelConnection, mode: SweepSignalMode, referenceConnection: ChannelConnection, completion: @escaping () -> Void) throws {
        try queue.sync {
            guard capture != nil, pending == nil, measurementSession, !measurementFailed, !measurementPlaybackPending, !selected.isEmpty, sweep == nil, !reference.samples.isEmpty,
                  selected.allSatisfy({ pipelines[$0.id]?.failed == false && (pipelines[$0.id]?.airplay?.scheduled ?? true) }) else { throw AudioFailure("Wait until every output has a scheduled playback clock before measuring") }
            guard selected.contains(where: { $0.id == target.outputID && $0.channels > target.channel }),
                  selected.contains(where: { $0.id == referenceConnection.outputID && $0.channels > referenceConnection.channel }) else {
                throw AudioFailure("The measurement speaker or timing-reference channel is unavailable.")
            }
            let routing = try CalibrationPlaybackRouting(target: target, mode: mode, referenceConnection: referenceConnection)
            sweep = (reference, 0, routing, measurementGeneration, completion)
            measurementPlaybackPending = true
        }
    }
    func updateAvailability(devices: [String: AudioDeviceID], receivers: [String: Receiver]) {
        queue.async {
            guard self.capture != nil else { return }
            self.devices = devices; self.receivers = receivers
            for (id, pipeline) in self.pipelines {
                let reason: String?
                if let wired = pipeline.wired {
                    reason = devices[id] == wired.device ? nil : (devices[id] == nil ? "Wired output disappeared" : "Wired playback endpoint changed")
                } else if let receiver = pipeline.airplay?.receiver {
                    if let current = receivers[id], current.output.available {
                        if current.host.caseInsensitiveCompare(receiver.host) != .orderedSame || current.port != receiver.port {
                            reason = "Receiver host or playback port changed"
                        } else if current.output.channels != receiver.output.channels || current.output.sampleRate != receiver.output.sampleRate {
                            reason = "Receiver channel layout or advertised sample rate changed"
                        } else { reason = nil }
                        // Session/group/flags TXT changes are expected during our own connection.
                    } else { reason = "Receiver disappeared from network discovery" }
                } else { reason = "Output has no playback endpoint" }
                guard let reason else { continue }
                pipeline.fail(reason); self.pipelines.removeValue(forKey: id); self.retries[id] = hostSeconds() + 8
                if self.selected.contains(where: { $0.id == id }) { self.invalidateMeasurement(reason) }
            }
        }
    }
    private func pump() {
        guard let capture else { return }
        let scratch = scratchStorage.pointer
        let available = rt_atomic_load(capture.available)
        if available > frame + UInt64(capture.rate * 0.25) {
            // A suspended worker cannot drain old audio into newly recovered receivers.
            frame = available
            for pipeline in pipelines.values { pipeline.fail("Audio timeline missed its deadline; stale audio discarded") }
            pipelines.removeAll()
            invalidateMeasurement("Audio timeline missed its deadline during measurement")
            onStatus?("service", "Missed audio deadline; discarding backlog and rejoining outputs")
        }
        let now = hostSeconds()
        if let pending {
            if now > pending.deadline || pending.ids.contains(where: { pipelines[$0]?.failed != false }) {
                for id in pending.ids where pipelines[id]?.failed == false && !(pipelines[id]?.airplay?.scheduled ?? true) && now > pending.deadline {
                    pipelines[id]?.fail("Receiver did not finish preparing playback within 15 seconds")
                }
                let reason = pending.ids.sorted().compactMap { failures[$0] }.first ?? "Prepared output disappeared"
                for id in pending.ids { pipelines.removeValue(forKey: id)?.stop(); retries[id] = now + 8 }
                self.pending = nil; onConfiguration?(false, "\(reason); previous configuration retained")
            } else if pending.ids.allSatisfy({ pipelines[$0]?.airplay?.scheduled ?? true }) {
                do { try pending.apply(); self.pending = nil; onConfiguration?(true, "Configuration committed at a shared audio frame") }
                catch {
                    for id in pending.ids { pipelines.removeValue(forKey: id)?.stop() }
                    self.pending = nil; onConfiguration?(false, error.localizedDescription)
                }
            }
        }
        if measurementSession, !measurementFailed, selected.contains(where: { pipelines[$0.id]?.failed != false }) {
            invalidateMeasurement("An output failed during measurement; previous profile retained")
        }
        for (id, pipeline) in pipelines where pipeline.failed || (pipeline.retiringAt.map { now >= $0 } ?? false) {
            pipeline.stop(); pipelines.removeValue(forKey: id); retries[id] = now + 8
            if selected.contains(where: { $0.id == id }) { invalidateMeasurement("A measured output lost its playback timeline") }
        }
        for output in selected where pipelines[output.id] == nil && authenticationRequired[output.id] == nil && (devices[output.id] != nil || receivers[output.id] != nil) && now >= retries[output.id, default: 0] {
            do {
                let adjustedOrigin = capture.hostTime(forFrame: frame) - Double(frame) / capture.rate
                let pipeline = try OutputPipeline(output: output, device: devices[output.id], receiver: receivers[output.id], sourceRate: capture.rate, firstFrame: frame, origin: adjustedOrigin, unixOrigin: unixOrigin + adjustedOrigin - origin, lead: lead, queue: queue, useStoredCredentials: credentialPermission.contains(output.id))
                observe(pipeline); failures.removeValue(forKey: output.id)
                try pipeline.configure(mixes: mixes, volume: volume, muted: muted, bypass: bypass); pipelines[output.id] = pipeline
                if pipeline.wired != nil { onOutputReady?(output.id) }
            } catch { failures[output.id] = error.localizedDescription; onStatus?(output.id, error.localizedDescription); retries[output.id] = now + 8 }
        }
        var iterations = 0
        while available >= frame + 256, iterations < 48 {
            _ = rt_buffer_read(capture.ring, scratch, 256, frame)
            if var measurement = sweep {
                let reference = measurement.reference
                let count = min(256, reference.samples.count - measurement.index)
                for pipeline in pipelines.values {
                    measurement.routing.render(reference, from: measurement.index, outputID: pipeline.id,
                                               into: UnsafeMutableBufferPointer(start: scratch, count: 512))
                    pipeline.process(scratch, frames: 256, sourceRatio: Double(bitPattern: rt_atomic_load(capture.ratio)))
                }
                measurement.index += count
                if measurement.index == reference.samples.count {
                    sweep = nil
                    let generation = measurement.generation, completion = measurement.completion
                    let playbackEnd = capture.hostTime(forFrame: frame + 256) + lead + 0.1
                    queue.asyncAfter(deadline: .now() + max(0, playbackEnd - hostSeconds())) { [weak self] in
                        guard let self, self.measurementSession, self.measurementGeneration == generation else { return }
                        guard self.selected.allSatisfy({ self.pipelines[$0.id]?.failed == false && (self.pipelines[$0.id]?.airplay?.scheduled ?? true) }) else { self.invalidateMeasurement("Output failed before measurement playback completed"); return }
                        self.measurementPlaybackPending = false; completion()
                    }
                }
                else { sweep = measurement }
            } else {
                if measurementSession { scratch.update(repeating: 0, count: 512) }
                for pipeline in pipelines.values { pipeline.process(scratch, frames: 256, sourceRatio: Double(bitPattern: rt_atomic_load(capture.ratio))) }
            }
            frame += 256; iterations += 1
        }
    }
    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil; capture?.stop(); capture = nil
            pipelines.values.forEach { $0.stop() }; pipelines.removeAll(); selected.removeAll(); retries.removeAll()
            sweep = nil; pending = nil; measurementSession = false; measurementFailed = false; measurementPlaybackPending = false; measurementGeneration &+= 1
            if let activity = playbackActivity { ProcessInfo.processInfo.endActivity(activity); playbackActivity = nil }
        }
    }
    deinit { stop() }
}
