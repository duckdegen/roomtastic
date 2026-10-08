// SPDX-License-Identifier: MIT
import SwiftUI
import Charts
import RoomtasticShared

@main struct RoomtasticPhoneApp: App {
    @StateObject private var model = PhoneModel()
    var body: some Scene { WindowGroup { CompanionView().environmentObject(model) } }
}
struct CompanionView: View {
    @EnvironmentObject var model: PhoneModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection = false
    @State private var alignment = false
    @State private var scanning = false
    @State private var finishScan = false
    @State private var confirmRescan = false
    var body: some View {
        NavigationStack {
            List {
                if !model.sessionInProgress { Section {
                    Button { connection = true } label: {
                        HStack {
                            Label("Mac", systemImage: "desktopcomputer")
                            Spacer()
                            Text(model.connected ? "Connected" : "Not connected").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.foregroundStyle(.primary)
                    }.buttonStyle(.plain).disabled(model.sessionInProgress && !model.sessionPaused)
                    NavigationLink { RoomEditor() } label: {
                        Label("Room & Speakers", systemImage: "speaker.wave.2")
                    }.disabled(model.sessionInProgress)
                    if model.scanned {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            Button { alignment = true } label: {
                                HStack {
                                    Label("Room Alignment", systemImage: "viewfinder")
                                    Spacer()
                                    Text(model.roomTrackingReady ? "Ready" : "Align").foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }.foregroundStyle(.primary)
                            }.buttonStyle(.plain)
                        }
                    }
                } }
                if model.sessionInProgress {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(PositionCompassView.pointName(model.pointIndex)).font(.title2.bold())
                                Spacer()
                                Text("\(model.pointIndex + 1) of 9").foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(model.captureLabel).font(.subheadline.weight(.semibold))
                            Text(model.captureOutputLabel).font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: Double(model.pointIndex) + (model.purpose == .calibration ? Double(model.speakerIndex) / Double(max(1, model.positionTestCount)) : 0), total: 9)
                            Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                                PositionCompassView(grid: model.measurementGrid, pointIndex: model.pointIndex,
                                                    microphonePosition: model.trackedMicrophonePosition)
                            }
                            if model.sessionPaused {
                                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                                    if model.connected && !model.roomTrackingReady {
                                        Button("Align Room to Continue") { alignment = true }
                                            .buttonStyle(.borderedProminent).controlSize(.large)
                                    } else {
                                        Button(model.resumePending ? "Reconnecting…" : !model.connected ? "Reconnect to Mac" : model.captureRetryReason != nil ? "Retry This Sample" : "Resume Calibration") { model.resumeCalibration() }
                                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.resumePending)
                                    }
                                }
                            } else if model.positionRunActive {
                                HStack {
                                    ProgressView()
                                    Text("Test \(model.positionTestNumber) of \(model.positionTestCount)").monospacedDigit()
                                    Spacer()
                                    Button("Pause") { model.pausePositionMeasurements() }.buttonStyle(.bordered)
                                }
                            } else if model.guided {
                                Button("Measure This Position") { model.startPositionMeasurements() }
                                    .frame(maxWidth: .infinity)
                                    .buttonStyle(.borderedProminent).controlSize(.large)
                                    .disabled(!model.canMeasure)
                            } else {
                                ProgressView("Verifying measurements…")
                            }
                        }.padding(.vertical, 8)
                        Button("Cancel Measurement", role: .destructive) { model.cancel() }
                    } header: { Text("Measurement") }
                      footer: { Text(model.purpose == .calibration ? "Stay here while all channels are measured automatically. Move only when prompted." : "This check plays all selected speakers together. Move only when prompted.") }
                } else {
                    Section {
                        Picker("Listening Position", selection: $model.selectedPosition) {
                            Text("Choose a position").tag(nil as UUID?)
                            ForEach(model.room.positions) { Text($0.name).tag(Optional($0.id)) }
                        }.pickerStyle(.navigationLink)
                        MeasurementLevelControl()
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            VStack(alignment: .leading, spacing: 12) {
                                if !model.supported {
                                    Text("Calibration requires an iPhone or iPad with LiDAR.").foregroundStyle(.secondary)
                                } else if !model.connected {
                                    Button("Connect to Mac") { connection = true }
                                        .buttonStyle(.borderedProminent).controlSize(.large)
                                } else if !model.scanned {
                                    Button("Scan Room") { finishScan = false; scanning = true }
                                        .buttonStyle(.borderedProminent).controlSize(.large)
                                } else if model.measurableSpeakers.isEmpty || model.selectedPosition == nil {
                                    NavigationLink("Set Up Speakers & Listener") { RoomEditor() }
                                        .buttonStyle(.borderedProminent).controlSize(.large)
                                } else if !model.roomTrackingReady {
                                    Button("Align Room") { alignment = true }
                                        .buttonStyle(.borderedProminent).controlSize(.large)
                                } else {
                                    Button("Start Calibration") { model.beginPosition() }
                                        .buttonStyle(.borderedProminent).controlSize(.large)
                                        .disabled(model.volumeRequestPending || (model.reportedMasterVolume ?? 0) <= 0)
                                }
                            }.frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
                        }
                    } header: { Text("Calibration") }
                      footer: { Text("Choose a comfortable level. It stays fixed while speakers are measured and balanced.") }
                }
                if let profile = model.profile {
                    Section {
                        NavigationLink {
                            List {
                                Section {
                                    Text(profile.name).font(.headline)
                                    Label(profile.hasMeasuredVerification ? "Verified" : "Needs Verification", systemImage: profile.hasMeasuredVerification ? "checkmark.seal" : "exclamationmark.circle")
                                    if let conditions = profile.conditions { LabeledContent("Measured", value: conditions.capturedAt.formatted(date: .abbreviated, time: .shortened)) }
                                }
                                Section("Frequency Response") { ResponseChart(profile: profile).frame(height: 220) }
                            }.navigationTitle("Saved Calibration")
                        } label: {
                            Label("Saved Calibration", systemImage: "waveform.path.ecg")
                        }
                    }
                }
            }
            .navigationTitle("Calibrate")
            .navigationBarTitleDisplayMode(model.sessionInProgress ? .inline : .large)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.applicationDidEnterBackground() }
                else if phase == .active { model.applicationBecameActive() }
                else if phase == .inactive { model.applicationWillResignActive() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink { MeasurementHelpView() } label: { Label("How to Measure", systemImage: "questionmark.circle") }
                        NavigationLink { MeasurementSettingsView() } label: { Label("Measurement Settings", systemImage: "slider.horizontal.3") }
                        Button {
                            if model.scanned { confirmRescan = true }
                            else { finishScan = false; scanning = true }
                        } label: { Label(model.scanned ? "Rescan Room" : "Scan Room", systemImage: "viewfinder") }
                            .disabled(!model.supported || model.sessionInProgress)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Calibration Options")
                }
            }
            .confirmationDialog("Rescan this room?", isPresented: $confirmRescan, titleVisibility: .visible) {
                Button(model.scanned ? "Rescan Room" : "Scan Room", role: model.scanned ? .destructive : nil) { finishScan = false; scanning = true }
            } message: { Text("A new scan requires fresh calibration.") }
            .sheet(isPresented: $connection) { MacConnectionView() }
            .sheet(isPresented: $alignment) { RoomAlignmentView() }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    RoomScanner(finish: $finishScan, onRoom: { model.saveScan($0); scanning = false }, arSession: model.trackingSession, onFailure: { model.error = $0; scanning = false })
                        .navigationTitle("Scan Room")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } }; ToolbarItem(placement: .confirmationAction) { Button("Finish") { finishScan = true }.disabled(finishScan) } }
                }.interactiveDismissDisabled()
            }
            .alert("Roomtastic", isPresented: Binding(get: { model.error != nil && !connection && !alignment }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}
private struct MeasurementLevelControl: View {
    @EnvironmentObject var model: PhoneModel
    @State private var level = 0.0
    @State private var editing = false
    var body: some View {
        VStack(spacing: 8) {
            LabeledContent("Measurement Level", value: model.volumeRequestPending ? "Updating…" : model.reportedMasterVolume.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Unavailable")
            if model.reportedMasterVolume != nil {
                Slider(value: $level, in: 0...1, step: 0.01) {
                    Text("Measurement Level")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                } onEditingChanged: { active in
                    editing = active
                    if !active { model.setPlaybackVolume(level) }
                }
                .disabled(!model.connected || model.sessionInProgress || model.volumeRequestPending)
                .accessibilityLabel("Measurement Level")
            }
        }
        .onAppear { level = model.reportedMasterVolume ?? 0 }
        .onChange(of: model.reportedMasterVolume) { _, value in if !editing { level = value ?? 0 } }
    }
}
private struct MacConnectionView: View {
    @EnvironmentObject var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var pastedCode = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.connected ? "Connected to Mac" : "Not Connected", systemImage: model.connected ? "checkmark.circle.fill" : "desktopcomputer")
                    Button("Reconnect Saved Mac") { model.reconnect() }
                    Button("Scan Pairing Code") { pairing = true }
                } footer: { Text("Use Wi-Fi on your Mac’s network. Find the pairing code in Mac → Room Setup.") }
                Section {
                    DisclosureGroup("Enter Code Manually") {
                        TextField("Pairing code", text: $pastedCode, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Connect") { model.pair(pastedCode); pastedCode = "" }.disabled(pastedCode.isEmpty)
                    }
                }
                if !model.connected { Section { Text(model.status).font(.subheadline).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Connect to Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: model.connected) { _, connected in if connected { dismiss() } }
            .sheet(isPresented: $pairing) {
                NavigationStack {
                    QRScanner(onCode: { code in pairing = false; model.pair(code) }, onFailure: { model.error = $0; pairing = false })
                        .ignoresSafeArea(edges: .bottom).navigationTitle("Scan Pairing Code")
                        .toolbar { Button("Cancel") { pairing = false } }
                }
            }
            .alert("Connection", isPresented: Binding(get: { model.error != nil && !pairing }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}
private struct RoomAlignmentView: View {
    @EnvironmentObject var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TrackingPreview(session: model.trackingSession).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 12))
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Label(model.roomTrackingReady ? "Room Aligned" : "Look Around Your Room", systemImage: model.roomTrackingReady ? "checkmark.circle.fill" : "viewfinder")
                        if model.sessionInProgress, let target = model.guidedTargetPosition, let current = model.trackedMicrophonePosition {
                            let distance = sqrt(pow(target.x - current.x, 2) + pow(target.y - current.y, 2) + pow(target.z - current.z, 2))
                            LabeledContent("Distance to Position", value: "\(Int((distance * 100).rounded())) cm")
                        }
                    }
                } footer: { Text("Point the camera toward familiar parts of your scanned room.") }
                if model.sessionInProgress {
                    Section {
                        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                            PositionCompassView(grid: model.measurementGrid, pointIndex: model.pointIndex,
                                                microphonePosition: model.trackedMicrophonePosition)
                        }
                    }
                }
                Section {
                    DisclosureGroup("Position Details") {
                        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                            if let p = model.trackedMicrophonePosition { Text("Microphone: X \(p.x, specifier: "%.2f"), Y \(p.y, specifier: "%.2f"), Z \(p.z, specifier: "%.2f") m").monospacedDigit() }
                            if model.sessionInProgress, let p = model.guidedTargetPosition { Text("Target: X \(p.x, specifier: "%.2f"), Y \(p.y, specifier: "%.2f"), Z \(p.z, specifier: "%.2f") m").monospacedDigit() }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Restart Alignment") { model.relocalizeRoom() }.disabled(model.sessionInProgress && !model.sessionPaused)
                }
            }
            .navigationTitle("Room Alignment").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if !model.roomTrackingReady && (!model.sessionInProgress || model.sessionPaused) { model.relocalizeRoom() } }
            .alert("Roomtastic", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}
private struct MeasurementSettingsView: View {
    @EnvironmentObject var model: PhoneModel
    @State private var confirmDelete = false
    var body: some View {
        Form {
            Section {
                LabeledContent("Layout Name") {
                    TextField("e.g. Sofa by window", text: $model.furnitureRevision)
                        .multilineTextAlignment(.trailing).accessibilityLabel("Layout name")
                }.disabled(model.sessionInProgress)
            } header: { Text("Room Conditions") }
              footer: { Text("Rename the layout after moving furniture, so old measurements aren’t reused.") }
            Section {
                Toggle("Keep Recordings", isOn: $model.retainRaw).disabled(model.sessionInProgress)
                Button("Delete Saved Recordings", role: .destructive) { confirmDelete = true }.disabled(model.sessionInProgress)
            } header: { Text("Recordings") }
              footer: { Text("Recordings are encrypted in transit and deleted after processing unless kept. Calibration results remain saved.") }
        }
        .navigationTitle("Measurement Settings").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete saved recordings?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Recordings", role: .destructive) { model.deleteRaw() }
        } message: { Text("Your room and calibration results will be kept.") }
    }
}
private struct MeasurementHelpView: View {
    var body: some View {
        List {
            Section("Before You Start") {
                Label("Keep the room quiet.", systemImage: "speaker.slash")
                Label("Choose a comfortable measurement level.", systemImage: "speaker.wave.2")
                Label("Leave furniture and doors in place.", systemImage: "sofa")
            }
            Section("At Each Position") {
                Text("Hold the phone upright, screen toward you, with its bottom microphone at ear height.")
                Text("The first measurement anchors the center where you hold the microphone. Follow the next eight position prompts.")
                Text("Start Calibration runs every channel at Center automatically. At each new position, tap Measure This Position once and stay there until all its tests finish.")
            }
            Section("Verification") {
                Text("Individual measurements isolate the selected output and channel. Short timing chirps bracket each sweep. Only the final complete-system checks play every selected output together.")
            }
        }.navigationTitle("How to Measure").navigationBarTitleDisplayMode(.inline)
    }
}
struct RoomEditor: View {
    @EnvironmentObject var model: PhoneModel
    @State private var selectedTag: UUID?
    @State private var adding: NewTagKind?
    var body: some View {
        List {
            Section("Room layout") {
                TextField("Room name", text: $model.room.name)
                Picker("Selected tag", selection: $selectedTag) {
                    Text("Choose a tag to move").tag(nil as UUID?)
                    ForEach(model.room.mapTags) { tag in
                        if let speaker = model.room.speakers.first(where: { $0.id == tag.id }) {
                            Text("\(tag.label) · \(model.room.assignmentLabel(for: speaker, outputs: model.outputs))").tag(Optional(tag.id))
                        } else { Text(tag.label).tag(Optional(tag.id)) }
                    }
                }
                .accessibilityIdentifier("room.tagSelector")
                RoomMap(room: model.room, selectedTag: selectedTag, onMove: moveTag).frame(height: 280)
                Text("Choose a named tag above, then tap or drag on the map to move it. Height, facing and output mapping stay unchanged. Overlapping tags can be selected individually.").font(.caption)
                MapLegend()
            }
            Section("Speakers") {
                ForEach($model.room.speakers) { $speaker in
                    NavigationLink { SpeakerEditor(speaker: $speaker) } label: {
                        VStack(alignment: .leading) {
                            Label(speaker.name, systemImage: speaker.linkedSubwoofer ? "hifispeaker.fill" : "speaker.wave.2")
                            Text(model.room.assignmentLabel(for: speaker, outputs: model.outputs)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.onDelete { indices in
                    guard !model.sessionInProgress else { return }
                    model.room.speakers.remove(atOffsets: indices); model.saveRoom()
                }
                Button("Add speaker") { adding = .speaker }.accessibilityIdentifier("room.addSpeaker")
                Button("Add linked subwoofer") { adding = .subwoofer }
                    .accessibilityIdentifier("room.addSubwoofer")
                Text("A linked subwoofer belongs to a chosen speaker's timing group, with no independent output. Add an independently wired subwoofer as an ordinary speaker.").font(.caption)
            }
            Section("Listeners") {
                ForEach($model.room.positions) { $position in
                    NavigationLink(position.name) { ListenerEditor(position: $position) }
                }.onDelete { indices in
                    guard !model.sessionInProgress else { return }
                    model.room.positions.remove(atOffsets: indices); model.saveRoom()
                }
                Button("Add listener") { adding = .listener }.accessibilityIdentifier("room.addListener")
            }
        }
        .navigationTitle("Room & tags")
        .disabled(model.sessionInProgress)
        .sheet(item: $adding) { kind in NewTagSheet(kind: kind) }
        .onDisappear { if !model.sessionInProgress { model.saveRoom() } }
    }
    private func moveTag(_ location: Point3) {
        guard !model.sessionInProgress, let selectedTag else { return }
        if let index = model.room.speakers.firstIndex(where: { $0.id == selectedTag }) {
            model.room.speakers[index].position.x = location.x
            model.room.speakers[index].position.z = location.z
        } else if let index = model.room.positions.firstIndex(where: { $0.id == selectedTag }) {
            model.room.positions[index].position.x = location.x
            model.room.positions[index].position.z = location.z
        }
        model.saveRoom()
    }
}

private enum NewTagKind: String, Identifiable {
    case speaker, subwoofer, listener
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speaker: "Speaker"
        case .subwoofer: "Linked subwoofer"
        case .listener: "Listener"
        }
    }
}

private enum PlacementMethod: String, Identifiable {
    case camera, map, microphone
    var id: String { rawValue }
}

private struct OutputChannelPicker: View {
    @EnvironmentObject var model: PhoneModel
    @Binding var outputID: String?
    @Binding var channel: Int?
    var excludingSpeakerID: UUID?
    var body: some View {
        Picker("Receiver / output", selection: Binding(get: { outputID }, set: { outputID = $0; channel = nil })) {
            Text("Choose an output").tag(nil as String?)
            ForEach(model.assignableOutputs) { output in Text(output.name).tag(Optional(output.id)) }
            if let outputID, !model.assignableOutputs.contains(where: { $0.id == outputID }) {
                Text("\(model.outputs.first(where: { $0.id == outputID })?.name ?? outputID) (unavailable)").tag(Optional(outputID))
            }
        }
        .accessibilityIdentifier("mapping.output")
        if let output = model.assignableOutputs.first(where: { $0.id == outputID }) {
            Picker("Channel", selection: $channel) {
                Text("Choose a channel").tag(nil as Int?)
                ForEach(0..<min(output.channels, 2), id: \.self) { index in
                    let assigned = model.room.channelIsAssigned(ChannelConnection(outputID: output.id, channel: index), excluding: excludingSpeakerID)
                    Text("\(channelLabel(index, channels: output.channels))\(assigned ? " (already assigned)" : "")")
                        .tag(Optional(index)).disabled(assigned)
                }
            }
            .accessibilityIdentifier("mapping.channel")
            Text("Only the first stereo pair is supported: 1 = Left, 2 = Right. Mono outputs use channel 1. Choose the channel wired to this physical speaker.").font(.caption)
        }
    }
}

private func channelLabel(_ channel: Int, channels: Int) -> String {
    channels == 1 ? "1 · Mono" : (channel == 0 ? "1 · Left" : "2 · Right")
}

private func availableConnection(outputID: String?, channel: Int?, outputs: [AudioOutput], room: RoomModel, excluding speakerID: UUID? = nil) -> ChannelConnection? {
    guard let outputID, let channel, let output = outputs.first(where: { $0.id == outputID }),
          channel >= 0, channel < min(output.channels, 2) else { return nil }
    let connection = ChannelConnection(outputID: outputID, channel: channel)
    return room.channelIsAssigned(connection, excluding: speakerID) ? nil : connection
}

private func mappedParents(room: RoomModel, outputs: [AudioOutput], excluding speakerID: UUID? = nil) -> [PhysicalSpeaker] {
    room.speakers.filter { speaker in
        guard speaker.id != speakerID, !speaker.linkedSubwoofer, let connection = speaker.connection else { return false }
        return connection.channel >= 0 && connection.channel < 2 &&
            outputs.contains { $0.id == connection.outputID && $0.channels >= 2 }
    }
}

private struct LinkedParentPicker: View {
    @EnvironmentObject var model: PhoneModel
    @Binding var parentID: UUID?
    var excludingSpeakerID: UUID?
    private var parents: [PhysicalSpeaker] { mappedParents(room: model.room, outputs: model.assignableOutputs, excluding: excludingSpeakerID) }
    var body: some View {
        Picker("Parent stereo speaker", selection: $parentID) {
            Text("Choose a mapped parent").tag(nil as UUID?)
            ForEach(parents) { speaker in
                Text("\(speaker.name) · \(model.room.assignmentLabel(for: speaker, outputs: model.outputs))").tag(Optional(speaker.id))
            }
            if let parentID, !parents.contains(where: { $0.id == parentID }) {
                Text("\(model.room.speakers.first(where: { $0.id == parentID })?.name ?? "Selected parent") (unavailable)")
                    .tag(Optional(parentID))
            }
        }
        .accessibilityIdentifier("mapping.parent")
        if let parent = parents.first(where: { $0.id == parentID }), let connection = parent.connection,
           let output = model.assignableOutputs.first(where: { $0.id == connection.outputID }) {
            LabeledContent("Inherited receiver", value: output.name)
        }
        if parents.isEmpty {
            Text("Map a non-sub speaker to an available stereo output first. A linked subwoofer needs that hardware parent; mono and unassigned speakers cannot be parents.").font(.caption)
        }
        Text("This is a hardware-linked subwoofer, not a separate playback channel. Its parent's left/right speakers and linked subs share one timing group.").font(.caption)
    }
}

private struct MappingConnectionControls: View {
    @EnvironmentObject var model: PhoneModel
    @State private var pairing = false
    @State private var pairingError: String?
    var body: some View {
        Section("Mac connection") {
            if !model.connected {
                Text("Pair your Mac first to choose its real audio outputs. Your name and placement stay in this draft while you connect.")
            } else if model.assignableOutputs.isEmpty {
                Text("No usable outputs are available from the Mac. Check the receiver is online, then refresh outputs. Your draft stays here.")
            } else {
                Label("Mac connected", systemImage: "lock.shield")
            }
            Button("Scan Mac pairing QR") { pairing = true }.accessibilityIdentifier("mapping.pair")
            Button("Reconnect saved Mac") { model.reconnect() }
            Button("Refresh outputs") { model.refreshOutputs() }.disabled(!model.connected).accessibilityIdentifier("mapping.refresh")
            if let pairingError { Text(pairingError).foregroundStyle(.red) }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .onAppear { if model.connected { model.refreshOutputs() } }
        .onChange(of: model.connected) { _, connected in if connected { model.refreshOutputs() } }
        .sheet(isPresented: $pairing) {
            NavigationStack {
                QRScanner(onCode: { code in
                    pairing = false; pairingError = nil; model.pair(code)
                }, onFailure: { pairingError = $0; pairing = false })
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan Mac QR")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pairing = false } } }
            }
        }
    }
}

private struct NewTagSheet: View {
    @EnvironmentObject var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let kind: NewTagKind
    @State private var name = ""
    @State private var outputID: String?
    @State private var channel: Int?
    @State private var parentID: UUID?
    @State private var location: Point3?
    @State private var facing = 0.0
    @State private var method: PlacementMethod?
    @State private var assignmentError: String?
    private var parent: PhysicalSpeaker? {
        mappedParents(room: model.room, outputs: model.assignableOutputs).first { $0.id == parentID }
    }
    private var connection: ChannelConnection? {
        availableConnection(outputID: outputID, channel: channel, outputs: model.assignableOutputs, room: model.room)
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && location != nil &&
        (kind != .speaker || connection != nil) && (kind != .subwoofer || parent != nil) && !model.sessionInProgress
    }
    var body: some View {
        NavigationStack {
            Form {
                if kind == .speaker {
                    Section("Actual playback assignment") {
                        OutputChannelPicker(outputID: $outputID, channel: $channel)
                    }
                } else if kind == .subwoofer {
                    Section("Hardware-linked stereo system") { LinkedParentPicker(parentID: $parentID) }
                }
                if kind != .listener { MappingConnectionControls() }
                TextField("Name", text: $name)
                if let assignmentError { Text(assignmentError).foregroundStyle(.red) }
                Section("Choose location") {
                    if kind == .listener {
                        Button("Use tracked microphone…") { method = .microphone }
                            .disabled(!model.scanned || !model.supported)
                    } else {
                        Button("Aim camera at \(kind.title.lowercased())…") { method = .camera }
                            .disabled(!model.scanned || !model.supported)
                    }
                    Button("Place on room map…") { method = .map }
                    if let location {
                        Text("Chosen: X \(location.x, specifier: "%.2f"), world Y \(location.y, specifier: "%.2f"), Z \(location.z, specifier: "%.2f") m")
                            .font(.caption.monospacedDigit())
                        Text("Nothing is added until you tap Add.").font(.caption)
                    } else {
                        Text("Choose a real location before adding this tag. Camera placement requires an aligned scan; map placement requires an explicit point and height.").font(.caption)
                    }
                }
            }
            .disabled(model.sessionInProgress)
            .navigationTitle("Add \(kind.title.lowercased())")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("placement.cancel") }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: save).disabled(!canSave).accessibilityIdentifier("placement.save") }
            }
            .sheet(item: $method) { method in
                PlacementSheet(method: method, title: name.isEmpty ? kind.title : name, initial: location) { point, direction in
                    guard !model.sessionInProgress else { return }
                    location = point
                    if let direction { facing = direction }
                    self.method = nil
                } onCancel: { self.method = nil }
            }
        }
    }
    private func save() {
        guard canSave, let location else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch kind {
            case .listener:
                let listener = ListeningPosition(id: UUID(), name: trimmed, position: location, facingRadians: facing)
                model.room.positions.append(listener); model.selectedPosition = listener.id
            case .speaker:
                guard let connection else { return }
                try model.room.addConnectedSpeaker(name: trimmed, position: location, facingRadians: facing, connection: connection, outputs: model.assignableOutputs)
            case .subwoofer:
                guard let parent else { return }
                try model.room.addLinkedSubwoofer(name: trimmed, position: location, facingRadians: facing, parentSpeakerID: parent.id, outputs: model.assignableOutputs)
            }
            model.saveRoom(); dismiss()
        } catch { assignmentError = error.localizedDescription }
    }
}

private struct PlacementSheet: View {
    @EnvironmentObject var model: PhoneModel
    let method: PlacementMethod
    let title: String
    let initial: Point3?
    let onPlace: (Point3, Double?) -> Void
    let onCancel: () -> Void
    var body: some View {
        Group {
            switch method {
            case .camera:
                SpatialPlacementView(session: model.trackingSession, title: title, tags: model.room.speakers,
                    isRoomAligned: { model.roomTrackingReady && !model.sessionInProgress },
                    onRelocalize: { if !model.sessionInProgress { model.relocalizeRoom() } },
                    onPlace: { point, direction in if !model.sessionInProgress { onPlace(point, direction) } },
                    onCancel: onCancel)
                    .onAppear { model.prepareSpatialPlacement() }
            case .map:
                MapPlacementSheet(room: model.room, title: title, initial: initial,
                    onPlace: { if !model.sessionInProgress { onPlace($0, nil) } }, onCancel: onCancel)
            case .microphone:
                MicrophonePlacementSheet(title: title,
                    onPlace: { point, facing in if !model.sessionInProgress { onPlace(point, facing) } }, onCancel: onCancel)
                    .onAppear { model.prepareSpatialPlacement() }
            }
        }
        .disabled(model.sessionInProgress)
    }
}

private struct MicrophonePlacementSheet: View {
    @EnvironmentObject var model: PhoneModel
    let title: String
    let onPlace: (Point3, Double) -> Void
    let onCancel: () -> Void
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TrackingPreview(session: model.trackingSession).frame(maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Hold the microphone at ear height with the screen toward you. Aim the rear camera where you look: that becomes Forward.")
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    if model.roomTrackingReady, let pose = model.trackedListenerPose {
                        Text("Facing \(pose.facingRadians * 180 / .pi, specifier: "%.0f")° · turns with your phone")
                            .font(.caption.monospacedDigit())
                    } else { Text("Look around until aligned, then aim the camera ahead—not at the floor or ceiling.") }
                    Button("Save Listener Position & Direction") {
                        guard !model.sessionInProgress,
                              model.roomTrackingReady, let pose = model.trackedListenerPose else { return }
                        onPlace(pose.position, pose.facingRadians)
                    }.buttonStyle(.borderedProminent)
                        .disabled(!model.roomTrackingReady || model.trackedListenerPose == nil || model.sessionInProgress)
                }
                Button("Relocalize room") { model.relocalizeRoom() }
                Spacer()
            }.padding()
                .navigationTitle(title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel).accessibilityIdentifier("placement.cancel") } }
        }
    }
}

struct SpeakerEditor: View {
    @EnvironmentObject var model: PhoneModel
    @Binding var speaker: PhysicalSpeaker
    @State private var method: PlacementMethod?
    @State private var outputID: String?
    @State private var channel: Int?
    @State private var parentID: UUID?
    @State private var assignmentError: String?
    @State private var loadedAssignment = false
    private var connection: ChannelConnection? {
        availableConnection(outputID: outputID, channel: channel, outputs: model.assignableOutputs, room: model.room, excluding: speaker.id)
    }
    private var parent: PhysicalSpeaker? {
        mappedParents(room: model.room, outputs: model.assignableOutputs, excluding: speaker.id).first { $0.id == parentID }
    }
    var body: some View {
        Form {
            Section("Actual playback assignment") {
                Text(model.room.assignmentLabel(for: speaker, outputs: model.outputs))
                if speaker.linkedSubwoofer {
                    LinkedParentPicker(parentID: $parentID, excludingSpeakerID: speaker.id)
                    Button("Update linked parent", action: updateAssignment).disabled(parent == nil)
                } else {
                    OutputChannelPicker(outputID: $outputID, channel: $channel, excludingSpeakerID: speaker.id)
                    Button("Save output assignment", action: updateAssignment).disabled(connection == nil || connection == speaker.connection)
                }
                Text("Choose a route, then save it. Name, position and speaker identity stay unchanged.").font(.caption)
                if let assignmentError { Text(assignmentError).foregroundStyle(.red) }
            }
            MappingConnectionControls()
            TextField("Name", text: $speaker.name)
            Section("Reposition") {
                RoomMap(room: model.room, selectedTag: speaker.id, onMove: { point in
                    guard !model.sessionInProgress else { return }
                    speaker.position.x = point.x; speaker.position.z = point.z; model.saveRoom()
                }).frame(height: 230)
                Text("Tap or drag this selected tag. Its height, facing, group and output connection stay unchanged.").font(.caption)
                Button("Reposition with camera…") { method = .camera }.disabled(!model.scanned || !model.supported)
                Button("Place on map with height…") { method = .map }
            }
            DisclosureGroup("Advanced coordinates & facing") {
                CoordinateFields(position: $speaker.position, facing: $speaker.facingRadians, floorY: model.room.referenceFloorY)
            }
            Section("Timing group") {
                Text(speaker.linkedSubwoofer
                     ? "Hardware-linked subs inherit their parent's stereo timing group. Change the parent above to relink."
                     : "Adding a linked subwoofer joins the speakers on its receiver into one hardware timing group.").font(.caption)
            }
        }
        .navigationTitle("Speaker")
        .disabled(model.sessionInProgress)
        .onAppear {
            guard !loadedAssignment else { return }
            outputID = speaker.connection?.outputID; channel = speaker.connection?.channel
            loadedAssignment = true
        }
        .sheet(item: $method) { method in
            PlacementSheet(method: method, title: speaker.name, initial: speaker.position) { point, _ in
                guard !model.sessionInProgress else { return }
                speaker.position = point; model.saveRoom(); self.method = nil
            } onCancel: { self.method = nil }
        }
        .onDisappear { if !model.sessionInProgress { model.saveRoom() } }
    }
    private func updateAssignment() {
        guard !model.sessionInProgress else { return }
        do {
            if speaker.linkedSubwoofer {
                guard let parent else { return }
                try model.room.linkSubwoofer(speakerID: speaker.id, parentSpeakerID: parent.id, outputs: model.assignableOutputs)
            } else {
                guard let connection else { return }
                try model.room.setSpeakerConnection(speakerID: speaker.id, connection: connection, outputs: model.assignableOutputs)
            }
            assignmentError = nil
            model.saveRoom()
        } catch { assignmentError = error.localizedDescription }
    }
}

struct CoordinateFields: View {
    @Binding var position: Point3
    @Binding var facing: Double
    let floorY: Double?
    var body: some View {
        LabeledContent("X") { TextField("X meters", value: $position.x, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
        LabeledContent(floorY == nil ? "World Y" : "Height above floor") {
            TextField("Height meters", value: Binding(get: { position.y - (floorY ?? 0) }, set: { position.y = $0 + (floorY ?? 0) }), format: .number)
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
        }
        LabeledContent("Z") { TextField("Z meters", value: $position.z, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
        LabeledContent("Facing degrees") { TextField("Facing degrees", value: Binding(get: { facing * 180 / .pi }, set: { facing = $0 * .pi / 180 }), format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
        Text(floorY == nil
             ? "Meters in scan coordinates: X right, Y up, Z backward. No floor reference was scanned; world Y is not height above floor. Facing 0° points toward −Z."
             : "X/Z are scan coordinates in meters. Height is above the lowest scanned floor; stored world Y = floor Y + height. Facing 0° points toward −Z.").font(.caption)
    }
}

private struct MapPlacementSheet: View {
    @EnvironmentObject var model: PhoneModel
    let room: RoomModel
    let title: String
    let initial: Point3?
    let onPlace: (Point3) -> Void
    let onCancel: () -> Void
    @State private var location: Point3?
    @State private var height = ""
    private var heightValue: Double? {
        guard let value = Double(height.replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
        return value
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Tap a location") {
                    RoomMap(room: room, candidate: location, onChoose: { location = $0 }).frame(height: 300)
                    MapLegend()
                    Text("Tap or drag to choose X/Z. No location is saved until you confirm.").font(.caption)
                }
                Section("Height in meters") {
                    TextField(room.referenceFloorY == nil ? "World Y (required)" : "Height above floor (required)", text: $height).keyboardType(.numbersAndPunctuation)
                    if let floor = room.referenceFloorY {
                        Text("Height above the lowest scanned floor (world Y \(floor, specifier: "%.2f") m). Stored world Y = floor + height.").font(.caption)
                    } else {
                        Text("No floor reference was scanned. Enter world Y in scan coordinates, not an assumed height above the floor.").font(.caption)
                    }
                }
            }.disabled(model.sessionInProgress)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel).accessibilityIdentifier("placement.cancel") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Confirm") {
                            guard !model.sessionInProgress, var location, let heightValue else { return }
                            location.y = heightValue + (room.referenceFloorY ?? 0); onPlace(location)
                        }.disabled(location == nil || heightValue == nil || model.sessionInProgress)
                    }
                }
                .onAppear {
                    if let initial {
                        location = initial
                        height = String(initial.y - (room.referenceFloorY ?? 0))
                    }
                }
        }
    }
}

private struct RoomMapTag: Identifiable {
    let id: UUID
    let name: String
    let number: Int
    let kind: String
    let point: Point3
    let facing: Double
    let color: Color
    var label: String { "\(number). \(name) — \(kind)" }
}

private extension RoomModel {
    var referenceFloorY: Double? {
        geometry?.surfaces.filter { $0.category == "floor" && $0.transform.count == 16 }
            .map { $0.transform[13] }.filter(\.isFinite).min()
    }
    var mapWallPoints: [Point3] {
        (geometry?.surfaces ?? []).filter { $0.category == "wall" && $0.transform.count == 16 }.flatMap { wall in
            let m = wall.transform, half = wall.dimensions.x / 2
            return [Point3(x: m[12] - m[0] * half, y: m[13], z: m[14] - m[2] * half),
                    Point3(x: m[12] + m[0] * half, y: m[13], z: m[14] + m[2] * half)]
        }
    }
    var mapTags: [RoomMapTag] {
        speakers.enumerated().map { index, speaker in
            RoomMapTag(id: speaker.id, name: speaker.name, number: index + 1,
                       kind: speaker.linkedSubwoofer ? "Linked sub" : "Speaker", point: speaker.position,
                       facing: speaker.facingRadians, color: speaker.linkedSubwoofer ? .orange : .blue)
        } + positions.enumerated().map { index, listener in
            RoomMapTag(id: listener.id, name: listener.name, number: speakers.count + index + 1,
                       kind: "Listener", point: listener.position, facing: listener.facingRadians, color: .green)
        }
    }
}

struct RoomMapProjection {
    let centerX: Double
    let centerZ: Double
    let scale: Double
    let size: CGSize
    init(points: [Point3], size: CGSize) {
        let finite = points.filter { $0.x.isFinite && $0.z.isFinite }
        let minX = finite.map(\.x).min() ?? -1, maxX = finite.map(\.x).max() ?? 1
        let minZ = finite.map(\.z).min() ?? -1, maxZ = finite.map(\.z).max() ?? 1
        centerX = (minX + maxX) / 2; centerZ = (minZ + maxZ) / 2
        scale = min(max(1, Double(size.width) - 48) / max(maxX - minX + 1, 2),
                    max(1, Double(size.height) - 48) / max(maxZ - minZ + 1, 2))
        self.size = size
    }
    func screen(_ point: Point3) -> CGPoint {
        CGPoint(x: Double(size.width) / 2 + (point.x - centerX) * scale,
                y: Double(size.height) / 2 + (point.z - centerZ) * scale)
    }
    func world(_ point: CGPoint) -> Point3 {
        Point3(x: centerX + (Double(point.x) - Double(size.width) / 2) / scale, y: 0,
               z: centerZ + (Double(point.y) - Double(size.height) / 2) / scale)
    }
}

struct RoomMap: View {
    let room: RoomModel
    var selectedTag: UUID? = nil
    var candidate: Point3? = nil
    var onMove: ((Point3) -> Void)? = nil
    var onChoose: ((Point3) -> Void)? = nil
    @State private var dragProjection: RoomMapProjection?
    @State private var dragPoint: Point3?
    private var selected: RoomMapTag? { room.mapTags.first { $0.id == selectedTag } }
    var body: some View {
        GeometryReader { geometry in
            let tags = room.mapTags
            let walls = room.mapWallPoints
            let projection = dragProjection ?? RoomMapProjection(points: walls + tags.map(\.point), size: geometry.size)
            Canvas { context, size in
                for index in stride(from: 0, to: walls.count, by: 2) {
                    var line = Path(); line.move(to: projection.screen(walls[index])); line.addLine(to: projection.screen(walls[index + 1]))
                    context.stroke(line, with: .color(.secondary), lineWidth: 3)
                }
                for speaker in room.speakers where speaker.linkedSubwoofer {
                    if let parent = room.speakers.first(where: { !$0.linkedSubwoofer && $0.timingGroupID == speaker.timingGroupID }) {
                        var link = Path()
                        link.move(to: projection.screen(speaker.id == selectedTag ? dragPoint ?? speaker.position : speaker.position))
                        link.addLine(to: projection.screen(parent.id == selectedTag ? dragPoint ?? parent.position : parent.position))
                        context.stroke(link, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                // Draw the selected marker last so legacy colocated tags stay individually recoverable.
                for tag in tags.filter({ $0.id != selectedTag }) + tags.filter({ $0.id == selectedTag }) {
                    let isSelected = tag.id == selectedTag
                    let point = projection.screen(isSelected ? dragPoint ?? tag.point : tag.point)
                    let rect = CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
                    let shape = tag.kind == "Linked sub" ? Path(rect) : Path(ellipseIn: rect)
                    context.fill(shape, with: .color(tag.color))
                    if isSelected {
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(.primary), lineWidth: 3)
                    }
                    var arrow = Path(); arrow.move(to: point)
                    arrow.addLine(to: CGPoint(x: point.x + sin(tag.facing) * 28, y: point.y - cos(tag.facing) * 28))
                    context.stroke(arrow, with: .color(tag.color), lineWidth: 2)
                    context.draw(Text("\(tag.number)").font(.caption2.bold()).foregroundColor(.white), at: point)
                }
                if let point = onChoose == nil ? candidate : dragPoint ?? candidate {
                    let center = projection.screen(point)
                    let rect = CGRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26)
                    context.stroke(Path(ellipseIn: rect), with: .color(.primary), lineWidth: 3)
                    var cross = Path()
                    cross.move(to: CGPoint(x: center.x - 18, y: center.y)); cross.addLine(to: CGPoint(x: center.x + 18, y: center.y))
                    cross.move(to: CGPoint(x: center.x, y: center.y - 18)); cross.addLine(to: CGPoint(x: center.x, y: center.y + 18))
                    context.stroke(cross, with: .color(.primary), lineWidth: 2)
                }
            }
            .background(.quaternary.opacity(0.3))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard onChoose != nil || (selected != nil && onMove != nil) else { return }
                    if dragProjection == nil { dragProjection = projection }
                    dragPoint = (dragProjection ?? projection).world(clamped(value.location, size: geometry.size))
                }
                .onEnded { value in
                    guard let frozen = dragProjection else { return }
                    let point = frozen.world(clamped(value.location, size: geometry.size))
                    if let onChoose { onChoose(point) } else { onMove?(point) }
                    dragPoint = nil; dragProjection = nil
                })
            .overlay(alignment: .topLeading) {
                Text(selected.map { "Selected: \($0.label)" } ?? (onChoose == nil ? "Choose a tag above" : "Tap to choose location"))
                    .font(.caption).padding(6).background(.regularMaterial).allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(selected.map { "Room map. Selected \($0.label)" } ?? "Top-down room map")
            .accessibilityHint("Use the named tag selector to distinguish overlapping tags. Advanced coordinate fields provide a nonvisual alternative.")
            .accessibilityIdentifier("room.map")
        }
    }
    private func clamped(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x), size.width), y: min(max(0, point.y), size.height))
    }
}

private struct MapLegend: View {
    var body: some View {
        Text("Blue circles: speakers · Orange squares: linked subs · Green circles: listeners. Numbers match the tag selector; arrows show facing.").font(.caption)
    }
}

struct ListenerEditor: View {
    @EnvironmentObject var model: PhoneModel
    @Binding var position: ListeningPosition
    @State private var method: PlacementMethod?
    var body: some View {
        Form {
            TextField("Name", text: $position.name)
            Section("Reposition") {
                RoomMap(room: model.room, selectedTag: position.id, onMove: { point in
                    guard !model.sessionInProgress else { return }
                    position.position.x = point.x; position.position.z = point.z; model.saveRoom()
                }).frame(height: 230)
                Text("Tap or drag to move X/Z without changing height, facing, target preference or manual mix.").font(.caption)
                Button("Set Position & Direction with Phone…") { method = .microphone }.disabled(!model.scanned || !model.supported)
                Button("Place on map with height…") { method = .map }
            }
            DisclosureGroup("Advanced coordinates & facing") {
                CoordinateFields(position: $position.position, facing: $position.facingRadians, floorY: model.room.referenceFloorY)
            }
            Section("Target preference") {
                Text("Bass: \(position.target.bassDB, specifier: "%.1f") dB"); Slider(value: $position.target.bassDB, in: -6...3, step: 0.5)
                Text("Treble: \(position.target.trebleDB, specifier: "%.1f") dB"); Slider(value: $position.target.trebleDB, in: -6...3, step: 0.5)
                Text("Preference shapes the target; correction remains constrained by measured response and boost limits.").font(.caption)
            }
            Section("Listener-facing mix") {
                Button("Use geometric suggestions as editable overrides") { position.mixOverrides = model.room.suggestedMixes(for: position) }
                Button("Clear manual overrides") { position.mixOverrides = [] }
                ForEach(position.mixOverrides.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        let mix = position.mixOverrides[index]
                        Text("\(model.outputs.first(where: { $0.id == mix.connection.outputID })?.name ?? mix.connection.outputID), channel \(mix.connection.channel + 1)")
                        Text("Left contribution \(mix.left, specifier: "%.2f")"); Slider(value: $position.mixOverrides[index].left, in: 0...1)
                        Text("Right contribution \(mix.right, specifier: "%.2f")"); Slider(value: $position.mixOverrides[index].right, in: 0...1)
                        Text("Trim \(mix.gainDB, specifier: "%.1f") dB"); Slider(value: $position.mixOverrides[index].gainDB, in: -18...0, step: 0.5)
                    }
                }
                Text("Geometry suggests stereo contributions only. Timing and phase alignment require microphone measurement.").font(.caption)
            }
        }
        .navigationTitle("Listener")
        .disabled(model.sessionInProgress)
        .sheet(item: $method) { method in
            PlacementSheet(method: method, title: position.name, initial: position.position) { point, direction in
                guard !model.sessionInProgress else { return }
                position.position = point
                if let direction { position.facingRadians = direction }
                model.saveRoom(); self.method = nil
            } onCancel: { self.method = nil }
        }
        .onDisappear { if !model.sessionInProgress { model.saveRoom() } }
    }
}

struct ResponseChart: View {
    let profile: CalibrationProfile
    private struct Sample: Identifiable { let id: String; let series: String; let frequency: Double; let db: Double }
    private var samples: [Sample] {
        [("Measured before", profile.measuredBefore), ("Measured after", profile.measuredAfter), ("Predicted only", profile.predicted)].flatMap { name, curve in
            guard let curve else { return [Sample]() }
            return zip(curve.frequencies, curve.decibels).enumerated().compactMap { index, pair in
                guard pair.0 > 0, pair.0.isFinite, pair.1.isFinite else { return nil }
                return Sample(id: "\(name)-\(index)", series: name, frequency: pair.0, db: pair.1)
            }
        }
    }
    var body: some View {
        if samples.isEmpty { Text("No response curves are stored in this profile.").font(.caption) }
        else {
            Chart(samples) { sample in
                LineMark(x: .value("Frequency Hz", sample.frequency), y: .value("Response dB", sample.db))
                    .foregroundStyle(by: .value("Measurement", sample.series))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: sample.series == "Predicted only" ? [4, 3] : []))
            }.chartXScale(type: .log).chartXAxisLabel("Frequency (Hz)").chartYAxisLabel("Response (dB)")
                .accessibilityLabel("Response graph distinguishes measured before, measured after, and predicted response. A predicted curve is not measured verification.")
        }
    }
}
