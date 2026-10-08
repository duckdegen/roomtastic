// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreAudio
import AudioToolbox
import RoomtasticDSP

func hostSeconds(_ ticks: UInt64 = mach_absolute_time()) -> Double { Double(AudioConvertHostTimeToNanos(ticks)) / 1_000_000_000 }

final class CaptureEndpoint {
    let device: AudioDeviceID, rate: Double, origin: Double
    let ring: OpaquePointer, available: OpaquePointer, ratio: OpaquePointer, clock: OpaquePointer
    private let timelineVersion: OpaquePointer, hostAtEnd: OpaquePointer
    private let resources: DSPResources
    private var version: UInt64 = 0
    private var callback: AudioDeviceIOProcID?
    private let scratchStorage = FloatStorage(16384)
    private var sampleOrigin: Double?
    // Read and updated only on the engine's processing queue.
    private var lastTimeline: (frame: UInt64, host: Double, ratio: Double)?
    init(device: AudioDeviceID, origin: Double) throws {
        self.device = device; self.origin = origin
        let format = try Hardware.streamFormat(device, scope: kAudioDevicePropertyScopeInput); rate = format.mSampleRate
        guard [44100.0, 48000.0].contains(rate) else { throw AudioFailure("Roomtastic requires 44.1 or 48 kHz") }
        let resources = DSPResources(); self.resources = resources
        ring = try resources.own(rt_buffer_create(524288, 2), destroy: rt_buffer_destroy)
        available = try resources.own(rt_atomic_create(0), destroy: rt_atomic_destroy)
        ratio = try resources.own(rt_atomic_create(Double(1).bitPattern), destroy: rt_atomic_destroy)
        clock = try resources.own(rt_clock_create(rate), destroy: rt_clock_destroy)
        timelineVersion = try resources.own(rt_atomic_create(0), destroy: rt_atomic_destroy)
        hostAtEnd = try resources.own(rt_atomic_create(origin.bitPattern), destroy: rt_atomic_destroy)
        try checked(AudioDeviceCreateIOProcID(device, { _, _, input, inputTime, _, _, context in
            guard let context else { return noErr }
            Unmanaged<CaptureEndpoint>.fromOpaque(context).takeUnretainedValue().capture(input, time: inputTime.pointee)
            return noErr
        }, Unmanaged.passUnretained(self).toOpaque(), &callback), "Create virtual capture callback")
    }
    func start() throws { try checked(AudioDeviceStart(device, callback), "Start virtual capture") }
    private func capture(_ input: UnsafePointer<AudioBufferList>, time: AudioTimeStamp) {
        let scratch = scratchStorage.pointer
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
        guard frames <= 8192, time.mFlags.contains(.hostTimeValid), time.mFlags.contains(.sampleTimeValid) else { return }
        let seconds = hostSeconds(time.mHostTime)
        if sampleOrigin == nil { sampleOrigin = time.mSampleTime - max(0, seconds - origin) * rate }
        let firstFrame = UInt64(max(0, (time.mSampleTime - sampleOrigin!).rounded()))
        var channel = 0
        scratch.update(repeating: 0, count: frames * 2)
        for buffer in buffers {
            guard let raw = buffer.mData else { channel += Int(buffer.mNumberChannels); continue }
            let samples = raw.assumingMemoryBound(to: Float.self), channels = Int(buffer.mNumberChannels)
            for c in 0..<channels where channel + c < 2 { for f in 0..<frames { scratch[f * 2 + channel + c] = samples[f * channels + c] } }
            channel += channels
        }
        _ = rt_buffer_write(ring, scratch, UInt32(frames), firstFrame)
        let clockRatio = rt_clock_update(clock, time.mSampleTime, seconds)
        version &+= 1; rt_atomic_store(timelineVersion, version)
        rt_atomic_store(hostAtEnd, (seconds + Double(frames) / (rate * clockRatio)).bitPattern)
        rt_atomic_store(available, firstFrame + UInt64(frames))
        rt_atomic_store(ratio, clockRatio.bitPattern)
        version &+= 1; rt_atomic_store(timelineVersion, version)
    }
    func hostTime(forFrame frame: Double) -> Double {
        for _ in 0..<8 {
            let before = rt_atomic_load(timelineVersion)
            if before & 1 != 0 { continue }
            let end = rt_atomic_load(available), seconds = Double(bitPattern: rt_atomic_load(hostAtEnd))
            let clockRatio = Double(bitPattern: rt_atomic_load(ratio))
            if before == rt_atomic_load(timelineVersion) {
                lastTimeline = (end, seconds, clockRatio)
                return seconds + (Double(frame) - Double(end)) / (rate * clockRatio)
            }
        }
        let last = lastTimeline ?? (0, origin, 1)
        return last.1 + (Double(frame) - Double(last.0)) / (rate * last.2)
    }
    func stop() { if let callback { AudioDeviceStop(device, callback); AudioDeviceDestroyIOProcID(device, callback); self.callback = nil } }
    deinit { stop() }
}
final class WiredEndpoint {
    let device: AudioDeviceID, rate: Double, startHost: Double, deviceDelay: Double
    let ring: OpaquePointer, ratio: OpaquePointer, clock: OpaquePointer
    private let resources: DSPResources
    private var callback: AudioDeviceIOProcID?
    private let scratchStorage = FloatStorage(16384)
    private var sampleOrigin: Double?
    private let timelineVersion: OpaquePointer, timelineFrame: OpaquePointer, timelineHost: OpaquePointer
    private var version: UInt64 = 0
    // Snapshot cache belongs only to the processing queue.
    private var lastTimeline: (frame: Double, host: Double, ratio: Double)?
    init(device: AudioDeviceID, startHost: Double) throws {
        self.device = device; self.startHost = startHost; self.deviceDelay = Hardware.deviceDelay(device)
        let format = try Hardware.streamFormat(device, scope: kAudioDevicePropertyScopeOutput); rate = format.mSampleRate
        guard [44100.0, 48000.0].contains(rate) else { throw AudioFailure("Output must run at 44.1 or 48 kHz") }
        let resources = DSPResources(); self.resources = resources
        ring = try resources.own(rt_buffer_create(524288, 2), destroy: rt_buffer_destroy)
        ratio = try resources.own(rt_atomic_create(Double(1).bitPattern), destroy: rt_atomic_destroy)
        clock = try resources.own(rt_clock_create(rate), destroy: rt_clock_destroy)
        timelineVersion = try resources.own(rt_atomic_create(0), destroy: rt_atomic_destroy)
        timelineFrame = try resources.own(rt_atomic_create(0), destroy: rt_atomic_destroy)
        timelineHost = try resources.own(rt_atomic_create(startHost.bitPattern), destroy: rt_atomic_destroy)
        try checked(AudioDeviceCreateIOProcID(device, { _, _, _, _, output, outputTime, context in
            guard let context else { return noErr }
            Unmanaged<WiredEndpoint>.fromOpaque(context).takeUnretainedValue().render(output, time: outputTime.pointee)
            return noErr
        }, Unmanaged.passUnretained(self).toOpaque(), &callback), "Create wired playback callback")
    }
    func start() throws { try checked(AudioDeviceStart(device, callback), "Start wired playback") }
    private func render(_ output: UnsafeMutablePointer<AudioBufferList>, time: AudioTimeStamp) {
        let scratch = scratchStorage.pointer
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
        guard let first = buffers.first, first.mNumberChannels > 0, time.mFlags.contains(.hostTimeValid), time.mFlags.contains(.sampleTimeValid) else { return }
        let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels)); guard frames <= 8192 else { return }
        let seconds = hostSeconds(time.mHostTime) + deviceDelay
        let clockRatio = rt_clock_update(clock, time.mSampleTime, hostSeconds(time.mHostTime))
        // Keep the host deadline fixed while the sink clock converges before playback.
        if sampleOrigin == nil {
            let untilStart = (startHost - seconds) * rate * clockRatio
            if untilStart >= Double(frames) {
                rt_atomic_store(ratio, clockRatio.bitPattern); return
            }
            sampleOrigin = time.mSampleTime + untilStart
        }
        // Publish the actual presentation position, not just clock speed. A
        // speed estimate alone cannot repair errors accumulated earlier.
        version &+= 1; rt_atomic_store(timelineVersion, version)
        rt_atomic_store(timelineFrame, (time.mSampleTime - sampleOrigin!).bitPattern)
        rt_atomic_store(timelineHost, seconds.bitPattern)
        rt_atomic_store(ratio, clockRatio.bitPattern)
        version &+= 1; rt_atomic_store(timelineVersion, version)
        let position = Int64((time.mSampleTime - sampleOrigin!).rounded())
        if position + Int64(frames) <= 0 { return }
        let prefix = position < 0 ? min(frames, Int(-position)) : 0
        scratch.update(repeating: 0, count: frames * 2)
        _ = rt_buffer_read(ring, scratch.advanced(by: prefix * 2), UInt32(frames - prefix), UInt64(max(0, position)))
        var channel = 0
        for buffer in buffers {
            guard let raw = buffer.mData else { channel += Int(buffer.mNumberChannels); continue }
            let samples = raw.assumingMemoryBound(to: Float.self), channels = Int(buffer.mNumberChannels)
            for c in 0..<channels where channel + c < 2 { for f in 0..<frames { samples[f * channels + c] = scratch[f * 2 + channel + c] } }
            channel += channels
        }
    }
    func presentation(forFrame frame: UInt64) -> (host: Double, ratio: Double) {
        for _ in 0..<8 {
            let before = rt_atomic_load(timelineVersion)
            if before == 0 || before & 1 != 0 { continue }
            let position = Double(bitPattern: rt_atomic_load(timelineFrame))
            let host = Double(bitPattern: rt_atomic_load(timelineHost))
            let speed = Double(bitPattern: rt_atomic_load(ratio))
            if before == rt_atomic_load(timelineVersion) {
                lastTimeline = (position, host, speed); break
            }
        }
        let last = lastTimeline ?? (0, startHost, Double(bitPattern: rt_atomic_load(ratio)))
        return (last.1 + (Double(frame) - last.0) / (rate * last.2), last.2)
    }
    func stop() { if let callback { AudioDeviceStop(device, callback); AudioDeviceDestroyIOProcID(device, callback); self.callback = nil } }
    deinit { stop() }
}
