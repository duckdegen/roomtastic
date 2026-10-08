// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import CoreAudio
import Darwin
import CryptoKit
import RoomtasticShared
import RoomtasticControl

private final class MeasurementCallbackGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID()
    func snapshot() -> UUID { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); defer { lock.unlock() }; value = UUID() }
}

@MainActor final class Service {
    var state = ControlState()
    let discovery = ReceiverDiscovery(), engine = PlaybackEngine()
    var devices: [String: AudioDeviceID] = [:]
    var room: RoomModel?
    var phone: PhoneCoordinator?
    private var previousOutputUID: String?
    private var pendingControlState: ControlState?
    private var lockFD: Int32 = -1
    private var socketFD: Int32 = -1
    private var socketSource: DispatchSourceRead?
    private var refreshTimer: Timer?
    private let clients = DispatchSemaphore(value: 8)
    private var observers: [NSObjectProtocol] = []
    private var resumeAfterWake = false
    private(set) var shuttingDown = false
    private let measurementCallbacks = MeasurementCallbackGeneration()
    let dataURL = ControlSocket.directory.appendingPathComponent("state.json")
    struct Persisted: Codable { var state: ControlState; var room: RoomModel?; var previousOutputUID: String? }
    init() {
        if FileManager.default.fileExists(atPath: dataURL.path) {
            do {
                let size = try dataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 32 * 1_048_576 else { throw AudioFailure("Saved state exceeds the storage limit") }
                let saved = try JSONDecoder().decode(Persisted.self, from: Data(contentsOf: dataURL))
                try Self.validate(saved)
                state = saved.state; room = saved.room; previousOutputUID = saved.previousOutputUID
                state.error = nil
                for i in state.profiles.indices where state.profiles[i].state == .verified && !state.profiles[i].hasMeasuredVerification { state.profiles[i].state = .needsVerification }
            } catch { state.error = "Cannot load saved Roomtastic state: \(error.localizedDescription)" }
        }
        state.running = false; state.pairingURI = nil; state.outputStatus = [:]; state.authenticationRequired = nil
        engine.onStatus = { [weak self] id, message in DispatchQueue.main.async { guard let self, !self.shuttingDown else { return }; self.state.outputStatus[id] = message } }
        engine.onAuthenticationRequired = { [weak self] id, reason in DispatchQueue.main.async {
            guard let self, !self.shuttingDown else { return }
            if self.state.authenticationRequired == nil { self.state.authenticationRequired = [:] }
            self.state.authenticationRequired?[id] = reason
        } }
        engine.onOutputReady = { [weak self] id in DispatchQueue.main.async {
            guard let self, !self.shuttingDown else { return }
            self.state.authenticationRequired?.removeValue(forKey: id)
        } }
        engine.onMeasurementFailure = { [weak self, measurementCallbacks] reason in
            let generation = measurementCallbacks.snapshot()
            DispatchQueue.main.async {
                guard let self, !self.shuttingDown, measurementCallbacks.snapshot() == generation else { return }
                self.phone?.fail(reason)
            }
        }
        engine.onConfiguration = { [weak self] success, message in DispatchQueue.main.async {
            guard let self, !self.shuttingDown, let previous = self.pendingControlState else { return }
            self.pendingControlState = nil
            if !success {
                let outputStatus = self.state.outputStatus
                let authentication = self.state.authenticationRequired
                self.state = previous
                self.state.outputStatus = outputStatus
                self.state.authenticationRequired = authentication
                if !previous.running { try? self.stopPlayback() }
                self.state.error = message
            } else {
                self.updateVerificationStatus()
            }
            try? self.persist()
        } }
        discovery.changed = { [weak self] in self?.refresh() }
    }
    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        try FileManager.default.createDirectory(at: ControlSocket.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(ControlSocket.directory.path, 0o700)
        lockFD = open(ControlSocket.directory.appendingPathComponent("service.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw AudioFailure("Roomtastic service is already running") }
        unlink(ControlSocket.path)
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0); guard socketFD >= 0 else { throw ControlError.system(errno) }
        var address = try ControlSocket.address()
        let result = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, chmod(ControlSocket.path, 0o600) == 0, listen(socketFD, 8) == 0 else { throw ControlError.system(errno) }
        socketSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .global(qos: .userInitiated))
        let listenerFD = socketFD
        socketSource?.setEventHandler { [weak self] in self?.acceptClient(listenerFD) }; socketSource?.resume()
        discovery.start(); refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in DispatchQueue.main.async {
            guard let self, !self.shuttingDown else { return }
            self.resumeAfterWake = self.state.running
            self.phone?.fail("Mac went to sleep; previous calibration retained", restorePlayback: false)
            self.pendingControlState = nil; self.engine.stop(); self.state.running = false
        } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in DispatchQueue.main.async {
            guard let self, !self.shuttingDown, self.resumeAfterWake else { return }
            self.resumeAfterWake = false; self.refresh()
            do { try self.activate() } catch { self.state.error = error.localizedDescription }
        } })
        phone = PhoneCoordinator(service: self)
        if let driver = try? Hardware.driver(), let current = try? Hardware.defaultOutput(), current == driver {
            do { try activate() }
            catch {
                state.error = error.localizedDescription
                do { try restorePreviousOutput() } catch { state.error = "Cannot resume playback or restore previous output: \(error.localizedDescription)" }
            }
        }
    }
    nonisolated private func acceptClient(_ listenerFD: Int32) {
        let fd = accept(listenerFD, nil, nil); guard fd >= 0 else { return }
        guard clients.wait(timeout: .now()) == .success else { close(fd); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { close(fd); return }; defer { close(fd); self.clients.signal() }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            do {
                let data = try ControlSocket.readLine(fd), request = try JSONDecoder().decode(ControlRequest.self, from: data)
                let response = DispatchQueue.main.sync { self.handle(request) }
                var encoded = try JSONEncoder().encode(response); encoded.append(10); try ControlSocket.sendAll(fd, data: encoded)
            } catch { /* Malformed or unauthenticated local clients cannot mutate state. */ }
        }
    }
    func refresh() {
        guard !shuttingDown else { return }
        do {
            let found = try Hardware.outputDevices(); devices = Dictionary(uniqueKeysWithValues: found.map { ($0.0.id, $0.1) })
            let live = found.map(\.0) + discovery.receivers.values.map(\.output)
            let liveIDs = Set(live.map(\.id))
            var missing = state.outputs.filter { !liveIDs.contains($0.id) && state.selected.contains($0.id) }
            for i in missing.indices { missing[i].available = false }
            state.outputs = (live + missing).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            state.driverAvailable = try Hardware.driver() != nil
            engine.updateAvailability(devices: devices, receivers: discovery.receivers)
            if state.running && !state.driverAvailable {
                phone?.fail("Virtual input was removed during playback", restorePlayback: false); pendingControlState = nil; engine.stop(); state.running = false
            }
            let selectedMissing = !Set(state.selected).isSubset(of: liveIDs)
            if selectedMissing { phone?.fail("Selected output is missing; previous calibration retained") }
            if phone?.isMeasuring != true, pendingControlState == nil {
                invalidateChangedProfiles()
                if selectedMissing { state.calibrationStatus = "Needs verification — selected output missing" }
                else { updateVerificationStatus() }
            }
            if state.running, let driver = try Hardware.driver(), let rate = try? Hardware.value(driver, kAudioDevicePropertyNominalSampleRate, Double(48000)), rate != engine.sampleRate {
                phone?.fail("Sample rate changed during calibration", restorePlayback: false)
                pendingControlState = nil; engine.stop(); state.running = false
                for i in state.profiles.indices { state.profiles[i].state = .needsVerification }
                state.calibrationStatus = "Needs verification — sample rate changed"; try activate()
            }
        } catch {
            phone?.fail("Cannot confirm the current output setup: \(error.localizedDescription)")
            state.error = error.localizedDescription
        }
    }
    func handle(_ request: ControlRequest) -> ControlState {
        let previous = state
        var playbackChanged = false
        var preparedConfiguration = false
        do {
            guard !shuttingDown else { throw AudioFailure("Roomtastic is shutting down") }
            if [.configure, .preset, .activate, .saveCredentials, .forgetCredentials].contains(request.action) {
                guard phone?.isMeasuring != true else { throw AudioFailure("Finish or cancel measurements before changing playback settings") }
                guard !engine.configurationPending else { throw AudioFailure("Wait for the coordinated output change to complete") }
            }
            if request.action == .activate || (state.running && (request.action == .preset || (request.action == .configure && request.selected.map { $0 != state.selected } == true))) {
                // Install rollback state before the worker can finish or reject staging.
                pendingControlState = previous; preparedConfiguration = true
            }
            switch request.action {
            case .status: break
            case .activate: try activate(); playbackChanged = true
            case .stop: try stopPlayback()
            case .shutdown:
                shuttingDown = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.shutdown(); exit(0) }
                try stopPlayback()
            case .pair: state.pairingURI = try phone?.beginPairing()
            case .saveCredentials, .forgetCredentials:
                guard let outputID = request.outputID, state.outputs.contains(where: { $0.id == outputID && $0.kind == .airplay }) else { throw AudioFailure("Choose an existing AirPlay output") }
                if request.action == .saveCredentials {
                    guard state.authenticationRequired?[outputID] != nil else { throw AudioFailure("This receiver has not requested authentication; it will connect without credentials") }
                    guard let credentials = request.receiverCredentials else { throw AudioFailure("Receiver credentials are required") }
                    try SpeakerCredentialStore.save(outputID: outputID, credentials: credentials)
                    engine.retryAuthentication(outputID: outputID, useStoredCredentials: true)
                } else {
                    try SpeakerCredentialStore.remove(outputID: outputID)
                    state.authenticationRequired?.removeValue(forKey: outputID)
                    engine.retryAuthentication(outputID: outputID, useStoredCredentials: false)
                }
            case .preset:
                guard let id = request.profileID, let profile = state.profiles.first(where: { $0.id == id }) else { throw AudioFailure("Preset does not exist") }
                let missing = profile.outputIDs.filter { id in !state.outputs.contains { $0.id == id && $0.available } }
                guard missing.isEmpty else { state.calibrationStatus = "Needs verification — missing: \(missing.joined(separator: ", "))"; throw AudioFailure("Preset speaker set is incomplete; current playback retained") }
                let previous = state; state.selected = profile.outputIDs; state.activeProfile = id
                do { invalidateChangedProfiles(); if state.running { try configureEngine(); playbackChanged = true }; updateVerificationStatus() } catch { state = previous; throw error }
            case .configure:
                if let volume = request.volume { guard volume.isFinite, (0...1).contains(volume) else { throw AudioFailure("Volume must be between zero and one") }; state.volume = volume }
                if let muted = request.muted { state.muted = muted }
                if let bypass = request.bypass { state.bypass = bypass }
                if let selected = request.selected {
                    guard Set(selected).count == selected.count, selected.allSatisfy({ id in state.outputs.contains { $0.id == id } }) else { throw AudioFailure("Unknown or duplicated speaker selection") }
                    if state.selected != selected { state.selected = selected; state.activeProfile = nil; state.calibrationStatus = "Needs verification — speaker selection changed"; if state.running { try configureEngine() } }
                }
                invalidateChangedProfiles()
                engine.setControls(volume: state.volume, muted: state.muted, bypass: state.bypass)
                playbackChanged = true
                updateVerificationStatus()
            }
            if request.action != .status, engine.configurationPending {
                if pendingControlState == nil { pendingControlState = previous }
                state.calibrationStatus = "Preparing outputs — previous configuration remains active"
            }
            if request.action != .status { state.error = nil; try persist() }
            if request.action == .configure { phone?.publishPlaybackState() }
        } catch {
            if preparedConfiguration { pendingControlState = nil }
            let running = state.running
            if request.action != .stop && request.action != .shutdown {
                state = previous
                if request.action == .activate { state.running = running }
                if playbackChanged {
                    let configurationWasPending = engine.configurationPending
                    pendingControlState = nil
                    if configurationWasPending {
                        engine.stop(); state.running = false; try? restorePreviousOutput()
                    } else if previous.running {
                        do { try configureEngine() }
                        catch { engine.stop(); state.running = false }
                    } else { try? stopPlayback() }
                    engine.setControls(volume: state.volume, muted: state.muted, bypass: state.bypass)
                }
            }
            state.error = error.localizedDescription
        }
        return state
    }
    func configureEngine(mixes override: [ChannelMix]? = nil) throws {
        guard !shuttingDown else { throw AudioFailure("Roomtastic is shutting down") }
        let outputs = try availableSelectedOutputs()
        let mixes = override ?? state.profiles.first(where: { $0.id == state.activeProfile })?.mixes ?? []
        try engine.configure(outputs: outputs, devices: devices, receivers: discovery.receivers, mixes: mixes, volume: state.volume, muted: state.muted, bypass: state.bypass)
    }
    func activate() throws {
        guard !shuttingDown, phone?.isMeasuring != true else { throw AudioFailure("Playback cannot restart during calibration or shutdown") }
        guard let driver = try Hardware.driver() else { throw AudioFailure("Install the Roomtastic audio driver before activating playback") }
        guard !state.selected.isEmpty else { throw AudioFailure("Select at least one speaker before activating Roomtastic") }
        let current = try Hardware.defaultOutput()
        if current != driver { previousOutputUID = try Hardware.string(current, kAudioDevicePropertyDeviceUID); try persist() }
        try engine.start(driver: driver)
        do { invalidateChangedProfiles(); try configureEngine(); try Hardware.setDefault(driver); state.running = true; updateVerificationStatus() }
        catch { engine.stop(); state.running = false; throw error }
    }
    func stopPlayback() throws {
        resumeAfterWake = false
        phone?.fail("Playback stopped; previous calibration retained", restorePlayback: false)
        if let previous = pendingControlState { state = previous }
        pendingControlState = nil
        engine.stop(); state.running = false
        try restorePreviousOutput()
    }
    func persist() throws {
        var saved = pendingControlState ?? state
        saved.pairingURI = nil
        saved.authenticationRequired = nil
        let snapshot = Persisted(state: saved, room: room, previousOutputUID: previousOutputUID)
        try Self.validate(snapshot)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 32 * 1_048_576 else { throw AudioFailure("Saved state exceeds the storage limit") }
        try data.write(to: dataURL, options: .atomic); chmod(dataURL.path, 0o600)
    }
    func digest(outputIDs: [String]? = nil) throws -> String {
        struct Output: Encodable { let id: String; let kind: OutputKind; let channels: Int; let sampleRate: Double }
        struct Configuration: Encodable { let room: RoomModel?; let outputs: [Output]; let rate: Double; let measurementVolume: Float }
        let rate = try Hardware.driver().map { try Hardware.value($0, kAudioDevicePropertyNominalSampleRate, Double(48000)) } ?? engine.sampleRate
        let outputs = try availableSelectedOutputs(outputIDs: outputIDs).map { Output(id: $0.id, kind: $0.kind, channels: $0.channels, sampleRate: $0.sampleRate) }.sorted { $0.id < $1.id }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(Configuration(room: room, outputs: outputs, rate: rate, measurementVolume: state.volume))).map { String(format: "%02x", $0) }.joined()
    }
    func invalidateMeasurementCallbacks() { measurementCallbacks.advance() }
    func availableSelectedOutputs(outputIDs: [String]? = nil) throws -> [AudioOutput] {
        let selected = outputIDs ?? state.selected
        guard !selected.isEmpty, selected.count <= 64, Set(selected).count == selected.count else { throw AudioFailure("Select a unique, nonempty set of speakers") }
        return try selected.map { id in
            let matches = state.outputs.filter { $0.id == id }
            guard matches.count == 1, let output = matches.first, output.available,
                  output.channels > 0, output.sampleRate.isFinite, (8000...192000).contains(output.sampleRate),
                  (output.kind == .wired ? devices[id] != nil : discovery.receivers[id] != nil) else {
                throw AudioFailure("Every selected output must be present and available: \(id)")
            }
            return output
        }
    }
    private func restorePreviousOutput() throws {
        guard let driver = try Hardware.driver(), try Hardware.defaultOutput() == driver else { return }
        guard let previousOutputUID, let previous = try Hardware.devices().first(where: { try Hardware.string($0, kAudioDevicePropertyDeviceUID) == previousOutputUID }) else {
            throw AudioFailure("The previous default output is unavailable; select a system output in Sound settings")
        }
        try Hardware.setDefault(previous)
    }
    private func matchesCurrentSetup(_ profile: CalibrationProfile) -> Bool {
        guard profile.hasMeasuredVerification, let conditions = profile.conditions,
              abs(conditions.outputVolume - Double(state.volume)) <= 0.000_001,
              let baseline = try? digest(outputIDs: profile.outputIDs) else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let mixes = try? encoder.encode(profile.mixes) else { return false }
        let digest = SHA256.hash(data: Data(baseline.utf8) + mixes).map { String(format: "%02x", $0) }.joined()
        return digest == profile.configurationDigest
    }
    private func invalidateChangedProfiles() {
        for i in state.profiles.indices where state.profiles[i].state == .verified && !matchesCurrentSetup(state.profiles[i]) {
            state.profiles[i].state = .needsVerification
        }
    }
    private func updateVerificationStatus() {
        if state.bypass { state.calibrationStatus = "Correction bypassed — needs verification"; return }
        let profile = state.profiles.first { $0.id == state.activeProfile }
        state.calibrationStatus = profile.map { Set($0.outputIDs) == Set(state.selected) && matchesCurrentSetup($0) } == true ? "Measured verification passed" : "Needs verification"
    }
    static func validateRoom(_ room: RoomModel) throws {
        func finite(_ point: Point3) -> Bool { point.x.isFinite && point.y.isFinite && point.z.isFinite }
        let connections = room.speakers.compactMap(\.connection)
        guard room.name.utf8.count <= 1024, room.speakers.count <= 64, room.positions.count <= 64,
              Set(room.speakers.map(\.id)).count == room.speakers.count, Set(room.positions.map(\.id)).count == room.positions.count,
              Set(connections).count == connections.count,
              room.speakers.allSatisfy({ finite($0.position) && $0.facingRadians.isFinite && $0.name.utf8.count <= 1024 && $0.timingGroupID.utf8.count <= 1024 && (!$0.linkedSubwoofer || $0.connection == nil) }),
              connections.allSatisfy({ !$0.outputID.isEmpty && $0.outputID.utf8.count <= 1024 && (0...1).contains($0.channel) }),
              room.positions.allSatisfy({ finite($0.position) && $0.facingRadians.isFinite && $0.target.bassDB.isFinite && $0.target.trebleDB.isFinite && $0.name.utf8.count <= 1024 }) else {
            throw AudioFailure("Room contains invalid, duplicated, or excessive speaker/position data")
        }
        for position in room.positions {
            try validateMixes(position.mixOverrides)
            guard position.mixOverrides.allSatisfy({ connections.contains($0.connection) }) else { throw AudioFailure("Room mix refers to an unmapped speaker") }
        }
        if let geometry = room.geometry {
            guard geometry.surfaces.count <= 4096, geometry.roomPlanArchive.count <= 524_288,
                  geometry.capturedAt.timeIntervalSinceReferenceDate.isFinite,
                  Set(geometry.surfaces.map(\.id)).count == geometry.surfaces.count,
                  geometry.surfaces.allSatisfy({ finite($0.dimensions) && $0.dimensions.x >= 0 && $0.dimensions.y >= 0 && $0.dimensions.z >= 0 && $0.category.utf8.count <= 1024 && $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite) }) else {
                throw AudioFailure("Scanned room geometry is invalid or exceeds storage limits")
            }
        }
        guard try JSONEncoder().encode(room).count <= RoomtasticProtocol.maxFrameBytes else { throw AudioFailure("Room model exceeds the transfer/storage limit") }
    }
    static func validateConditions(_ conditions: MeasurementConditions) throws {
        guard !conditions.microphoneID.isEmpty, conditions.microphoneID.utf8.count <= 1024,
              !conditions.microphoneOrientation.isEmpty, conditions.microphoneOrientation.utf8.count <= 1024,
              !conditions.furnitureRevision.isEmpty, conditions.furnitureRevision.utf8.count <= 1024,
              conditions.sampleRate.isFinite, (8000...192000).contains(conditions.sampleRate),
              conditions.outputVolume.isFinite, (0...1).contains(conditions.outputVolume),
              conditions.ambientNoiseDBFS.isFinite, conditions.capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AudioFailure("Measurement conditions are missing or invalid")
        }
    }
    private static func validateMixes(_ mixes: [ChannelMix]) throws {
        guard mixes.count <= 64, Set(mixes.map(\.connection)).count == mixes.count,
              mixes.allSatisfy({ !$0.connection.outputID.isEmpty && $0.connection.outputID.utf8.count <= 1024 && (0...1).contains($0.connection.channel) && $0.left.isFinite && $0.right.isFinite && $0.gainDB.isFinite && $0.delaySeconds.isFinite && (0...2).contains($0.delaySeconds) && $0.fir.count <= 4097 && $0.fir.allSatisfy(\.isFinite) }) else {
            throw AudioFailure("Saved channel correction is invalid or exceeds storage limits")
        }
    }
    private static func validate(_ saved: Persisted) throws {
        let state = saved.state
        guard state.volume.isFinite, (0...1).contains(state.volume), state.outputs.count <= 256,
              state.selected.count <= 64, Set(state.selected).count == state.selected.count,
              state.selected.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
              Set(state.outputs.map(\.id)).count == state.outputs.count,
              state.outputs.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 1024 && $0.name.utf8.count <= 1024 && (1...256).contains($0.channels) && $0.sampleRate.isFinite && (8000...192000).contains($0.sampleRate) }),
              state.profiles.count <= 64, Set(state.profiles.map(\.id)).count == state.profiles.count,
              saved.previousOutputUID.map({ !$0.isEmpty && $0.utf8.count <= 1024 && $0 != "Roomtastic_UID" }) ?? true else {
            throw AudioFailure("Saved playback state is invalid or exceeds storage limits")
        }
        if let room = saved.room { try validateRoom(room) }
        for profile in state.profiles {
            guard profile.name.utf8.count <= 1024, profile.configurationDigest.utf8.count <= 1024,
                  !profile.outputIDs.isEmpty, profile.outputIDs.count <= 64, Set(profile.outputIDs).count == profile.outputIDs.count,
                  profile.outputIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
                  profile.mixes.allSatisfy({ profile.outputIDs.contains($0.connection.outputID) }) else { throw AudioFailure("Saved calibration profile is invalid") }
            try validateMixes(profile.mixes)
            if let conditions = profile.conditions { try validateConditions(conditions) }
            if let provenance = profile.provenance {
                try validateConditions(provenance.conditions)
                guard provenance.captureIDs.count <= 1024, provenance.configurationDigest.utf8.count <= 1024,
                      provenance.verifiedAt.timeIntervalSinceReferenceDate.isFinite,
                      provenance.beforeErrorDB.isFinite, provenance.afterErrorDB.isFinite else { throw AudioFailure("Saved verification evidence is invalid") }
            }
            for curve in [profile.measuredBefore, profile.measuredAfter, profile.predicted].compactMap({ $0 }) {
                guard curve.frequencies.count <= 16_384, curve.frequencies.count == curve.decibels.count,
                      curve.frequencies.allSatisfy({ $0.isFinite && $0 > 0 }), curve.decibels.allSatisfy(\.isFinite) else { throw AudioFailure("Saved response curve is invalid or too large") }
            }
        }
    }
    func shutdown() {
        shuttingDown = true
        try? stopPlayback(); try? persist(); refreshTimer?.invalidate(); discovery.stop(); phone?.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
        socketSource?.cancel(); socketSource = nil
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
        if socketFD >= 0 { close(socketFD); socketFD = -1; unlink(ControlSocket.path) }
    }
}
