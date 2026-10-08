// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import SystemConfiguration
import RoomtasticShared
import RoomtasticTransport
import RoomtasticCalibration
import RoomtasticControl

@MainActor final class PhoneCoordinator {
    unowned let service: Service
    private var listener: PairingListener?, peer: SecurePeer?
    private let receiver = CaptureReceiver()
    private let analysisQueue = DispatchQueue(label: "org.roomtastic.analysis", qos: .userInitiated)
    private var request: SweepRequest?, reference: CalibrationSweep?
    private var transactionID: UUID?, baselineDigest = "", candidateDigest = ""
    private var measurements: [String: [AcousticMeasurement]] = [:]
    private var before: [AcousticMeasurement] = [], after: [AcousticMeasurement] = []
    private var candidate: CalibrationProfile?, candidateCreated = Date()
    private var previousState: RoomtasticControl.ControlState?
    private var armed = false, playbackFinished = false, analyzing = false
    private var credentials: PeerCredentials?
    private var lastConditions: MeasurementConditions?
    private var captureOutputVolume: Double?
    private var sessionGeneration = UUID()
    private var transactionGeneration = UUID(), positionID: UUID?
    private var usedCaptureIDs = Set<UUID>(), completedTransactionIDs = Set<UUID>()
    private var paused = false
    private var needsQuietLead = false
    private var pauseExpiry: Task<Void, Never>?
    private var completedResult: (transactionID: UUID, profile: CalibrationProfile)?
    var isMeasuring: Bool { transactionID != nil }
    init(service: Service) {
        self.service = service
        let file = ControlSocket.directory.appendingPathComponent("phone-peer.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4096 else { throw AudioFailure("Saved phone identity exceeds the storage limit") }
                let id = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: file))
                guard let credentials = try PeerKeychain.load(peerID: id) else { throw AudioFailure("Saved phone pairing key is missing; pair the phone again") }
                self.credentials = credentials; try listen(credentials)
            } catch { service.state.error = "Cannot restore phone pairing: \(error.localizedDescription)" }
        }
    }
    func beginPairing() throws -> String {
        guard !isMeasuring else { throw AudioFailure("Finish or cancel calibration before pairing another phone") }
        sessionGeneration = UUID(); peer?.cancel(); peer = nil; listener?.stop()
        guard let host = SCDynamicStoreCopyLocalHostName(nil) as String? else { throw AudioFailure("Cannot determine local Mac hostname") }
        let code = try PairingListener.makeCode(host: host + ".local", port: 49731)
        let next = try PairingListener(code: code); install(next, rotate: true); next.start()
        return try code.encodedString()
    }
    private func listen(_ credentials: PeerCredentials) throws { let next = try PairingListener(credentials: credentials); install(next, rotate: false); next.start() }
    private func install(_ next: PairingListener, rotate: Bool) {
        listener = next; sessionGeneration = UUID()
        let generation = sessionGeneration
        let listenerCredentials = next.credentials
        next.onError = { [weak self] error in DispatchQueue.main.async {
            guard let self, self.sessionGeneration == generation else { return }
            self.service.state.error = error.localizedDescription
        } }
        next.onPeer = { [weak self] peer in DispatchQueue.main.async { [weak self, peer] in
            guard let self, !self.service.shuttingDown, self.sessionGeneration == generation else { peer.cancel(); return }
            self.pause()
            self.peer?.cancel(); self.peer = peer; self.service.state.pairingURI = nil
            if !self.isMeasuring { self.usedCaptureIDs.removeAll(); self.completedTransactionIDs.removeAll() }
            peer.onMessage = { [weak self, weak peer] message in DispatchQueue.main.async {
                guard let self, self.sessionGeneration == generation, self.peer === peer else { return }
                self.receive(message)
            } }
            peer.onError = { [weak self, weak peer] error in DispatchQueue.main.async {
                guard let self, self.sessionGeneration == generation, self.peer === peer else { return }
                self.pause(); self.peer = nil
                if rotate, let credentials = self.credentials {
                    do { try self.listen(credentials) } catch { self.service.state.error = "Cannot resume phone listener: \(error.localizedDescription)" }
                }
            } }
            do {
                var saved = listenerCredentials
                if rotate { saved.secret = try PairingListener.makeCode(host: saved.host, port: saved.port).secret }
                try PeerKeychain.save(saved); self.credentials = saved
                let data = try JSONEncoder().encode(saved.peerID)
                try data.write(to: ControlSocket.directory.appendingPathComponent("phone-peer.json"), options: .atomic)
                peer.send(.paired(peerID: saved.peerID, reconnectSecret: saved.secret))
            } catch { self.fail(error.localizedDescription); peer.cancel() }
        } }
    }
    func publishPlaybackState() {
        if isMeasuring {
            do { try validateTransactionSetup() }
            catch { fail(error.localizedDescription) }
        }
        peer?.send(.playbackState(masterVolume: Double(service.state.volume)))
    }
    private func receive(_ message: WireMessage) {
        guard !service.shuttingDown else { return }
        do {
            switch message {
            case .requestOutputs:
                peer?.send(.outputs(service.state.outputs))
                publishPlaybackState()
            case .setPlaybackVolume(let volume):
                guard !isMeasuring else { throw AudioFailure("The measurement level is fixed until calibration finishes or is cancelled.") }
                guard volume.isFinite, (0...1).contains(volume) else { throw AudioFailure("Playback volume must be between zero and one.") }
                let result = service.handle(ControlRequest(.configure, volume: Float(volume)))
                if let error = result.error { throw AudioFailure(error) }
            case .room(let room):
                guard !isMeasuring, !service.engine.configurationPending else { throw WireError.unexpectedMessage }
                try Service.validateRoom(room)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                if try encoder.encode(room) != service.room.map({ try encoder.encode($0) }) {
                    let previousRoom = service.room, previousState = service.state
                    service.room = room
                    for i in service.state.profiles.indices { service.state.profiles[i].state = .needsVerification }
                    service.state.calibrationStatus = "Needs verification — room updated"
                    do { try service.persist() } catch { service.room = previousRoom; service.state = previousState; throw error }
                }
            case .sweepRequest(let next): try prepare(next)
            case .captureArmed(let captureID):
                guard let request, request.captureID == captureID else { return }
                guard let reference, transactionID == request.transactionID, !armed else { throw WireError.unexpectedMessage }
                try validateTransactionSetup()
                armed = true
                let generation = transactionGeneration
                guard let anchor = referenceConnection() else { throw AudioFailure("No acoustic reference speaker is mapped") }
                try service.engine.playMeasurement(reference, target: request.connection, mode: request.signalMode, referenceConnection: anchor) { [weak self] in DispatchQueue.main.async {
                    guard let self, self.matches(request, generation: generation) else { return }
                    self.playbackFinished = true; self.peer?.send(.sweepFinished(captureID: captureID))
                } }
            case .captureStart(let metadata):
                guard let request, request.captureID == metadata.captureID, request.transactionID == metadata.transactionID else { return }
                guard request.pointIndex == metadata.pointIndex, armed, playbackFinished, !analyzing else { throw WireError.unexpectedMessage }
                try validateTransactionSetup(); try validate(metadata)
                try receiver.begin(metadata)
            case .captureChunk(let captureID, let offset, let bytes):
                guard request?.captureID == captureID else { return }
                guard !analyzing else { throw WireError.unexpectedMessage }
                try receiver.append(captureID: captureID, offset: offset, chunk: bytes)
            case .captureEnd(let captureID):
                guard let request, request.captureID == captureID else { return }
                guard let reference, !analyzing else { throw WireError.unexpectedMessage }
                let (metadata, samples) = try receiver.finish(captureID: captureID)
                try analyze(metadata: metadata, samples: samples, request: request, reference: reference)
            case .deleteRetainedRecordings:
                guard !isMeasuring else { throw AudioFailure("Finish calibration before deleting retained recordings") }
                let directory = ControlSocket.directory.appendingPathComponent("Retained Recordings", isDirectory: true)
                if FileManager.default.fileExists(atPath: directory.path) {
                    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "f32le" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                        try FileManager.default.removeItem(at: file)
                    }
                }
            case .cancel(let cancelled):
                guard transactionID == cancelled else { return }
                fail("Calibration cancelled; previous profile retained")
            case .pauseCalibration(let id):
                if transactionID == id { pause() }
            case .resumeCalibration(let id):
                if let completedResult, completedResult.transactionID == id {
                    peer?.send(.result(transactionID: id, profile: completedResult.profile))
                } else if transactionID == id {
                    try validateTransactionSetup()
                    pauseExpiry?.cancel(); pauseExpiry = nil; paused = false
                    var accepted: [UUID] = []
                    accepted.reserveCapacity(usedCaptureIDs.count)
                    accepted.append(contentsOf: measurements.values.joined().lazy.map(\.recordingID))
                    accepted.append(contentsOf: before.lazy.map(\.recordingID))
                    accepted.append(contentsOf: after.lazy.map(\.recordingID))
                    service.state.calibrationStatus = "Calibration resumed"
                    peer?.send(.calibrationResumed(transactionID: id, available: true, acceptedCaptureIDs: accepted))
                } else {
                    peer?.send(.calibrationResumed(transactionID: id, available: false, acceptedCaptureIDs: []))
                }
            default: throw WireError.unexpectedMessage
            }
        } catch {
            if isMeasuring { fail(error.localizedDescription) }
            else { service.state.error = error.localizedDescription; peer?.send(.failure(transactionID: nil, reason: error.localizedDescription)) }
        }
    }
    private func prepare(_ next: SweepRequest) throws {
        service.refresh()
        guard request == nil, !analyzing, !paused, !service.shuttingDown, (0...8).contains(next.pointIndex), let room = service.room,
              room.positions.contains(where: { $0.id == next.positionID }), service.state.running, !service.state.muted, service.state.volume.isFinite, service.state.volume > 0, service.state.volume <= 1 else { throw AudioFailure("Activate playback, unmute, and select a scanned listening position before measuring") }
        guard !service.engine.configurationPending else { throw AudioFailure("Wait for speaker synchronization before beginning calibration") }
        try validateMeasurementSetup()
        guard service.state.selected.contains(next.connection.outputID),
              room.speakers.contains(where: { !$0.linkedSubwoofer && $0.connection == next.connection }) else { throw AudioFailure("Measurement target does not match the mapped system") }
        switch (next.purpose, next.signalMode) {
        case (.calibration, .channel), (.calibration, .linkedCombined), (.systemBefore, .system), (.systemAfter, .system): break
        default: throw AudioFailure("Measurement signal mode does not match its purpose")
        }
        if next.signalMode == .linkedCombined {
            guard let speaker = room.speakers.first(where: { $0.connection == next.connection }), !speaker.timingGroupID.isEmpty else { throw AudioFailure("Combined measurement requires a linked stereo group") }
            let group = room.speakers.filter { !$0.linkedSubwoofer && $0.timingGroupID == speaker.timingGroupID }
            guard group.count == 2, Set(group.compactMap(\.connection)) == Set([ChannelConnection(outputID: next.connection.outputID, channel: 0), ChannelConnection(outputID: next.connection.outputID, channel: 1)]) else { throw AudioFailure("Combined measurement must target both channels of one linked stereo output") }
        }
        guard !usedCaptureIDs.contains(next.captureID), usedCaptureIDs.count < RoomtasticProtocol.maxSessionCaptures else { throw AudioFailure("Capture identity was reused or this phone connection reached its capture limit") }
        if transactionID == nil {
            guard !completedTransactionIDs.contains(next.transactionID), completedTransactionIDs.count < 1024 else { throw AudioFailure("Calibration transaction identity was reused; reconnect the phone") }
            let digest = try service.digest()
            transactionGeneration = UUID(); transactionID = next.transactionID; positionID = next.positionID
            previousState = service.state; baselineDigest = digest
            measurements.removeAll(); before.removeAll(); after.removeAll(); candidate = nil; lastConditions = nil
        }
        guard transactionID == next.transactionID, positionID == next.positionID else { throw WireError.unexpectedMessage }
        try validateTransactionSetup()
        guard candidate == nil || next.purpose == .systemAfter else { throw AudioFailure("Candidate verification has begun; start a new transaction to change baseline measurements") }
        service.invalidateMeasurementCallbacks()
        let beganSession = service.engine.beginMeasurementSession()
        let quietLead = beganSession || needsQuietLead ? service.engine.lead + 0.25 : 0
        needsQuietLead = false
        if next.purpose == .systemAfter {
            guard before.count == 9 else { throw AudioFailure("Nine fresh complete-system baseline measurements are required") }
            if candidate == nil { try fit(positionID: next.positionID) }
            try service.configureEngine(mixes: candidate!.mixes)
        } else { try service.configureEngine(mixes: []) }
        service.engine.setControls(volume: service.state.volume, muted: false, bypass: false)
        request = next; usedCaptureIDs.insert(next.captureID); armed = false; playbackFinished = false
        let outputVolume = Double(service.state.volume)
        captureOutputVolume = outputVolume
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: service.engine.sampleRate, duration: 1, guardInterval: sweepGuardInterval(for: next))
        reference = sweep
        service.state.calibrationStatus = "Measuring point \(next.pointIndex + 1) of 9 — \(next.purpose.rawValue)"
        let generation = transactionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + quietLead) { [weak self] in
            guard let self, self.matches(next, generation: generation) else { return }
            do {
                try self.validateTransactionSetup()
                self.peer?.send(.sweepReady(captureID: next.captureID, durationSeconds: sweep.duration + self.service.engine.lead + 1, outputVolume: outputVolume))
            } catch { self.fail(error.localizedDescription) }
        }
    }
    private func channelKey(_ request: SweepRequest) -> String { request.signalMode == .system ? "system" : "\(request.connection.outputID):\(request.signalMode == .linkedCombined ? "combined" : String(request.connection.channel))" }
    private func sweepGuardInterval(for next: SweepRequest) -> Double {
        let coldStart = 2.3
        var maximumArrival: Double
        if next.signalMode == .system {
            guard let room = service.room else { return coldStart }
            let channels = room.speakers.filter { !$0.linkedSubwoofer && $0.connection.map { service.state.selected.contains($0.outputID) } == true }
            guard !channels.isEmpty else { return coldStart }
            maximumArrival = 0
            for speaker in channels {
                guard let connection = speaker.connection,
                      let observed = measurements["\(connection.outputID):\(connection.channel)"]?.lazy.map({ abs($0.arrivalSeconds) }).max() else { return coldStart }
                maximumArrival = max(maximumArrival, observed)
            }
            // System correlation can favor a louder/earlier speaker, so it never substitutes
            // for missing individual-channel evidence. Keep any larger combined/system arrival.
            if let observed = measurements.values.lazy.joined().map({ abs($0.arrivalSeconds) }).max() { maximumArrival = max(maximumArrival, observed) }
            if let observed = before.lazy.map({ abs($0.arrivalSeconds) }).max() { maximumArrival = max(maximumArrival, observed) }
            if let observed = after.lazy.map({ abs($0.arrivalSeconds) }).max() { maximumArrival = max(maximumArrival, observed) }
        } else {
            guard let observed = measurements[channelKey(next)]?.lazy.map({ abs($0.arrivalSeconds) }).max() else { return coldStart }
            maximumArrival = observed
        }
        if next.purpose == .systemAfter {
            guard let candidate else { return coldStart }
            // The reference markers also traverse correction. Adding the largest nonnegative
            // delay plus linear-phase FIR latency bounds either sign of relative arrival.
            let sampleRate = service.engine.sampleRate
            let correctionLatency = candidate.mixes.lazy.map {
                $0.delaySeconds + Double(max(0, $0.fir.count - 1)) / (2 * sampleRate)
            }.max()
            guard let correctionLatency, correctionLatency.isFinite else { return coldStart }
            maximumArrival += correctionLatency
        }
        return max(0.35, maximumArrival + 0.30)
    }
    private func referenceConnection() -> ChannelConnection? { service.room?.speakers.compactMap(\.connection).filter { service.state.selected.contains($0.outputID) }.sorted { ($0.outputID, $0.channel) < ($1.outputID, $1.channel) }.first }
    private func speakerIDs() -> Set<UUID> { Set(service.room?.speakers.filter { $0.connection.map { service.state.selected.contains($0.outputID) } ?? false }.map(\.id) ?? []) }
    private func matches(_ capture: SweepRequest, generation: UUID) -> Bool {
        !service.shuttingDown && transactionGeneration == generation && transactionID == capture.transactionID &&
        request?.transactionID == capture.transactionID && request?.captureID == capture.captureID
    }
    private func validateMeasurementSetup() throws {
        guard let room = service.room else { throw AudioFailure("A scanned room is required") }
        try Service.validateRoom(room)
        let selected = try service.availableSelectedOutputs()
        let connections = room.speakers.compactMap(\.connection)
        for connection in connections {
            guard let output = service.state.outputs.first(where: { $0.id == connection.outputID }),
                  connection.channel >= 0, connection.channel < min(2, output.channels) else { throw AudioFailure("A mapped speaker channel does not exist") }
        }
        for output in selected {
            guard (0..<min(2, output.channels)).allSatisfy({ channel in connections.contains(ChannelConnection(outputID: output.id, channel: channel)) }) else {
                throw AudioFailure("Map every playable channel of each selected output before measuring")
            }
        }
        let speakers = room.speakers.filter { !$0.linkedSubwoofer && $0.connection.map { service.state.selected.contains($0.outputID) } == true }
        for (_, group) in Dictionary(grouping: speakers.filter { !$0.timingGroupID.isEmpty }, by: \.timingGroupID) where group.count > 1 {
            guard group.count == 2, let left = group.first(where: { $0.connection?.channel == 0 })?.connection,
                  let right = group.first(where: { $0.connection?.channel == 1 })?.connection, left.outputID == right.outputID else {
                throw AudioFailure("A linked timing group must contain the two channels of one stereo output")
            }
        }
    }
    private func validateTransactionSetup() throws {
        guard isMeasuring, !service.shuttingDown, service.state.running, !service.state.muted,
              service.state.volume.isFinite, service.state.volume > 0, service.state.volume <= 1, let previousState,
              service.state.volume == previousState.volume, service.state.muted == previousState.muted,
              service.state.bypass == previousState.bypass, service.state.selected == previousState.selected,
              baselineDigest == (try service.digest()) else { throw AudioFailure("Setup or playback controls changed during calibration") }
        try validateMeasurementSetup()
    }
    private func validate(_ metadata: CaptureMetadata) throws {
        guard let request, metadata.transactionID == transactionID, metadata.transactionID == request.transactionID,
              metadata.captureID == request.captureID, metadata.pointIndex == request.pointIndex,
              !metadata.interrupted, metadata.motionMaxTranslationMeters.isFinite, metadata.motionMaxRotationRadians.isFinite,
              HandheldCapturePolicy.acceptsMotion(translation: metadata.motionMaxTranslationMeters, rotation: metadata.motionMaxRotationRadians),
              metadata.location.x.isFinite, metadata.location.y.isFinite, metadata.location.z.isFinite else {
            throw AudioFailure("Capture identity, movement, or interruption telemetry is missing or invalid")
        }
        let conditions = metadata.conditions
        try Service.validateConditions(conditions)
        guard let captureOutputVolume, metadata.sampleRate == conditions.sampleRate,
              conditions.outputVolume == captureOutputVolume,
              captureOutputVolume == Double(service.state.volume) else {
            throw AudioFailure("Capture conditions do not match the microphone rate and actual Mac master volume")
        }
        if let lastConditions {
            guard conditions.microphoneID == lastConditions.microphoneID,
                  conditions.microphoneOrientation == lastConditions.microphoneOrientation,
                  conditions.furnitureRevision == lastConditions.furnitureRevision,
                  conditions.sampleRate == lastConditions.sampleRate,
                  conditions.outputVolume == lastConditions.outputVolume else {
                throw AudioFailure("Microphone, orientation, furniture, sample rate, or output volume changed between captures")
            }
        }
    }
    private func analyze(metadata: CaptureMetadata, samples: [Float], request: SweepRequest, reference: CalibrationSweep) throws {
        try validateTransactionSetup(); try validate(metadata)
        let purpose: MeasurementPurpose = request.purpose == .systemAfter ? .verificationAfter : request.purpose == .systemBefore ? .verificationBefore : .calibration
        let recording = CalibrationRecording(id: metadata.captureID, channelID: channelKey(request), pointIndex: request.pointIndex, location: MeasurementLocation(x: metadata.location.x, y: metadata.location.y, z: metadata.location.z), samples: samples, sampleRate: metadata.sampleRate, origin: .liveMicrophone, purpose: purpose, capturedAt: metadata.conditions.capturedAt, configurationDigest: request.purpose == .systemAfter ? candidateDigest : baselineDigest, activeSpeakerIDs: speakerIDs(), completeSystem: request.signalMode == .system, maximumTranslationMeters: metadata.motionMaxTranslationMeters, maximumRotationRadians: metadata.motionMaxRotationRadians, interrupted: metadata.interrupted)
        analyzing = true
        let generation = transactionGeneration
        analysisQueue.async { [weak self] in
            let result = Result { try CalibrationAnalyzer.analyze(recording: recording, sweep: reference) }
            DispatchQueue.main.async {
                guard let self, self.matches(request, generation: generation) else { return }
                self.analyzing = false
                do {
                    try self.validateTransactionSetup()
                    let measurement: AcousticMeasurement
                    do { measurement = try result.get() }
                    catch let error as CalibrationError {
                        switch error {
                        case .rejected, .incomplete:
                            self.pause()
                            self.peer?.send(.captureRejected(transactionID: request.transactionID, captureID: request.captureID, reason: error.localizedDescription))
                            return
                        case .invalidInput: throw error
                        }
                    }
                    self.lastConditions = metadata.conditions
                    switch request.purpose {
                    case .calibration:
                        let key = self.channelKey(request); var values = self.measurements[key, default: []]
                        values.removeAll { $0.pointIndex == measurement.pointIndex }; values.append(measurement); self.measurements[key] = values
                    case .systemBefore: self.before.removeAll { $0.pointIndex == measurement.pointIndex }; self.before.append(measurement)
                    case .systemAfter: self.after.removeAll { $0.pointIndex == measurement.pointIndex }; self.after.append(measurement)
                    }
                    if metadata.retainRaw {
                        let directory = ControlSocket.directory.appendingPathComponent("Retained Recordings", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let data = samples.withUnsafeBytes { Data($0) }; try data.write(to: directory.appendingPathComponent(metadata.captureID.uuidString + ".f32le"), options: .atomic)
                    }
                    self.request = nil; self.reference = nil; self.captureOutputVolume = nil
                    if self.after.count == 9 { try self.verify() }
                    else { self.peer?.send(.progress(transactionID: request.transactionID, fraction: 1, message: "Measurement accepted. Move to the next guided point.")) }
                } catch { self.fail(error.localizedDescription) }
            }
        }
    }
    private func fit(positionID: UUID) throws {
        guard let room = service.room, let position = room.positions.first(where: { $0.id == positionID }) else { throw AudioFailure("Listening position no longer exists") }
        let speakers = room.speakers.filter { !$0.linkedSubwoofer && $0.connection.map { service.state.selected.contains($0.outputID) } == true }
        var corrections: [ChannelConnection: ChannelCorrection] = [:]
        let target = CorrectionTarget(bassDB: position.target.bassDB, trebleDB: position.target.trebleDB)
        for speaker in speakers {
            let connection = speaker.connection!, key = "\(connection.outputID):\(connection.channel)"
            corrections[connection] = try CalibrationAnalyzer.fit(measurements: measurements[key, default: []], target: target)
        }
        let latest = corrections.values.map(\.relativeArrivalSeconds).max() ?? 0
        var commonDelays: [ChannelConnection: Double] = [:]
        for (_, group) in Dictionary(grouping: speakers, by: { $0.timingGroupID.isEmpty ? $0.id.uuidString : $0.timingGroupID }) where group.count > 1 {
            guard group.count == 2, let l = group.first(where: { $0.connection?.channel == 0 })?.connection, let r = group.first(where: { $0.connection?.channel == 1 })?.connection, l.outputID == r.outputID else { throw AudioFailure("A linked timing group must map to the two channels of one stereo output") }
            let joint = try CalibrationAnalyzer.fitLinkedStereo(left: measurements["\(l.outputID):0", default: []], right: measurements["\(r.outputID):1", default: []], combined: measurements["\(l.outputID):combined", default: []], target: target, alignmentArrivalSeconds: latest)
            corrections[l] = joint.left; corrections[r] = joint.right; commonDelays[l] = joint.commonDelaySeconds; commonDelays[r] = joint.commonDelaySeconds
        }
        let groupLevels = Dictionary(grouping: speakers, by: { $0.timingGroupID.isEmpty ? $0.id.uuidString : $0.timingGroupID }).mapValues { group in
            let levels = group.flatMap { speaker in measurements["\(speaker.connection!.outputID):\(speaker.connection!.channel)", default: []].map(\.gainDB) }.sorted()
            return levels[levels.count / 2]
        }
        let quietestGroup = groupLevels.values.min() ?? 0
        let suggestions = room.suggestedMixes(for: position)
        var mixes: [ChannelMix] = []
        for speaker in speakers {
            let connection = speaker.connection!, correction = corrections[connection]!
            var mix = position.mixOverrides.first(where: { $0.connection == connection }) ?? suggestions.first(where: { $0.connection == connection })!
            let matrixHeadroom = max(1, abs(mix.left) + abs(mix.right))
            let groupID = speaker.timingGroupID.isEmpty ? speaker.id.uuidString : speaker.timingGroupID
            mix.gainDB = min(0, mix.gainDB) + correction.gainDB - 20 * log10(matrixHeadroom) - (groupLevels[groupID, default: quietestGroup] - quietestGroup)
            mix.delaySeconds = commonDelays[connection] ?? max(0, latest - correction.relativeArrivalSeconds)
            mix.fir = correction.fir; mixes.append(mix)
        }
        for (_, group) in Dictionary(grouping: speakers, by: { $0.timingGroupID.isEmpty ? $0.id.uuidString : $0.timingGroupID }) where group.count > 1 {
            let connections = Set(group.compactMap(\.connection))
            let commonGain = mixes.filter { connections.contains($0.connection) }.map(\.gainDB).min() ?? 0
            for i in mixes.indices where connections.contains(mixes[i].connection) { mixes[i].gainDB = commonGain }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        candidateDigest = SHA256.hash(data: Data(baselineDigest.utf8) + (try encoder.encode(mixes))).map { String(format: "%02x", $0) }.joined()
        candidateCreated = Date()
        candidate = CalibrationProfile(id: UUID(), name: position.name, positionID: positionID, outputIDs: service.state.selected, mixes: mixes, state: .unverified, configurationDigest: candidateDigest, conditions: lastConditions)
    }
    private func verify() throws {
        guard var candidate, let transactionID, let conditions = lastConditions, let position = service.room?.positions.first(where: { $0.id == candidate.positionID }) else { throw WireError.unexpectedMessage }
        try validateTransactionSetup()
        let result = try CalibrationAnalyzer.verify(request: SystemVerificationRequest(selectedSpeakerIDs: speakerIDs(), before: before, after: after, baselineConfigurationDigest: baselineDigest, candidateConfigurationDigest: candidateDigest, candidateCreatedAt: candidateCreated, target: CorrectionTarget(bassDB: position.target.bassDB, trebleDB: position.target.trebleDB)))
        guard result.passed else { throw AudioFailure("Fresh system verification failed: " + result.reasons.joined(separator: "; ")) }
        candidate.state = .verified
        candidate.provenance = VerificationProvenance(captureIDs: result.evidenceRecordingIDs, verifiedAt: Date(), configurationDigest: candidateDigest, conditions: conditions, beforeErrorDB: result.beforeErrorDB, afterErrorDB: result.afterErrorDB)
        candidate.measuredBefore = curve(before); candidate.measuredAfter = curve(after)
        guard candidate.hasMeasuredVerification else { throw AudioFailure("Fresh measurements did not demonstrate the required target improvement; previous profile retained") }
        service.state.profiles.removeAll { $0.positionID == candidate.positionID }; service.state.profiles.append(candidate)
        service.state.activeProfile = candidate.id; service.state.bypass = false
        service.state.calibrationStatus = "Fresh complete-system verification passed"
        do { try service.persist() }
        catch {
            if let previousState { service.state = previousState }
            throw error
        }
        completedResult = (transactionID, candidate)
        peer?.send(.result(transactionID: transactionID, profile: candidate)); clear()
    }
    private func curve(_ measurements: [AcousticMeasurement]) -> ResponseCurve? {
        guard let first = measurements.first else { return nil }
        return ResponseCurve(frequencies: first.frequencies, decibels: first.magnitudeDB.indices.map { index in measurements.map { $0.magnitudeDB[index] }.reduce(0, +) / Double(measurements.count) })
    }
    private func pause() {
        guard isMeasuring, !paused else { return }
        paused = true; needsQuietLead = true; transactionGeneration = UUID()
        service.invalidateMeasurementCallbacks()
        service.engine.pauseMeasurementPlayback()
        request = nil; reference = nil; captureOutputVolume = nil
        receiver.reset(); armed = false; playbackFinished = false; analyzing = false
        service.state.calibrationStatus = "Calibration paused — return to the phone to continue"
        let id = transactionID
        pauseExpiry?.cancel()
        pauseExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self, self.paused, self.transactionID == id else { return }
            self.fail("Calibration paused for too long. Start a new measurement session.")
        }
    }
    func fail(_ reason: String, restorePlayback: Bool = true) {
        guard isMeasuring else { return }
        peer?.send(.failure(transactionID: transactionID, reason: reason))
        let previous = previousState
        let running = service.state.running, outputs = service.state.outputs, driverAvailable = service.state.driverAvailable, outputStatus = service.state.outputStatus
        let authentication = service.state.authenticationRequired
        clear()
        if let previous {
            service.state = previous
            service.state.outputs = outputs; service.state.driverAvailable = driverAvailable; service.state.outputStatus = outputStatus
            service.state.authenticationRequired = authentication
            service.state.running = running && previous.running
            if restorePlayback, service.state.running, !service.shuttingDown {
                do { try service.configureEngine() }
                catch { service.state.error = "Cannot restore previous playback: \(error.localizedDescription)"; service.engine.stop(); service.state.running = false }
            }
        }
        service.state.error = service.state.error ?? reason
        service.state.calibrationStatus = reason
    }
    private func clear() {
        pauseExpiry?.cancel(); pauseExpiry = nil; paused = false; needsQuietLead = false
        service.invalidateMeasurementCallbacks()
        if let transactionID { completedTransactionIDs.insert(transactionID) }
        transactionGeneration = UUID(); transactionID = nil; positionID = nil
        request = nil; reference = nil; candidate = nil; previousState = nil; lastConditions = nil; captureOutputVolume = nil
        receiver.reset(); measurements.removeAll(); before.removeAll(); after.removeAll()
        armed = false; playbackFinished = false; analyzing = false
        service.engine.endMeasurementSession()
    }
    func stop() {
        fail("Service stopped; previous calibration retained", restorePlayback: false)
        sessionGeneration = UUID(); peer?.cancel(); peer = nil; listener?.stop(); clear()
    }
}
