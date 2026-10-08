// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import RoomtasticDSP

final class AirPlaySession {
    let receiver: Receiver
    let queue: DispatchQueue
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var commandFD: Int32 = -1
    private var fifo: URL
    private var fragments: [Int32: Data] = [:]
    private var closedStreams: Set<Int32> = []
    private var exitStatus: Int32?
    private var inputFD: Int32 { input.fileHandleForWriting.fileDescriptor }
    private var connected = false, buffered = false, clockReady = false, started = false, startCommandSent = false
    private var pcm = [Int16](repeating: 0, count: 4096)
    private var requestedStart: Int64?
    private(set) var failed = false
    var onFailure: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onAuthenticationRequired: ((String) -> Void)?
    var onReady: (() -> Void)?
    let sampleRate: Double
    var scheduled: Bool { started && !failed }
    static var executableURL: URL {
        if let path = ProcessInfo.processInfo.environment["ROOMTASTIC_SENDER_PATH"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/cliairplay")
    }
    init(receiver: Receiver, queue: DispatchQueue, useStoredCredentials: Bool = false) throws {
        self.receiver = receiver; self.queue = queue; self.sampleRate = 44100
        let words = (receiver.txt["features"] ?? receiver.txt["ft"] ?? "").split(separator: ",").map { UInt64($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "", options: .caseInsensitive), radix: 16) ?? 0 }
        let features = (words.first ?? 0) | ((words.count > 1 ? words[1] : 0) << 32)
        if features & (1 << 41) != 0 {
            let sharedClock = rt_open_shared_clock()
            guard sharedClock >= 0 else { throw AudioFailure("Shared AirPlay clock required. Enable Roomtastic's installed PTP service before selecting this receiver.") }
            close(sharedClock)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("roomtastic-\(getuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fifo = directory.appendingPathComponent(UUID().uuidString + ".fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw AudioFailure("Cannot create private sender command pipe") }
        commandFD = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard commandFD >= 0 else { unlink(fifo.path); throw AudioFailure("Cannot open sender command pipe") }
        process.executableURL = Self.executableURL
        let txt = receiver.txt.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        var arguments = ["--protocol", "auto", "--port", String(receiver.port), "--samplerate", "44100", "--bitdepth", "16", "--channels", "2", "--volume", "100", "--ptp-shared", "--txt", txt, "--cmdpipe", fifo.path, "--dacp", SpeakerCredentialStore.identity(outputID: receiver.output.id)]
        // These RAOP properties are separate options, not extracted from --txt.
        // Do not pass --pw: its advertisement-only preflight is not an auth challenge.
        for key in ["am", "et", "md", "cn", "pk"] {
            if let value = receiver.txt[key], !value.contains("\0") { arguments += ["--\(key)", value] }
        }
        do {
            if useStoredCredentials, let credentials = try SpeakerCredentialStore.load(outputID: receiver.output.id) {
                if let password = credentials.password { arguments += ["--password", password] }
                if let auth = credentials.auth { arguments += ["--auth", auth] }
                if let secret = credentials.legacySecret { arguments += ["--secret", secret] }
            }
        } catch {
            stop(); throw AudioFailure("Cannot load authorized receiver credentials (\((error as NSError).code))")
        }
        process.arguments = arguments + [receiver.host]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { [weak self] process in
            self?.queue.async { [weak self] in self?.exitStatus = process.terminationStatus; self?.finishExit() }
        }
        for pipe in [output, errors] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData, stream = handle.fileDescriptor
                if data.isEmpty { handle.readabilityHandler = nil }
                self?.queue.async { [weak self] in
                    guard let self, !self.failed else { return }
                    if data.isEmpty {
                        // Final status bytes must win over the generic process-exit fallback.
                        if self.fragments[stream]?.isEmpty == false { self.parse(Data([10]), stream: stream) }
                        self.closedStreams.insert(stream); self.finishExit()
                    } else { self.parse(data, stream: stream) }
                }
            }
        }
        do { try process.run() } catch { stop(); throw AudioFailure("Cannot launch AirPlay sender (\((error as NSError).code))") }
        _ = fcntl(inputFD, F_SETFL, O_NONBLOCK)
        var one: Int32 = 1; setsockopt(inputFD, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
    }
    func send(_ samples: UnsafePointer<Float>, frames: Int, audibleUnix: Double) {
        guard connected, !failed, frames > 0 else { return }
        guard frames <= 2048 else { fail("Oversized sender audio block"); return }
        if requestedStart == nil { requestedStart = Int64((audibleUnix * 1000).rounded()) }
        let count = frames * 4
        let n = pcm.withUnsafeMutableBufferPointer { pcm in
            for i in 0..<(frames * 2) { let value = samples[i]; pcm[i] = Int16((max(-1, min(1, value.isFinite ? value : 0)) * 32767).rounded()).littleEndian }
            return Darwin.write(inputFD, pcm.baseAddress!, count)
        }
        guard n == count else { fail("Receiver backpressure: discarded session to prevent stale playback"); return }
        startIfReady()
    }
    private func parse(_ data: Data, stream: Int32) {
        guard !failed else { return }
        var text = fragments[stream, default: Data()]; text.append(data)
        guard text.count < 65536 else { fail("Oversized sender status"); return }
        while let newline = text.firstIndex(of: 10) {
            let line = String(decoding: text[..<newline], as: UTF8.self); text.removeSubrange(...newline)
            let fields = line.split(separator: " ")
            guard fields.first == "[STATUS]" else {
                if line == "[ERROR] RAOP control or media channel failed" { fail("Receiver RAOP control or media channel failed"); return }
                if line == "[ERROR] AirPlay 2 control channel failed" { fail("Receiver AirPlay 2 control channel failed"); return }
                continue
            }
            func field(_ key: String) -> Substring? {
                fields.dropFirst(2).first(where: { $0.hasPrefix(key + "=") })?.dropFirst(key.count + 1)
            }
            switch fields.dropFirst().first {
            case "connected":
                connected = true; onStatus?("Receiver connected; preparing playback clock")
            case "audio":
                buffered = true
            case "clock_ready":
                // NTP/RAOP intentionally report state=cold: only PTP has a probe streak.
                if field("mode") == "ntp" || field("state") == "ready" { clockReady = true }
                if field("state") == "stalled" { fail("Receiver clock stalled"); return }
            case "error":
                guard let code = field("code") else { fail("Receiver reported a transport error without a status code"); return }
                let reason: String
                switch code {
                case "auth_required": reason = "Receiver explicitly requires authentication"
                case "auth_failed": reason = "Receiver rejected the supplied credentials"
                case "connect_failed": reason = "Receiver connection failed"
                case "start_failed": reason = "Receiver could not schedule playback"
                case "flush_failed": reason = "Receiver could not flush playback"
                case "standby_failed": reason = "Receiver could not enter standby"
                case "play_failed": reason = "Receiver could not resume playback"
                case "pause_failed": reason = "Receiver could not pause playback"
                case "stop_failed": reason = "Receiver could not stop playback"
                case "announce_failed": reason = "Receiver announcement failed"
                default: fail("Receiver reported an unrecognized transport error"); return
                }
                // Never publish arbitrary sender text, which may echo credentials.
                let http = field("http").flatMap { Int($0) }
                let status = http.map { (100...599).contains($0) ? ", RTSP/HTTP \($0)" : "" } ?? ""
                let diagnostic = "\(reason) (\(code)\(status))"
                if code == "auth_required" || code == "auth_failed" { onAuthenticationRequired?(diagnostic) }
                fail(diagnostic); return
            case "started":
                guard startCommandSent, let item = field("at_unix_ms"), let actual = Int64(item), let requestedStart, actual >= requestedStart - 1, actual <= requestedStart + 1 else { fail("Receiver moved its playback anchor; rejoin required"); return }
                if !started { started = true; onStatus?("Playback acknowledged at \(actual) ms"); onReady?() }
            case "anchor_corrected":
                fail("Receiver moved its active playback anchor; rejoin required"); return
            default:
                break
            }
        }
        fragments[stream] = text; startIfReady()
    }
    private func startIfReady() {
        guard !failed, !startCommandSent, connected, buffered, clockReady, let requestedStart else { return }
        guard Double(requestedStart) / 1000 > Date().timeIntervalSince1970 + 0.3 else { fail("Receiver was not clock-ready before its playback deadline"); return }
        command("START_UNIX_MS=\(requestedStart)\nACTION=START\n"); startCommandSent = !failed
        if startCommandSent { onStatus?("Awaiting playback acknowledgement at \(requestedStart) ms") }
    }
    func checkDeadline() {
        if !failed, !started, let requestedStart, Date().timeIntervalSince1970 > Double(requestedStart) / 1000 - 0.3 { fail("Receiver start deadline expired") }
    }
    private func command(_ text: String) {
        let data = Data(text.utf8)
        let n = data.withUnsafeBytes { Darwin.write(commandFD, $0.baseAddress!, $0.count) }
        if n != data.count { fail("Sender command pipe stalled") }
    }
    private func finishExit() {
        guard !failed, let exitStatus, closedStreams.count == 2 else { return }
        fail("Sender exited (\(exitStatus)) before reporting a transport error")
    }
    private func fail(_ reason: String) { guard !failed else { return }; failed = true; stop(); onFailure?(reason) }
    func stop() {
        failed = true; started = false; connected = false
        fragments.removeAll()
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        if commandFD >= 0 { close(commandFD); commandFD = -1 }
        unlink(fifo.path)
    }
    deinit { stop() }
}
