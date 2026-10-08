// SPDX-License-Identifier: MIT
import AVFoundation
import ARKit
import Foundation
import QuartzCore
import RoomtasticShared

final class MeasurementRecorder: NSObject, ARSessionDelegate, @unchecked Sendable {
    struct Recording { var samples: [Float]; var sampleRate: Double; var noiseDBFS: Double; var microphoneID: String; var motionMaxTranslationMeters: Double; var motionMaxRotationRadians: Double; var location: Point3 }
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rejection: String?
    private var rate: Double = 48_000
    private var micID = ""
    private var observing: [NSObjectProtocol] = []
    private var running = false
    private var noiseDBFS = -120.0
    let tracking = ARSession()
    private var roomAlignmentKnown = false
    private var minimumFrameTime = 0.0
    private var microphoneOffset = SIMD4<Float>(0, 0, 0, 1)
    private var measuredLocation: Point3?
    var roomTrackingReady: Bool {
        lock.withLock {
            guard roomAlignmentKnown, let frame = tracking.currentFrame, frame.timestamp > minimumFrameTime,
                  (0...0.25).contains(CACurrentMediaTime() - frame.timestamp),
                  case .normal = frame.camera.trackingState else { return false }
            return true
        }
    }
    func useScannedCoordinateSystem() { lock.withLock { roomAlignmentKnown = true; minimumFrameTime = 0 }; tracking.delegate = self }
    func invalidateRoomTracking() { lock.withLock { roomAlignmentKnown = false }; tracking.pause() }
    func restoreRoomTracking(_ map: ARWorldMap) {
        let config = ARWorldTrackingConfiguration(); config.initialWorldMap = map
        configureSpatialPlacement(config)
        lock.withLock { roomAlignmentKnown = true; minimumFrameTime = CACurrentMediaTime() }
        tracking.delegate = self; tracking.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
    func enableSpatialPlacementTracking() {
        guard roomTrackingReady,
              let config = tracking.configuration?.copy() as? ARWorldTrackingConfiguration else { return }
        // Reconfigure the live session without resetting the scanned room's world origin.
        config.initialWorldMap = nil
        configureSpatialPlacement(config)
        tracking.run(config, options: [])
    }
    private func configureSpatialPlacement(_ config: ARWorldTrackingConfiguration) {
        config.planeDetection.formUnion([.horizontal, .vertical])
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if config.sceneReconstruction.rawValue == 0,
           ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
    }
    private var initialPose: simd_float4x4?
    private var translationMax = 0.0
    private var rotationMax = 0.0
    private var trackedFrames = 0
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lock.lock(); defer { lock.unlock() }
        guard running, roomAlignmentKnown, frame.timestamp > minimumFrameTime else { return }
        guard case .normal = frame.camera.trackingState else { return }
        let pose = frame.camera.transform
        if initialPose == nil {
            initialPose = pose
            let location = pose * microphoneOffset
            measuredLocation = Point3(x: Double(location.x), y: Double(location.y), z: Double(location.z))
        }
        guard let initialPose else { return }
        trackedFrames += 1
        translationMax = max(translationMax, Double(simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z), SIMD3(initialPose.columns.3.x, initialPose.columns.3.y, initialPose.columns.3.z))))
        let dot = min(1, abs(simd_dot(simd_quatf(pose).vector, simd_quatf(initialPose).vector)))
        rotationMax = max(rotationMax, Double(2 * acos(dot)))
        if !HandheldCapturePolicy.acceptsMotion(translation: translationMax, rotation: rotationMax) {
            rejection = "The phone moved substantially during the sweep. Rest your elbows and try again."
        }
    }
    func sessionWasInterrupted(_ session: ARSession) { lock.withLock { roomAlignmentKnown = false }; reject("Camera tracking was interrupted. Relocalize the saved room before retrying.") }
    func session(_ session: ARSession, didFailWithError error: Error) { lock.withLock { roomAlignmentKnown = false }; reject(error.localizedDescription) }
    func start(microphoneOffset: Point3) async throws {
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard permitted else { throw CaptureError.rejected("Microphone access is required for room measurement.") }
        try Task.checkCancellation()
        guard roomTrackingReady else { throw CaptureError.rejected("Relocalize to the scanned room before recording. Keep the camera uncovered and look around the room.") }
        guard [microphoneOffset.x, microphoneOffset.y, microphoneOffset.z].allSatisfy({ $0.isFinite && abs($0) <= 0.4 }) else { throw CaptureError.rejected("Microphone offset is invalid.") }
        lock.withLock { self.microphoneOffset = SIMD4(Float(microphoneOffset.x), Float(microphoneOffset.y), Float(microphoneOffset.z), 1); measuredLocation = nil }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(48_000)
        guard let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { throw CaptureError.rejected("Only the iPhone built-in microphone is supported. Disconnect external audio inputs.") }
        guard let bottom = input.dataSources?.first(where: { $0.orientation == .bottom }) else { throw CaptureError.rejected("This device does not expose a selectable bottom built-in microphone.") }
        try input.setPreferredDataSource(bottom)
        try session.setPreferredInput(input)
        try session.setActive(true)
        guard session.currentRoute.inputs.allSatisfy({ $0.portType == .builtInMic }),
              session.currentRoute.inputs.first?.selectedDataSource?.dataSourceID == bottom.dataSourceID else {
            try? session.setActive(false)
            throw CaptureError.rejected("The bottom built-in microphone could not be selected.")
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.rejected("Microphone format is unavailable.") }
        lock.withLock {
            samples.removeAll(keepingCapacity: true); samples.reserveCapacity(RoomtasticProtocol.maxRecordingBytes / 4)
            rejection = nil; rate = format.sampleRate; micID = "\(input.uid):\(bottom.dataSourceID)"; running = true
            initialPose = nil; translationMax = 0; rotationMax = 0; trackedFrames = 0
        }
        tracking.delegate = self
        let center = NotificationCenter.default
        observing.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            guard let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  kind == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.reject("Recording was interrupted. Return to Roomtastic and try again.")
        })
        observing.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            self?.validateMicrophoneInput()
        })
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.running else { return }
            guard buffer.format.sampleRate == self.rate else {
                self.rejection = "The microphone recording format changed. Try the measurement again."
                return
            }
            guard self.samples.count + Int(buffer.frameLength) <= RoomtasticProtocol.maxRecordingBytes / 4 else { self.rejection = "Recording exceeded 30 seconds at 48 kHz."; return }
            for index in 0..<Int(buffer.frameLength) {
                let sample = channel[index]
                if !sample.isFinite || abs(sample) >= 0.98 { self.rejection = "The recording was too loud. Lower Measurement Level and try again." }
                self.samples.append(sample)
            }
        }
        do { try engine.start() } catch { stop(); throw error }
    }
    func waitForAmbient() async throws {
        let deadline = CACurrentMediaTime() + 2
        while true {
            try Task.checkCancellation()
            let ready = try lock.withLock {
                if let rejection { throw CaptureError.rejected(rejection) }
                guard running else { throw CancellationError() }
                guard samples.count >= Int(rate * 0.3), trackedFrames >= 5 else { return false }
                let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
                noiseDBFS = 10 * log10(max(power, 1e-12))
                guard noiseDBFS < -35 else {
                    throw CaptureError.rejected("The room is too noisy to measure clearly. Quiet the room and try again.")
                }
                return true
            }
            if ready { return }
            if CACurrentMediaTime() >= deadline {
                let audioReady = lock.withLock { samples.count >= Int(rate * 0.3) }
                throw CaptureError.rejected(audioReady
                    ? "The camera is not ready to locate the microphone. Point it toward the room and align again."
                    : "The microphone hasn’t started recording. Close and reopen Roomtastic, then try again.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func finish() throws -> Recording {
        stop()
        lock.lock(); defer { lock.unlock() }
        defer { samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; samples.removeAll(keepingCapacity: false) }
        if let rejection { throw CaptureError.rejected(rejection) }
        guard samples.count > Int(rate) else { throw CaptureError.rejected("Recording is too short.") }
        guard trackedFrames >= 15 else { throw CaptureError.rejected("Insufficient tracked camera poses to validate motion.") }
        guard let measuredLocation, roomAlignmentKnown else { throw CaptureError.rejected("The recording has no valid position in the scanned room coordinate system.") }
        return Recording(samples: samples, sampleRate: rate, noiseDBFS: noiseDBFS, microphoneID: micID, motionMaxTranslationMeters: translationMax, motionMaxRotationRadians: rotationMax, location: measuredLocation)
    }
    func stop() {
        lock.lock(); let wasRunning = running; running = false; lock.unlock()
        observing.forEach { NotificationCenter.default.removeObserver($0) }; observing.removeAll()
        if wasRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func discard() { stop(); lock.lock(); samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; samples.removeAll(keepingCapacity: false); lock.unlock() }
    private func validateMicrophoneInput() {
        let expected = lock.withLock { (running, micID, rate) }
        guard expected.0 else { return }
        let session = AVAudioSession.sharedInstance()
        guard session.currentRoute.inputs.count == 1, let input = session.currentRoute.inputs.first,
              input.portType == .builtInMic else {
            reject("Recording switched away from the iPhone microphone. Disconnect headphones or USB audio and try again.")
            return
        }
        guard let source = input.selectedDataSource,
              "\(input.uid):\(source.dataSourceID)" == expected.1 else {
            reject("The selected microphone changed. Hold the phone upright and try again.")
            return
        }
        guard abs(session.sampleRate - expected.2) < 1 else {
            reject("The microphone recording format changed. Try the measurement again.")
            return
        }
    }
    private func reject(_ reason: String) {
        lock.withLock { if running && rejection == nil { rejection = reason } }
    }
    deinit { stop(); tracking.pause() }
}
enum CaptureError: LocalizedError {
    case rejected(String)
    var errorDescription: String? { if case .rejected(let message) = self { return message }; return nil }
}
