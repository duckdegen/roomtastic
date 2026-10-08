// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreAudio
import AudioToolbox
import RoomtasticShared
import Darwin

struct AudioFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func checked(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioFailure("\(operation): Core Audio error \(status)") }
}
enum Hardware {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var address = address(selector, scope); var value = initial; var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try checked(AudioObjectGetPropertyData(id, &address, 0, nil, &size, bytes.baseAddress!), "Read property")
        }
        guard size == MemoryLayout<T>.size else { throw AudioFailure("Unexpected Core Audio property size") }
        return value
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        try checked(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result), "Read device identifier")
        guard let result else { throw AudioFailure("Core Audio returned no device identifier") }
        return result.takeRetainedValue() as String
    }
    static func devices() throws -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices); var size: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "List devices")
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids), "List devices")
        return ids
    }
    static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope); var size: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "Read device channels")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment); defer { raw.deallocate() }
        try checked(AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw), "Read device channels")
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func outputDevices() throws -> [(AudioOutput, AudioDeviceID)] {
        try devices().compactMap { id in
            let channels = try channels(id, scope: kAudioDevicePropertyScopeOutput)
            guard channels > 0 else { return nil }
            let uid = try string(id, kAudioDevicePropertyDeviceUID)
            guard uid != "Roomtastic_UID" else { return nil }
            return (AudioOutput(id: "coreaudio:" + uid, name: try string(id, kAudioObjectPropertyName), kind: .wired, channels: channels, sampleRate: try value(id, kAudioDevicePropertyNominalSampleRate, Double(48000)), available: true), id)
        }
    }
    static func driver() throws -> AudioDeviceID? { try devices().first { try string($0, kAudioDevicePropertyDeviceUID) == "Roomtastic_UID" } }
    static func defaultOutput() throws -> AudioDeviceID { try value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0)) }
    static func setDefault(_ id: AudioDeviceID) throws {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice); var value = id
        try checked(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value), "Select system output")
    }
    static func setRate(_ id: AudioDeviceID, rate: Double) throws {
        var address = address(kAudioDevicePropertyNominalSampleRate); var rate = rate
        try checked(AudioObjectSetPropertyData(id, &address, 0, nil, 8, &rate), "Set sample rate")
    }
    static func streamFormat(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        let format = try value(id, kAudioDevicePropertyStreamFormat, AudioStreamBasicDescription(), scope: scope)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { throw AudioFailure("Device does not provide Float32 PCM") }
        return format
    }
    static func deviceDelay(_ id: AudioDeviceID) -> Double {
        let rate = (try? value(id, kAudioDevicePropertyNominalSampleRate, Double(48000))) ?? 48000
        let frames = (try? value(id, kAudioDevicePropertyLatency, UInt32(0), scope: kAudioDevicePropertyScopeOutput)) ?? 0
        return Double(frames) / rate
    }
}
struct Receiver {
    var output: AudioOutput
    var host: String
    var port: Int
    var txt: [String: String]
}
final class ReceiverDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browsers = [NetServiceBrowser(), NetServiceBrowser()]
    private var services: [String: NetService] = [:]
    private var records: [String: Receiver] = [:]
    private var addressRefresh: Timer?
    var receivers: [String: Receiver] = [:]
    var changed: (() -> Void)?
    private func key(_ service: NetService) -> String { service.type + service.domain + service.name }
    func start() {
        for (browser, type) in zip(browsers, ["_raop._tcp.", "_airplay._tcp."]) {
            browser.delegate = self; browser.searchForServices(ofType: type, inDomain: "local.")
        }
        addressRefresh = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.services.values.forEach { $0.resolve(withTimeout: 5) }
        }
    }
    func stop() { addressRefresh?.invalidate(); addressRefresh = nil; browsers.forEach { $0.stop() }; services.values.forEach { $0.stop() } }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services[key(service)] = service; service.delegate = self
        service.resolve(withTimeout: 5); service.startMonitoring()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeValue(forKey: key(service))?.stop()
        if let removed = records.removeValue(forKey: key(service)) { rebuild(removed.output.id) }
    }
    func netServiceDidResolveAddress(_ service: NetService) { update(service, txtRecord: service.txtRecordData()) }
    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) { update(sender, txtRecord: data) }
    private func update(_ service: NetService, txtRecord: Data?) {
        guard services[key(service)] === service, let host = ipv4Address(service), let raw = txtRecord, service.port > 0 else { return }
        let txt = NetService.dictionary(fromTXTRecord: raw).compactMapValues { String(data: $0, encoding: .utf8) }
        let prefix = service.name.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        let deviceID = (txt["deviceid"] ?? prefix).replacingOccurrences(of: ":", with: "").uppercased()
        guard deviceID.count == 12, deviceID.allSatisfy({ $0.isHexDigit }) else { return }
        let id = "airplay:" + deviceID
        let name = service.name.split(separator: "@", maxSplits: 1).last.map(String.init) ?? service.name
        let previousID = records[key(service)]?.output.id
        records[key(service)] = Receiver(output: AudioOutput(id: id, name: name, kind: .airplay, channels: max(1, min(2, Int(txt["ch"] ?? "2") ?? 2)), sampleRate: Double(txt["sr"] ?? "44100") ?? 44100, available: true), host: host, port: service.port, txt: txt)
        if let previousID, previousID != id { rebuild(previousID) }
        rebuild(id)
    }
    private func ipv4Address(_ service: NetService) -> String? {
        // cliairplay resolves RTSP names but its native media/PTP paths require IPv4 literals.
        for data in service.addresses ?? [] {
            let host: String? = data.withUnsafeBytes { bytes in
                guard bytes.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var address = bytes.loadUnaligned(as: sockaddr_in.self)
                guard address.sin_family == sa_family_t(AF_INET) else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let host { return host }
        }
        return nil
    }
    private func rebuild(_ id: String) {
        let matching = records.filter { $0.value.output.id == id }.sorted { $0.key > $1.key }
        guard var receiver = matching.first?.value else { receivers.removeValue(forKey: id); changed?(); return }
        // RAOP provides channel/codec fields; AirPlay provides native timing/auth capabilities.
        for record in matching { receiver.txt.merge(record.value.txt) { _, new in new } }
        if let native = matching.first(where: { $0.key.hasPrefix("_airplay.") }) {
            receiver.host = native.value.host; receiver.port = native.value.port; receiver.output.name = native.value.output.name
        }
        receivers[id] = receiver; changed?()
    }
}
