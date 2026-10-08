// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import RoomtasticControl

@main enum ServiceMain {
    static func main() {
        do {
            let args = CommandLine.arguments
            if args.contains("--status") || args.contains("--shutdown") {
                let state = try ControlSocket.request(ControlRequest(args.contains("--shutdown") ? .shutdown : .status))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(state), as: UTF8.self)); return
            }
            if args.contains("--discover") {
                let discovery = ReceiverDiscovery(); discovery.start()
                RunLoop.main.run(until: Date().addingTimeInterval(8)); discovery.stop()
                let outputs = try Hardware.outputDevices().map(\.0) + discovery.receivers.values.map(\.output)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(outputs.sorted { $0.id < $1.id }), as: UTF8.self)); return
            }
            let service = Service(); try service.start()
            if let flag = args.firstIndex(of: "--run-for") {
                guard flag + 1 < args.count, let seconds = Double(args[flag + 1]), (1...3600).contains(seconds) else { throw AudioFailure("--run-for requires 1–3600 seconds") }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { service.shutdown(); print("Roomtastic bounded run finished"); exit(0) }
            }
            var signals: [DispatchSourceSignal] = []
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { service.shutdown(); exit(0) }; source.resume(); signals.append(source)
            }
            print("Roomtastic service ready: \(ControlSocket.path)")
            fflush(stdout)
            withExtendedLifetime(signals) { RunLoop.main.run() }
        } catch {
            FileHandle.standardError.write(Data("Roomtastic: \(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
}
