// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import RoomtasticControl
import RoomtasticShared

@MainActor final class MenuModel: ObservableObject {
    @Published var state = ControlState()
    @Published var serviceError: String?
    @Published var authenticationOutputID: String?
    private var polling: Task<Void, Never>?
    private var requestsInFlight = 0
    private var nextRequest: UInt64 = 0
    private var appliedRequest: UInt64 = 0
    private let controlQueue = DispatchQueue(label: "org.roomtastic.menu-control", qos: .userInitiated)
    init() {
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.send(ControlRequest(.status))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func send(_ request: ControlRequest) async {
        if request.action == .status && requestsInFlight > 0 { return }
        nextRequest &+= 1; let sequence = nextRequest
        requestsInFlight += 1; defer { requestsInFlight -= 1 }
        do {
            let result: ControlState = try await withCheckedThrowingContinuation { continuation in
                controlQueue.async { continuation.resume(with: Result { try ControlSocket.request(request) }) }
            }
            guard sequence >= appliedRequest else { return }
            appliedRequest = sequence; state = result; serviceError = nil
        } catch {
            guard sequence >= appliedRequest else { return }
            appliedRequest = sequence; serviceError = error.localizedDescription
        }
    }
    func act(_ request: ControlRequest) { Task { await send(request) } }
    func quit() async {
        if serviceError != nil && !state.running { NSApp.terminate(nil); return }
        await send(ControlRequest(.shutdown))
        if serviceError == nil { NSApp.terminate(nil); return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t Stop Playback"
        alert.informativeText = "The audio service didn’t respond. Quitting now may leave audio playing."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }
    func toggle(_ id: String) {
        var selected = state.selected
        if selected.contains(id) { selected.removeAll { $0 == id } } else { selected.append(id) }
        state.selected = selected
        act(ControlRequest(.configure, selected: selected))
    }
    func startService() {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RoomtasticService")
        let process = Process(); process.executableURL = executable
        do { try process.run() } catch { serviceError = error.localizedDescription }
    }
}
@main struct RoomtasticApp: App {
    @StateObject private var model = MenuModel()
    var body: some Scene {
        MenuBarExtra("Roomtastic", systemImage: "hifispeaker.2.fill") {
            MenuPanel(model: model)
        }.menuBarExtraStyle(.window)
        Window("Roomtastic Room Setup", id: "setup") {
            SetupPanel(model: model).frame(minWidth: 580, minHeight: 580)
        }.defaultSize(width: 640, height: 680)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Roomtastic") { Task { await model.quit() } }.keyboardShortcut("q")
            }
        }
    }
}
struct MenuPanel: View {
    @ObservedObject var model: MenuModel
    @Environment(\.openWindow) private var openWindow
    private func showSetup() { openWindow(id: "setup"); NSApp.activate(ignoringOtherApps: true) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Roomtastic", systemImage: "hifispeaker.2.fill").font(.headline)
                Spacer()
                Text(model.state.running ? "Playing" : "Stopped").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Speakers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.state.outputs.isEmpty {
                Text("Looking for speakers…").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.state.outputs) { output in
                    VStack(alignment: .leading, spacing: 3) {
                        Button { model.toggle(output.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: output.kind == .airplay ? "airplay.audio" : "cable.connector")
                                    .foregroundStyle(.secondary).frame(width: 20)
                                Text(output.name).lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .opacity(model.state.selected.contains(output.id) ? 1 : 0)
                            }
                            .padding(.vertical, 5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(output.name)
                        .accessibilityValue(model.state.selected.contains(output.id) ? "Selected" : "Not selected")
                        .disabled(!output.available && !model.state.selected.contains(output.id))
                        if !output.available {
                            Text("Unavailable").font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
                        } else if model.state.authenticationRequired?[output.id] != nil {
                            Button("Authentication Required…") {
                                model.authenticationOutputID = output.id; showSetup()
                            }.font(.caption).buttonStyle(.link).padding(.leading, 30)
                        } else if let status = model.state.outputStatus[output.id],
                                  !status.hasPrefix("Playback acknowledged at ") {
                            Button(status == "Receiver connected; preparing playback clock" ? "Preparing…" : "Connection Details…") { showSetup() }
                                .font(.caption).buttonStyle(.link).padding(.leading, 30)
                        }
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 10) {
                Button { model.act(ControlRequest(.configure, muted: !model.state.muted)) } label: {
                    Image(systemName: model.state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help(model.state.muted ? "Unmute" : "Mute")
                .accessibilityLabel(model.state.muted ? "Unmute Audio" : "Mute Audio")
                Slider(value: Binding(get: { Double(model.state.volume) }, set: { model.act(ControlRequest(.configure, volume: Float($0))) }), in: 0...1)
                    .accessibilityLabel("Playback Volume")
                Text("\(Int(model.state.volume * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 36)
            }
            if !model.state.profiles.isEmpty {
                Picker("Listening Position", selection: Binding(get: { model.state.activeProfile }, set: { id in
                    if let id { model.act(ControlRequest(.preset, profileID: id)) }
                })) {
                    Text("Choose Position").tag(nil as UUID?)
                    ForEach(model.state.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }
                Toggle("Bypass Correction", isOn: Binding(get: { model.state.bypass }, set: { model.act(ControlRequest(.configure, bypass: $0)) }))
                    .help("Bypass tonal correction while keeping timing adjustments.")
                Label(model.state.calibrationStatus, systemImage: "waveform.path")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Not calibrated").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Set Up…") { showSetup() }.buttonStyle(.link).font(.caption)
                }
            }
            if model.serviceError != nil {
                Button("Start Audio Service") { model.startService() }
            } else if !model.state.driverAvailable {
                Text("Install the Roomtastic audio driver to begin.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button { model.act(ControlRequest(model.state.running ? .stop : .activate)) } label: {
                    Label(model.state.running ? "Stop Playback" : "Start Playback", systemImage: model.state.running ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }.controlSize(.large)
                    .help(model.state.running ? "Stop Roomtastic and restore your previous system output." : "Route system audio to the selected speakers.")
                    .disabled(!model.state.running && model.state.selected.isEmpty)
            }
            if model.state.error != nil || model.serviceError != nil {
                Button { showSetup() } label: { Label("Review Connection Issue…", systemImage: "exclamationmark.circle") }
                    .buttonStyle(.link).font(.caption)
            }
            Divider()
            Button { showSetup() } label: {
                HStack { Text("Room Setup…"); Spacer(); Text("⌘,").foregroundStyle(.secondary) }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).keyboardShortcut(",")
            Button {
                Task { await model.quit() }
            } label: {
                HStack { Text("Quit Roomtastic"); Spacer(); Text("⌘Q").foregroundStyle(.secondary) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut("q")
            .help("Stop playback, restore your previous system output, and quit.")
        }.padding(16).frame(width: 340)
    }
}
struct SetupPanel: View {
    @ObservedObject var model: MenuModel
    @State private var credentialOutput = ""
    @State private var receiverPassword = ""
    @State private var receiverAuth = ""
    @State private var receiverLegacySecret = ""
    private var authenticationOutputs: [AudioOutput] {
        model.state.outputs.filter { $0.kind == .airplay && model.state.authenticationRequired?[$0.id] != nil }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Room Setup", systemImage: "viewfinder").font(.largeTitle.bold())
                Text("Scan and measure with a LiDAR-capable iPhone").font(.title3)
                Text("Select your speakers in the menu, then connect the iPhone companion. Scan one room, mark speakers and listening positions, and measure at the ear position plus eight nearby points. Keep the phone still with its microphone facing consistently.")
                Button("Create Private Pairing QR Code") { model.act(ControlRequest(.pair)) }.buttonStyle(.borderedProminent)
                if let code = model.state.pairingURI, let image = qrImage(code) {
                    HStack { Spacer(); Image(nsImage: image).interpolation(.none).resizable().frame(width: 260, height: 260).padding(12).background(.white); Spacer() }
                    Text("Scan this code in Roomtastic on your iPhone. It contains a one-time secret; do not share screenshots. Expires after five minutes.").font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("What calibration does") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Arrival timing, relative level, and conservative frequency correction are measured—not inferred from speaker orientation.")
                        Text("Your linked 2.1 system keeps its hardware crossover and subwoofer timing. Its subwoofer is drawn separately but never treated as another output.")
                        Text("A preset is verified only after fresh measurements of the complete selected system pass. Missing speakers and changed connections require verification.")
                    }.padding(6)
                }
                if !authenticationOutputs.isEmpty {
                GroupBox("Receiver requested authentication") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Receiver", selection: $credentialOutput) {
                            Text("Choose receiver").tag("")
                            ForEach(authenticationOutputs) { output in Text(output.name).tag(output.id) }
                        }
                        if let reason = model.state.authenticationRequired?[credentialOutput] {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        SecureField("Receiver password (if required)", text: $receiverPassword)
                        DisclosureGroup("Existing pairing credentials") {
                            SecureField("AirPlay 2 credentials (192 hex characters)", text: $receiverAuth)
                            SecureField("Legacy pairing secret", text: $receiverLegacySecret)
                        }
                        HStack {
                            Button("Save in Keychain") {
                                model.act(ControlRequest(.saveCredentials, outputID: credentialOutput, receiverCredentials: ReceiverCredentials(password: receiverPassword.isEmpty ? nil : receiverPassword, auth: receiverAuth.isEmpty ? nil : receiverAuth, legacySecret: receiverLegacySecret.isEmpty ? nil : receiverLegacySecret)))
                                receiverPassword = ""; receiverAuth = ""; receiverLegacySecret = ""
                            }.disabled(model.state.authenticationRequired?[credentialOutput] == nil)
                            Button("Forget Credentials") { model.act(ControlRequest(.forgetCredentials, outputID: credentialOutput)) }.disabled(credentialOutput.isEmpty)
                        }
                        Text("Passwordless receivers connect automatically. These credentials are requested only after this receiver reports an authentication failure; saved values are used on its next connection.").font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                }
                Text("Phone microphones do not establish an accurate absolute frequency response. Measurement-microphone comparison and the 1 ms / 30-minute synchronization target require hardware validation.").font(.caption).foregroundStyle(.secondary)
                Text(model.state.calibrationStatus).font(.headline)
                if let error = model.state.error ?? model.serviceError { Text(error).foregroundStyle(.red) }
                DisclosureGroup("Connection Details") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.state.outputs.filter { model.state.outputStatus[$0.id] != nil }) { output in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(output.name).font(.headline)
                                Text(model.state.outputStatus[output.id] ?? "").font(.caption).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(28)
        }
        .onAppear { credentialOutput = model.authenticationOutputID ?? authenticationOutputs.first?.id ?? "" }
        .onChange(of: model.authenticationOutputID) { _, id in if let id { credentialOutput = id } }
        .onChange(of: credentialOutput) { _, _ in receiverPassword = ""; receiverAuth = ""; receiverLegacySecret = "" }
    }
    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
