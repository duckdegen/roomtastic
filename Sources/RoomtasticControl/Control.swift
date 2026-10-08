// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import RoomtasticShared

public struct ControlState: Codable, Sendable {
    public var outputs: [AudioOutput] = []
    public var selected: [String] = []
    public var volume: Float = 0.5
    public var muted = false
    public var bypass = false
    public var running = false
    public var driverAvailable = false
    public var profiles: [CalibrationProfile] = []
    public var activeProfile: UUID?
    public var calibrationStatus = "Not calibrated"
    public var error: String?
    public var pairingURI: String?
    public var outputStatus: [String: String] = [:]
    /// Present only after an explicit receiver authentication challenge; never contains secrets.
    public var authenticationRequired: [String: String]?
    public init() {}
}
public struct ReceiverCredentials: Codable, Sendable {
    public var password: String?
    public var auth: String?
    public var legacySecret: String?
    public init(password: String? = nil, auth: String? = nil, legacySecret: String? = nil) {
        self.password = password; self.auth = auth; self.legacySecret = legacySecret
    }
}
public struct ControlRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case status, configure, activate, stop, preset, pair, shutdown, saveCredentials, forgetCredentials }
    public var action: Action
    public var selected: [String]?
    public var volume: Float?
    public var muted: Bool?
    public var bypass: Bool?
    public var profileID: UUID?
    public var outputID: String?
    public var receiverCredentials: ReceiverCredentials?
    public init(_ action: Action, selected: [String]? = nil, volume: Float? = nil, muted: Bool? = nil, bypass: Bool? = nil, profileID: UUID? = nil, outputID: String? = nil, receiverCredentials: ReceiverCredentials? = nil) {
        self.action = action; self.selected = selected; self.volume = volume; self.muted = muted; self.bypass = bypass; self.profileID = profileID
        self.outputID = outputID; self.receiverCredentials = receiverCredentials
    }
}
public enum ControlError: Error, LocalizedError {
    case unavailable, invalidResponse, system(Int32)
    public var errorDescription: String? {
        switch self { case .unavailable: return "Roomtastic audio service is not running."
        case .invalidResponse: return "Invalid service response."
        case .system(let n): return String(cString: strerror(n)) }
    }
}
public enum ControlSocket {
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Roomtastic", isDirectory: true) }
    public static var path: String { directory.appendingPathComponent("control.sock").path }
    public static func address() throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ControlError.invalidResponse }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyBytes(from: $0) } }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    public static func request(_ request: ControlRequest) throws -> ControlState {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.system(errno) }; defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, 4)
        var addr = try address()
        let connected = withUnsafePointer(to: &addr) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw ControlError.unavailable }
        var data = try JSONEncoder().encode(request); data.append(10)
        try sendAll(fd, data: data)
        let reply = try readLine(fd)
        return try JSONDecoder().decode(ControlState.self, from: reply)
    }
    public static func sendAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ControlError.system(errno) }; offset += n
            }
        }
    }
    public static func readLine(_ fd: Int32) throws -> Data {
        var result = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while result.count < 1_048_576 {
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ControlError.invalidResponse }
            if let end = bytes[..<n].firstIndex(of: 10) { result.append(contentsOf: bytes[..<end]); return result }
            result.append(contentsOf: bytes[..<n])
        }
        throw ControlError.invalidResponse
    }
}
