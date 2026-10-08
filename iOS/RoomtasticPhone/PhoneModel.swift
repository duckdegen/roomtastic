// SPDX-License-Identifier: MIT
import SwiftUI
import RoomPlan
import ARKit
import CryptoKit
import RoomtasticShared
import RoomtasticTransport

@MainActor final class PhoneModel: ObservableObject {
    @Published var room = RoomModel(id: UUID(), name: "My room", speakers: [], positions: [])
    @Published var outputs: [AudioOutput] = []
    @Published var status = "Scan the Mac's pairing QR code to connect."
    @Published var connected = false {
        didSet {
            if !connected {
                reportedMasterVolume = nil
                volumeRequestPending = false
                for index in outputs.indices { outputs[index].available = false }
            }
        }
    }
    @Published var error: String?
    @Published var profile: CalibrationProfile?
    @Published var selectedPosition: UUID?
    @Published private var sequence: CalibrationSequence?
    var pointIndex: Int { sequence?.pointIndex ?? 0 }
    var speakerIndex: Int { sequence?.signalIndex ?? 0 }
    @Published var measuring = false
    @Published var retainRaw = false
    @Published var furnitureRevision = UserDefaults.standard.string(forKey: "furnitureRevision") ?? "Initial layout" {
        didSet { UserDefaults.standard.set(furnitureRevision, forKey: "furnitureRevision"); invalidateChangedConditions() }
    }
    @Published private(set) var reportedMasterVolume: Double?
    @Published private(set) var volumeRequestPending = false
    @Published private(set) var measurementGrid: MeasurementGrid?
    var purpose: SweepPurpose { sequence?.purpose ?? .calibration }
    @Published private(set) var guided = false
    @Published private(set) var sessionPaused = false { didSet { updateIdleTimer() } }
    @Published private(set) var resumePending = false
    @Published private(set) var positionRunActive = false { didSet { updateIdleTimer() } }
    @Published private(set) var captureRetryReason: String?
    private var nextCaptureTask: Task<Void, Never>?
    private var reconnectOnReturn = false
    private var applicationIsActive = true
    private var deferredCancellation: UUID?
    @Published var scanned = false
    // Approximate rear-camera-to-bottom-microphone translation, shared by placement and capture.
    private let microphoneOffset = Point3(x: 0, y: -0.14, z: 0)
    var trackingSession: ARSession { recorder.tracking }
    var roomTrackingReady: Bool { room.geometry != nil && recorder.roomTrackingReady }
    func prepareSpatialPlacement() {
        guard !sessionInProgress else { error = "Finish or cancel measurement before moving room tags."; return }
        guard scanned, room.geometry != nil else { error = "Scan the room before placing a spatial tag."; return }
        if recorder.roomTrackingReady { recorder.enableSpatialPlacementTracking() }
        else { relocalizeRoom() }
    }
    var sessionInProgress: Bool { guided || awaitingFinalResult }
    var guidedTargetPosition: Point3? { selectedPosition.flatMap { targetLocation(positionID: $0, point: pointIndex) } }
    var trackedMicrophonePosition: Point3? {
        guard recorder.roomTrackingReady, let frame = recorder.tracking.currentFrame else { return nil }
        let p = frame.camera.transform * SIMD4<Float>(Float(microphoneOffset.x), Float(microphoneOffset.y), Float(microphoneOffset.z), 1)
        return Point3(x: Double(p.x), y: Double(p.y), z: Double(p.z))
    }
    var trackedListenerPose: (position: Point3, facingRadians: Double)? {
        guard recorder.roomTrackingReady, let frame = recorder.tracking.currentFrame else { return nil }
        let transform = frame.camera.transform
        let backward = transform.columns.2
        guard let facing = ListenerOrientation.facing(cameraBackward: Point3(x: Double(backward.x), y: Double(backward.y), z: Double(backward.z))) else { return nil }
        let p = transform * SIMD4<Float>(Float(microphoneOffset.x), Float(microphoneOffset.y), Float(microphoneOffset.z), 1)
        return (Point3(x: Double(p.x), y: Double(p.y), z: Double(p.z)), facing)
    }
    private var peer: SecurePeer?
    private var credentials: PeerCredentials?
    private let recorder = MeasurementRecorder()
    private var active: SweepRequest?
    private var captureOutputVolume: Double?
    private var transactionOutputVolume: Double?
    private var transactionID = UUID()
    private var watchdog: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var awaitingFinalResult = false
    private var verificationCaptureIDs = Set<UUID>()
    private struct TrackingArchive: Codable { var roomID: UUID; var capturedAt: Date; var worldMap: Data }
    private var awaitingAcceptance = false
    private var captureStartedAt = Date()
    private enum CaptureStage { case waitingReady, preparing, recording, uploading }
    private var captureStage = CaptureStage.waitingReady
    private var savedRoomBytes: Data?
    private struct PlannedSignal { var name: String; var connection: ChannelConnection; var mode: SweepSignalMode }
    private var signals: [PlannedSignal] = []
    var canMeasure: Bool { guided && !sessionPaused && !measuring && connected && supported }
    var positionTestCount: Int { purpose == .calibration ? signals.count : 1 }
    var positionTestNumber: Int { purpose == .calibration ? speakerIndex + 1 : 1 }
    var captureLabel: String {
        if purpose == .systemBefore { return "All Speakers — Before Correction" }
        if purpose == .systemAfter { return "All Speakers — After Correction" }
        return signals.indices.contains(speakerIndex) ? signals[speakerIndex].name : "Begin a guided measurement first."
    }
    var captureOutputLabel: String {
        guard purpose == .calibration, signals.indices.contains(speakerIndex) else { return "Complete-system check" }
        let signal = signals[speakerIndex]
        let device = outputs.first(where: { $0.id == signal.connection.outputID })?.name ?? signal.name
        let channel = signal.mode == .linkedCombined ? "Linked Stereo" : signal.connection.channel == 0 ? "Left Channel" : "Right Channel"
        return "\(device) · \(channel)"
    }
    static let pointNames = ["Center", "Left 20 cm", "Right 20 cm", "Forward 20 cm", "Back 20 cm", "Forward-left 14 cm", "Forward-right 14 cm", "Back-left 14 cm", "Back-right 14 cm"]
    var supported: Bool { RoomCaptureSession.isSupported && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }
    var measurableSpeakers: [PhysicalSpeaker] { room.speakers.filter { $0.connection != nil && !$0.linkedSubwoofer } }
    var assignableOutputs: [AudioOutput] { connected ? outputs.filter { $0.available && !$0.id.isEmpty && $0.channels > 0 } : [] }
    private static let outputCacheLimit = 128
    private static let outputCacheByteLimit = 131_072
    private var storage: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    init() {
        if let data = try? Data(contentsOf: storage.appendingPathComponent("room.json")), let stored = try? JSONDecoder().decode(RoomModel.self, from: data) { room = stored; selectedPosition = room.positions.first?.id }
        if let data = try? Data(contentsOf: storage.appendingPathComponent("verified-profile.json")) { profile = try? JSONDecoder().decode(CalibrationProfile.self, from: data) }
        scanned = FileManager.default.fileExists(atPath: storage.appendingPathComponent("lidar-room.json").path)
        loadOutputNames()
        savedRoomBytes = try? Self.roomBytes(room)
    }
    private static func roomBytes(_ room: RoomModel) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(room) }
    private func invalidateChangedConditions() {
        guard let conditions = profile?.conditions,
              reportedMasterVolume.map({ conditions.outputVolume != $0 }) == true || conditions.furnitureRevision != furnitureRevision else { return }
        profile?.state = .needsVerification
        do { try JSONEncoder().encode(profile).write(to: storage.appendingPathComponent("verified-profile.json"), options: [.atomic, .completeFileProtection]) } catch { self.error = error.localizedDescription }
    }
    func saveRoom(sendToMac: Bool = true) {
        do {
            let bytes = try Self.roomBytes(room)
            try bytes.write(to: storage.appendingPathComponent("room.json"), options: [.atomic, .completeFileProtection])
            if bytes != savedRoomBytes, profile != nil { profile?.state = .needsVerification; try JSONEncoder().encode(profile).write(to: storage.appendingPathComponent("verified-profile.json"), options: [.atomic, .completeFileProtection]) }
            savedRoomBytes = bytes
            if connected && sendToMac { sendRoomToMac() }
        } catch { self.error = error.localizedDescription }
    }
    private func sendRoomToMac() {
        guard connected, let currentPeer = peer else { return }
        currentPeer.send(.room(room)) { [weak self, weak currentPeer] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, let currentPeer, self.peer === currentPeer else { return }
                self.peer = nil; self.connected = false
                self.fail("Room changes are saved on this phone but could not be sent to the Mac: \(error.localizedDescription)")
                currentPeer.cancel()
            }
        }
    }
    func refreshOutputs() {
        guard connected, let currentPeer = peer else { error = "Connect to the Mac before refreshing actual outputs."; return }
        currentPeer.send(.requestOutputs) { [weak self, weak currentPeer] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, let currentPeer, self.peer === currentPeer else { return }
                self.peer = nil; self.connected = false
                self.error = "Could not refresh outputs from the Mac: \(error.localizedDescription)"
                currentPeer.cancel()
            }
        }
    }
    private func loadOutputNames() {
        let url = storage.appendingPathComponent("output-names.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.outputCacheByteLimit,
              let data = try? Data(contentsOf: url), data.count <= Self.outputCacheByteLimit,
              var cached = try? JSONDecoder().decode([AudioOutput].self, from: data),
              cached.count <= Self.outputCacheLimit else { return }
        for index in cached.indices { cached[index].available = false }
        outputs = cached
    }
    private func updateOutputs(_ discovered: [AudioOutput]) {
        let discoveredIDs = Set(discovered.map(\.id))
        let previousNames = outputs.filter { !discoveredIDs.contains($0.id) }.map { output in
            var cached = output; cached.available = false; return cached
        }
        outputs = discovered + previousNames.prefix(Self.outputCacheLimit)
        let assignedIDs = Set(room.speakers.compactMap { $0.connection?.outputID })
        let ordered = outputs.filter { assignedIDs.contains($0.id) } + outputs.filter { !assignedIDs.contains($0.id) }
        var cached = Array(ordered.prefix(Self.outputCacheLimit))
        for index in cached.indices { cached[index].available = false }
        do {
            let bytes = try JSONEncoder().encode(cached)
            guard bytes.count <= Self.outputCacheByteLimit else { return }
            try bytes.write(to: storage.appendingPathComponent("output-names.json"), options: [.atomic, .completeFileProtection])
        } catch { self.error = "Outputs refreshed, but their names could not be saved for offline display: \(error.localizedDescription)" }
    }
    func saveScan(_ captured: CapturedRoom) {
        do {
            let archive = try JSONEncoder().encode(captured)
            var surfaces: [ScannedSurface] = []
            for (category, group) in [("wall", captured.walls), ("door", captured.doors), ("window", captured.windows), ("opening", captured.openings), ("floor", captured.floors)] {
                for surface in group {
                    let matrix = surface.transform
                    let values = (0..<4).flatMap { column in (0..<4).map { row in Double(matrix[column][row]) } }
                    surfaces.append(ScannedSurface(id: surface.identifier, category: category, dimensions: Point3(x: Double(surface.dimensions.x), y: Double(surface.dimensions.y), z: Double(surface.dimensions.z)), transform: values))
                }
            }
            room.geometry = ScannedGeometry(surfaces: surfaces, capturedAt: Date(), roomPlanArchive: archive)
            try archive.write(to: storage.appendingPathComponent("lidar-room.json"), options: [.atomic, .completeFileProtection])
            scanned = true; saveRoom(); status = "Room scanned. Add speakers and listener positions in the same scan coordinate system (meters)."
            recorder.useScannedCoordinateSystem()
            let roomID = room.id, capturedAt = room.geometry!.capturedAt
            recorder.tracking.getCurrentWorldMap { [weak self] map, error in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        guard let map else { throw error ?? CaptureError.rejected("No relocalization map is available. Rescan before restarting the app.") }
                        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                        let archive = TrackingArchive(roomID: roomID, capturedAt: capturedAt, worldMap: data)
                        try JSONEncoder().encode(archive).write(to: self.storage.appendingPathComponent("room.worldmap"), options: [.atomic, .completeFileProtection])
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        catch { self.error = error.localizedDescription }
    }
    func relocalizeRoom() {
        guard !guided || sessionPaused else { return }
        do {
            let archive = try JSONDecoder().decode(TrackingArchive.self, from: Data(contentsOf: storage.appendingPathComponent("room.worldmap")))
            guard archive.roomID == room.id, archive.capturedAt == room.geometry?.capturedAt,
                  let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: archive.worldMap) else { throw CaptureError.rejected("The saved tracking map does not match this room. Scan the room again.") }
            recorder.restoreRoomTracking(map); status = "Look around the scanned room until camera tracking relocalizes. Live coordinates appear below when ready."
        } catch { self.error = error.localizedDescription }
    }
    func pair(_ text: String) {
        do {
            let code = try PairingCode.decode(text)
            connect(PeerCredentials(peerID: code.peerID, host: code.host, port: code.port, secret: code.secret))
        } catch { self.error = error.localizedDescription }
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = positionRunActive && applicationIsActive && !sessionPaused
    }
    func applicationWillResignActive() { applicationIsActive = false; updateIdleTimer() }
    func applicationDidEnterBackground() {
        applicationIsActive = false; updateIdleTimer()
        reconnectOnReturn = connected || sessionInProgress
        if sessionInProgress { suspendCalibration() }
        let previous = peer; peer = nil; connected = false
        previous?.cancel()
    }
    func applicationBecameActive() {
        applicationIsActive = true; updateIdleTimer()
        if positionRunActive && !sessionPaused && connected { scheduleNextCapture() }
        if sessionPaused && !roomTrackingReady { relocalizeRoom() }
        guard reconnectOnReturn else { return }
        reconnectOnReturn = false; reconnect()
    }
    private func suspendCalibration() {
        guard sessionInProgress else { return }
        sessionPaused = true; resumePending = false
        nextCaptureTask?.cancel(); nextCaptureTask = nil
        watchdog?.cancel(); captureTask?.cancel(); recorder.discard(); measuring = false
        captureOutputVolume = nil
        peer?.send(.pauseCalibration(transactionID: transactionID))
        status = "Calibration paused. Your accepted measurements are kept."
    }
    private func rejectCurrentCapture(_ reason: String, request: SweepRequest) {
        guard request.transactionID == transactionID, active?.captureID == request.captureID else { return }
        suspendCalibration()
        captureRetryReason = reason
        error = nil
        status = "\(reason)\nYour earlier measurements are kept. Retry only this sample."
    }
    func resumeCalibration() {
        guard sessionPaused, !resumePending else { return }
        guard connected, let peer else { reconnect(); return }
        guard roomTrackingReady else { error = "Align the room, then resume calibration."; return }
        resumePending = true
        peer.send(.resumeCalibration(transactionID: transactionID)) { [weak self, weak peer] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, self.peer === peer else { return }
                self.resumePending = false
                self.error = "Couldn’t reconnect to the Mac. Check Wi-Fi and try Resume again."
            }
        }
    }
    func reconnect() {
        do {
            guard let text = UserDefaults.standard.string(forKey: "lastPeer"), let id = UUID(uuidString: text), let saved = try PeerKeychain.load(peerID: id) else { throw CaptureError.rejected("No saved Mac. Scan a fresh pairing QR code.") }
            connect(saved)
        } catch { self.error = error.localizedDescription }
    }
    private func connect(_ credentials: PeerCredentials) {
        let preservingSession = sessionInProgress && sessionPaused
        if !preservingSession { cancel() }
        peer?.cancel(); peer = nil; connected = false; resumePending = preservingSession
        do {
            let next = try SecurePeer(credentials: credentials); self.credentials = credentials; peer = next
            next.onReady = { [weak self, weak next] in Task { @MainActor in
                guard let self, let next, self.peer === next else { return }
                self.connected = true; self.status = "Authenticated encrypted connection established."
                if let cancelled = self.deferredCancellation {
                    next.send(.cancel(transactionID: cancelled)); self.deferredCancellation = nil
                }
                self.refreshOutputs()
                self.resumePending = false
                if preservingSession {
                    self.status = "Your measurements are kept. Align the room and tap Resume."
                } else { self.sendRoomToMac() }
            } }
            next.onMessage = { [weak self, weak next] message in Task { @MainActor in
                guard let self, let next, self.peer === next else { return }; await self.receive(message)
            } }
            next.onError = { [weak self, weak next] error in Task { @MainActor in
                guard let self, let next, self.peer === next else { return }
                self.peer = nil; self.connected = false; self.resumePending = false
                if self.sessionInProgress { self.suspendCalibration() }
                else {
                    self.error = "The Mac connection was interrupted. Reconnect to continue."
                    self.status = "Not connected"
                }
            } }
            next.start(); status = "Authenticating Mac…"
        } catch { resumePending = false; self.error = error.localizedDescription }
    }
    func setPlaybackVolume(_ volume: Double) {
        guard connected, !sessionInProgress, !volumeRequestPending, volume.isFinite, (0...1).contains(volume), let peer else { return }
        volumeRequestPending = true
        peer.send(.setPlaybackVolume(masterVolume: volume)) { [weak self, weak peer] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.peer === peer else { return }
                self.volumeRequestPending = false; self.error = error.localizedDescription
            }
        }
    }
    func beginPosition() {
        guard supported, connected, scanned, selectedPosition != nil, !measurableSpeakers.isEmpty else { error = "A LiDAR iPhone, scanned room, connected Mac, listener position, and mapped speaker are required."; return }
        guard !sessionInProgress else { return }
        guard !volumeRequestPending, let volume = reportedMasterVolume, volume > 0 else { error = "Choose a measurement level above zero before starting."; return }
        guard recorder.roomTrackingReady else { error = "Relocalize to the scanned room before beginning."; return }
        verificationCaptureIDs.removeAll(); awaitingFinalResult = false; transactionOutputVolume = nil; captureOutputVolume = nil
        measurementGrid = nil
        signals = measurableSpeakers.compactMap { speaker in speaker.connection.map { PlannedSignal(name: speaker.name, connection: $0, mode: .channel) } }
        var seen = Set<String>()
        for speaker in measurableSpeakers where !speaker.timingGroupID.isEmpty {
            if seen.insert(speaker.timingGroupID).inserted, measurableSpeakers.filter({ $0.timingGroupID == speaker.timingGroupID }).count > 1, let connection = speaker.connection {
                signals.append(PlannedSignal(name: "Combined linked group: \(speaker.name)", connection: connection, mode: .linkedCombined))
            }
        }
        sendRoomToMac()
        transactionID = UUID(); sequence = CalibrationSequence(signalCount: signals.count); guided = true
        startPositionMeasurements()
    }
    func startPositionMeasurements() {
        guard canMeasure, applicationIsActive else { return }
        positionRunActive = true
        measurePoint()
    }
    func pausePositionMeasurements() { suspendCalibration() }
    private func scheduleNextCapture() {
        nextCaptureTask?.cancel()
        guard positionRunActive, canMeasure, applicationIsActive else { return }
        let transaction = transactionID
        nextCaptureTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.transactionID == transaction,
                  self.positionRunActive, self.canMeasure, self.applicationIsActive else { return }
            self.measurePoint()
        }
    }
    private func measurePoint() {
        guard canMeasure, let currentPeer = peer, let positionID = selectedPosition, signals.indices.contains(speakerIndex) else { return }
        let signal = signals[speakerIndex], connection = signal.connection
        guard outputs.contains(where: { $0.id == connection.outputID && $0.available && connection.channel >= 0 && connection.channel < $0.channels }) else {
            positionRunActive = false; error = "Selected output channel is unavailable."; return
        }
        guard let actual = trackedMicrophonePosition, let listener = room.positions.first(where: { $0.id == positionID }) else {
            suspendCalibration(); status = "Align the room to continue this position."; return
        }
        if measurementGrid == nil {
            guard pointIndex == 0, speakerIndex == 0, purpose == .calibration else { return }
            measurementGrid = MeasurementGrid(center: actual, facingRadians: listener.facingRadians)
        }
        let request = SweepRequest(transactionID: transactionID, captureID: UUID(), positionID: positionID, pointIndex: pointIndex, connection: connection, purpose: purpose, signalMode: purpose == .calibration ? signal.mode : .system)
        active = request; captureOutputVolume = nil; measuring = true; awaitingAcceptance = false; status = "Requesting \(captureLabel)…"
        captureStage = .waitingReady
        currentPeer.send(.sweepRequest(request)) { [weak self, weak currentPeer] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, let currentPeer, self.peer === currentPeer,
                      self.active?.captureID == request.captureID, self.transactionID == request.transactionID else { return }
                self.fail(error.localizedDescription)
            }
        }
        watchdog?.cancel(); watchdog = Task { [weak self] in try? await Task.sleep(for: .seconds(45)); if !Task.isCancelled { self?.fail("Measurement timed out. Previous profile remains unchanged.") } }
    }
    func cancel() {
        if guided || awaitingFinalResult {
            if let peer { peer.send(.cancel(transactionID: transactionID)) }
            else { deferredCancellation = transactionID }
        }
        transactionID = UUID(); watchdog?.cancel(); captureTask?.cancel(); recorder.discard(); active = nil; measuring = false; guided = false; awaitingFinalResult = false; verificationCaptureIDs.removeAll(); awaitingAcceptance = false; status = "Cancelled. Previous profile retained."
        captureOutputVolume = nil; transactionOutputVolume = nil
        measurementGrid = nil; volumeRequestPending = false
        sessionPaused = false; resumePending = false
        nextCaptureTask?.cancel(); nextCaptureTask = nil; positionRunActive = false; sequence = nil
        captureRetryReason = nil
    }
    private func receive(_ message: WireMessage) async {
        do {
            switch message {
            case .paired(let peerID, let secret):
                guard var credentials, credentials.peerID == peerID, secret.count == 32 else { throw WireError.invalidPairingCode }
                credentials.secret = secret; try PeerKeychain.save(credentials); self.credentials = credentials; UserDefaults.standard.set(peerID.uuidString, forKey: "lastPeer")
            case .outputs(let outputs): updateOutputs(outputs)
            case .playbackState(let masterVolume):
                guard masterVolume.isFinite, (0...1).contains(masterVolume) else {
                    reportedMasterVolume = nil
                    throw CaptureError.rejected("Mac reported an invalid playback level.")
                }
                reportedMasterVolume = masterVolume
                volumeRequestPending = false
                if let transactionOutputVolume, masterVolume != transactionOutputVolume {
                    throw CaptureError.rejected("Mac playback volume changed during measurement. Previous profile retained.")
                }
                if !sessionInProgress { invalidateChangedConditions() }
            case .room(let room):
                guard !sessionInProgress else { throw WireError.unexpectedMessage }
                if room.geometry?.capturedAt != self.room.geometry?.capturedAt || room.id != self.room.id { recorder.invalidateRoomTracking() }
                self.room = room; selectedPosition = room.positions.first?.id; scanned = room.geometry != nil; saveRoom(sendToMac: false)
            case .calibrationResumed(let id, let available, let acceptedCaptureIDs):
                guard id == transactionID, sessionPaused else { return }
                guard acceptedCaptureIDs.count <= RoomtasticProtocol.maxSessionCaptures, Set(acceptedCaptureIDs).count == acceptedCaptureIDs.count else { throw WireError.unexpectedMessage }
                resumePending = false
                if !available {
                    guard transactionOutputVolume == nil, pointIndex == 0, speakerIndex == 0, purpose == .calibration else {
                        throw CaptureError.rejected("This calibration session is no longer available on the Mac. Start a new calibration.")
                    }
                    transactionID = UUID(); active = nil; awaitingAcceptance = false
                    sendRoomToMac()
                } else if let pending = active, acceptedCaptureIDs.contains(pending.captureID) {
                    advanceAcceptedCapture()
                } else {
                    if let pending = active { verificationCaptureIDs.remove(pending.captureID) }
                    active = nil; awaitingAcceptance = false
                }
                sessionPaused = false; measuring = false
                captureRetryReason = nil
                if guided { status = "Continue at \(Self.pointNames[pointIndex]). \(captureLabel)." }
                scheduleNextCapture()
            case .sweepReady(let captureID, let duration, let outputVolume):
                guard !sessionPaused else { return }
                guard let active, active.captureID == captureID, captureStage == .waitingReady, duration.isFinite, duration > 0, duration <= 25 else { throw WireError.unexpectedMessage }
                guard outputVolume.isFinite, outputVolume > 0, outputVolume <= 1 else {
                    throw CaptureError.rejected("The Mac must report a valid, nonzero playback level before capture.")
                }
                if let transactionOutputVolume, outputVolume != transactionOutputVolume {
                    throw CaptureError.rejected("Mac playback volume changed between captures. Previous profile retained.")
                }
                transactionOutputVolume = outputVolume
                captureOutputVolume = outputVolume
                reportedMasterVolume = outputVolume
                captureStage = .preparing
                captureTask = Task { [weak self] in await self?.prepareCapture(active) }
            case .sweepFinished(let captureID):
                guard !sessionPaused else { return }
                guard let active, active.captureID == captureID, captureStage == .recording else { throw WireError.unexpectedMessage }
                captureStage = .uploading
                captureTask = Task { [weak self] in await self?.finishCapture(active) }
            case .progress(let id, let fraction, let message):
                if id == transactionID && !sessionPaused {
                    status = message
                    if fraction >= 1, awaitingAcceptance, guided { advanceAcceptedCapture() }
                }
            case .result(let id, let candidate):
                guard id == transactionID else { return }
                let finalCapturePending = guided && purpose == .systemAfter && pointIndex == 8 && awaitingAcceptance
                guard let transactionOutputVolume, (awaitingFinalResult || finalCapturePending), candidate.hasMeasuredVerification,
                      candidate.positionID == selectedPosition, verificationCaptureIDs.count == 18,
                      verificationCaptureIDs.isSubset(of: Set(candidate.provenance?.captureIDs ?? [])),
                      Set(candidate.outputIDs) == Set(measurableSpeakers.compactMap { $0.connection?.outputID }),
                      candidate.conditions?.outputVolume == transactionOutputVolume,
                      candidate.provenance?.conditions.outputVolume == transactionOutputVolume,
                      candidate.conditions?.furnitureRevision == furnitureRevision else { throw WireError.verificationRequired }
                try JSONEncoder().encode(candidate).write(to: storage.appendingPathComponent("verified-profile.json"), options: [.atomic, .completeFileProtection])
                profile = candidate; watchdog?.cancel(); guided = false; awaitingFinalResult = false; measuring = false; active = nil; awaitingAcceptance = false; status = "Measured verification passed. Profile saved on Mac and phone."
                captureOutputVolume = nil; self.transactionOutputVolume = nil
                sessionPaused = false; resumePending = false
                nextCaptureTask?.cancel(); nextCaptureTask = nil; positionRunActive = false
                captureRetryReason = nil
            case .captureRejected(let id, let captureID, let reason):
                guard id == transactionID, let request = active, request.captureID == captureID else { return }
                rejectCurrentCapture(reason, request: request)
            case .failure(let id, let reason): if id == nil || id == transactionID { fail(reason) }
            default: throw WireError.unexpectedMessage
            }
        } catch { fail(error.localizedDescription) }
    }
    private func prepareCapture(_ request: SweepRequest) async {
        do {
            captureStartedAt = Date()
            try await recorder.start(microphoneOffset: microphoneOffset)
            try Task.checkCancellation()
            guard request.transactionID == transactionID, active?.captureID == request.captureID else { return }
            status = "Preparing microphone…"
            try await recorder.waitForAmbient()
            try Task.checkCancellation()
            guard request.transactionID == transactionID, active?.captureID == request.captureID else { return }
            captureStage = .recording
            try await peer?.send(.captureArmed(captureID: request.captureID))
            if request.transactionID == transactionID { status = "Recording. Keep the microphone near this spot." }
        } catch let error as CaptureError {
            if !sessionPaused && !Task.isCancelled { rejectCurrentCapture(error.localizedDescription, request: request) }
        } catch {
            if request.transactionID == transactionID && !sessionPaused && !Task.isCancelled { fail(error.localizedDescription) }
        }
    }
    private func finishCapture(_ request: SweepRequest) async {
        do {
            try await Task.sleep(for: .milliseconds(250))
            guard request.transactionID == transactionID, active?.captureID == request.captureID else { return }
            let recording = try recorder.finish()
            await upload(recording, request: request)
        } catch let error as CaptureError {
            if !sessionPaused && !Task.isCancelled { rejectCurrentCapture(error.localizedDescription, request: request) }
        } catch {
            if request.transactionID == transactionID && !sessionPaused && !Task.isCancelled { fail(error.localizedDescription) }
        }
    }
    private func targetLocation(positionID: UUID, point: Int) -> Point3? {
        guard selectedPosition == positionID else { return nil }
        return measurementGrid?.target(pointIndex: point)
    }
    private func upload(_ recording: MeasurementRecorder.Recording, request: SweepRequest) async {
        do {
            guard let peer else { throw WireError.disconnected }
            guard active?.captureID == request.captureID, request.transactionID == transactionID,
                  let captureOutputVolume, captureOutputVolume.isFinite, captureOutputVolume > 0, captureOutputVolume <= 1,
                  transactionOutputVolume == captureOutputVolume else {
                throw CaptureError.rejected("The capture has no unchanged, valid Mac playback level.")
            }
            var bytes = recording.samples.withUnsafeBytes { Data($0) }
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            let conditions = MeasurementConditions(microphoneID: recording.microphoneID, microphoneOrientation: "upright, screen toward listener, built-in microphone", sampleRate: recording.sampleRate, outputVolume: captureOutputVolume, furnitureRevision: furnitureRevision, ambientNoiseDBFS: recording.noiseDBFS, capturedAt: captureStartedAt)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let metadata = CaptureMetadata(transactionID: request.transactionID, captureID: request.captureID, pointIndex: request.pointIndex, sampleRate: recording.sampleRate, sampleCount: recording.samples.count, conditions: conditions, sha256: digest, retainRaw: retainRaw, location: recording.location, motionMaxTranslationMeters: recording.motionMaxTranslationMeters, motionMaxRotationRadians: recording.motionMaxRotationRadians, interrupted: false)
            try JSONEncoder().encode(metadata).write(to: storage.appendingPathComponent("measurement-\(request.captureID).json"), options: [.atomic, .completeFileProtection])
            try await peer.send(.captureStart(metadata))
            for offset in stride(from: 0, to: bytes.count, by: RoomtasticProtocol.maxChunkBytes) {
                try Task.checkCancellation()
                try await peer.send(.captureChunk(captureID: request.captureID, offset: offset, bytes: bytes.subdata(in: offset..<min(bytes.count, offset + RoomtasticProtocol.maxChunkBytes))))
            }
            try Task.checkCancellation()
            guard request.transactionID == transactionID else { return }
            if request.purpose != .calibration { verificationCaptureIDs.insert(request.captureID) }
            awaitingAcceptance = true
            try await peer.send(.captureEnd(captureID: request.captureID))
            if retainRaw { try bytes.write(to: storage.appendingPathComponent("capture-\(request.captureID).f32"), options: [.atomic, .completeFileProtection]) }
            if awaitingAcceptance { status = "Uploaded. Waiting for Mac analysis and acceptance before proceeding." }
        } catch { if request.transactionID == transactionID && !sessionPaused && !Task.isCancelled { fail(error.localizedDescription) } }
    }
    private func advanceAcceptedCapture() {
        awaitingAcceptance = false; watchdog?.cancel(); active = nil; captureOutputVolume = nil; measuring = false
        guard let next = sequence?.acceptCapture() else { return }
        switch next {
        case .channel:
            status = "Stay at \(Self.pointNames[pointIndex]). Next: \(captureLabel)."
            scheduleNextCapture()
        case .position:
            positionRunActive = false
            status = "Position complete. Move to \(Self.pointNames[pointIndex]), then tap Measure This Position."
        case .finished:
            positionRunActive = false; guided = false; awaitingFinalResult = true
            status = "All measurements accepted. Waiting for verification."
        }
    }
    func deleteRaw() {
        do {
            for url in try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil) where url.pathExtension == "f32" { try FileManager.default.removeItem(at: url) }
            if connected {
                peer?.send(.deleteRetainedRecordings) { [weak self] error in Task { @MainActor in if let error { self?.error = error.localizedDescription } } }
                status = "Local raw recordings deleted. Deletion requested on the connected Mac."
            } else { status = "Local raw recordings deleted. Mac deletion is pending: reconnect and tap Delete again." }
        } catch { self.error = error.localizedDescription }
    }
    private func fail(_ reason: String) {
        if !applicationIsActive && sessionInProgress { suspendCalibration(); return }
        cancel(); error = reason; status = "Measurement rejected. Previous profile retained."
    }
}
