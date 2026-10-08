// SPDX-License-Identifier: MIT
import Foundation

public enum OutputKind: String, Codable, Sendable { case wired, airplay }
public struct Point3: Codable, Sendable, Hashable {
    public var x: Double; public var y: Double; public var z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}
/// AR camera +Z points toward the screen; the rear camera looks along -Z.
public enum ListenerOrientation {
    public static func facing(cameraBackward: Point3) -> Double? {
        guard cameraBackward.x.isFinite, cameraBackward.y.isFinite, cameraBackward.z.isFinite,
              hypot(cameraBackward.x, cameraBackward.z) > 0.1 else { return nil }
        return atan2(-cameraBackward.x, cameraBackward.z)
    }
}
/// Handheld capture limits; small pose changes are expected, not measurement failures.
public enum HandheldCapturePolicy {
    public static let maximumTranslationMeters = 0.15
    public static let maximumRotationRadians = Double.pi / 6
    public static let matchingPositionToleranceMeters = 0.10
    public static func acceptsMotion(translation: Double, rotation: Double) -> Bool {
        translation.isFinite && rotation.isFinite &&
        (0...maximumTranslationMeters).contains(translation) &&
        (0...maximumRotationRadians).contains(rotation)
    }
}
/// A session-local grid anchored at the microphone, not an approximate room-map tag.
public struct MeasurementGrid: Sendable {
    public let center: Point3
    private let cosine: Double, sine: Double
    private static let offsets: [(Double, Double)] = [(0, 0), (-0.2, 0), (0.2, 0), (0, -0.2), (0, 0.2), (-0.14, -0.14), (0.14, -0.14), (-0.14, 0.14), (0.14, 0.14)]
    public init(center: Point3, facingRadians: Double) {
        self.center = center; cosine = cos(facingRadians); sine = sin(facingRadians)
    }
    /// Center-relative meters: positive X is right, positive Y is up, negative Z is forward.
    public static func localOffset(pointIndex: Int) -> Point3? {
        guard offsets.indices.contains(pointIndex) else { return nil }
        let offset = offsets[pointIndex]
        return Point3(x: offset.0, y: 0, z: offset.1)
    }
    public func worldPosition(localPosition: Point3) -> Point3 {
        Point3(x: center.x + localPosition.x * cosine - localPosition.z * sine,
               y: center.y + localPosition.y,
               z: center.z + localPosition.x * sine + localPosition.z * cosine)
    }
    public func localPosition(worldPosition: Point3) -> Point3 {
        let x = worldPosition.x - center.x, z = worldPosition.z - center.z
        return Point3(x: x * cosine + z * sine, y: worldPosition.y - center.y,
                      z: -x * sine + z * cosine)
    }
    public func target(pointIndex: Int) -> Point3? {
        Self.localOffset(pointIndex: pointIndex).map { worldPosition(localPosition: $0) }
    }
}
public struct AudioOutput: Codable, Sendable, Identifiable {
    public var id: String; public var name: String; public var kind: OutputKind
    public var channels: Int; public var sampleRate: Double; public var available: Bool
    public init(id: String, name: String, kind: OutputKind, channels: Int, sampleRate: Double, available: Bool) {
        self.id = id; self.name = name; self.kind = kind; self.channels = channels; self.sampleRate = sampleRate; self.available = available
    }
}
public struct ChannelConnection: Codable, Sendable, Hashable {
    public var outputID: String; public var channel: Int
    public init(outputID: String, channel: Int) { self.outputID = outputID; self.channel = channel }
}
public struct PhysicalSpeaker: Codable, Sendable, Identifiable {
    public var id: UUID; public var name: String; public var position: Point3; public var facingRadians: Double
    public var connection: ChannelConnection?; public var linkedSubwoofer: Bool; public var timingGroupID: String
    public init(id: UUID, name: String, position: Point3, facingRadians: Double, connection: ChannelConnection?, linkedSubwoofer: Bool, timingGroupID: String) {
        self.id = id; self.name = name; self.position = position; self.facingRadians = facingRadians
        self.connection = connection; self.linkedSubwoofer = linkedSubwoofer; self.timingGroupID = timingGroupID
    }
}
public struct ChannelMix: Codable, Sendable {
    public var connection: ChannelConnection; public var left: Double; public var right: Double
    public var gainDB: Double; public var delaySeconds: Double; public var fir: [Float]
    public init(connection: ChannelConnection, left: Double, right: Double, gainDB: Double, delaySeconds: Double, fir: [Float]) {
        self.connection = connection; self.left = left; self.right = right; self.gainDB = gainDB; self.delaySeconds = delaySeconds; self.fir = fir
    }
}
public struct TargetPreference: Codable, Sendable {
    public var bassDB: Double; public var trebleDB: Double
    public init(bassDB: Double = 0, trebleDB: Double = 0) { self.bassDB = bassDB; self.trebleDB = trebleDB }
}
public struct ResponseCurve: Codable, Sendable {
    public var frequencies: [Double]; public var decibels: [Double]
    public init(frequencies: [Double], decibels: [Double]) { self.frequencies = frequencies; self.decibels = decibels }
}
public struct ListeningPosition: Codable, Sendable, Identifiable {
    public var id: UUID; public var name: String; public var position: Point3; public var facingRadians: Double
    public var target: TargetPreference; public var mixOverrides: [ChannelMix]
    public init(id: UUID, name: String, position: Point3, facingRadians: Double, target: TargetPreference = TargetPreference(), mixOverrides: [ChannelMix] = []) { self.id = id; self.name = name; self.position = position; self.facingRadians = facingRadians; self.target = target; self.mixOverrides = mixOverrides }
}
public struct ScannedSurface: Codable, Sendable, Identifiable {
    public var id: UUID; public var category: String; public var dimensions: Point3; public var transform: [Double]
    /// Column-major 4x4 RoomPlan transform in the common scan coordinate system.
    public init(id: UUID, category: String, dimensions: Point3, transform: [Double]) { self.id = id; self.category = category; self.dimensions = dimensions; self.transform = transform }
}
public struct ScannedGeometry: Codable, Sendable {
    public var surfaces: [ScannedSurface]; public var capturedAt: Date; public var roomPlanArchive: Data
    public init(surfaces: [ScannedSurface], capturedAt: Date, roomPlanArchive: Data) { self.surfaces = surfaces; self.capturedAt = capturedAt; self.roomPlanArchive = roomPlanArchive }
}
public struct RoomModel: Codable, Sendable, Identifiable {
    public var id: UUID; public var name: String; public var speakers: [PhysicalSpeaker]; public var positions: [ListeningPosition]
    public var geometry: ScannedGeometry?
    public init(id: UUID, name: String, speakers: [PhysicalSpeaker], positions: [ListeningPosition], geometry: ScannedGeometry? = nil) { self.id = id; self.name = name; self.speakers = speakers; self.positions = positions; self.geometry = geometry }

    @discardableResult
    public mutating func addConnectedSpeaker(name: String, position: Point3, facingRadians: Double, connection: ChannelConnection, outputs: [AudioOutput]) throws -> UUID {
        try validatePlacement(name: name, position: position, facingRadians: facingRadians)
        _ = try validateConnection(connection, outputs: outputs)
        let linkedParent = linkedParentIndex(on: connection.outputID)
        let plan = try linkedParent.map { try linkedGroupPlan(parentIndex: $0, outputs: outputs) }
        let id = UUID()
        if let plan { applyGroup(plan) }
        speakers.append(PhysicalSpeaker(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), position: position, facingRadians: facingRadians, connection: connection, linkedSubwoofer: false, timingGroupID: plan?.id ?? UUID().uuidString))
        return id
    }

    public mutating func setSpeakerConnection(speakerID: UUID, connection: ChannelConnection, outputs: [AudioOutput]) throws {
        guard let index = speakers.firstIndex(where: { $0.id == speakerID }) else { throw AssignmentError("This speaker no longer exists.") }
        let speaker = speakers[index]
        try validatePlacement(name: speaker.name, position: speaker.position, facingRadians: speaker.facingRadians)
        let output = try validateConnection(connection, excluding: speakerID, outputs: outputs)
        let hasLinkedChildren = !speaker.linkedSubwoofer && groupHasSubwoofer(speaker.timingGroupID, excluding: speakerID)
        if hasLinkedChildren {
            guard output.channels >= 2 else { throw AssignmentError("A hardware-linked subwoofer requires a stereo output. Unlink the subwoofer before choosing a mono output.") }
            guard !speakers.contains(where: {
                $0.id != speakerID && !$0.linkedSubwoofer && $0.timingGroupID == speaker.timingGroupID &&
                $0.connection.map { $0.outputID != connection.outputID } == true
            }) else { throw AssignmentError("This would split a hardware-linked stereo system across outputs. Unlink its subwoofers before remapping the speakers, then link them again.") }
        }
        let linkedParent = linkedParentIndex(on: connection.outputID, excluding: speakerID)
        let destinationParent = linkedParent ?? (hasLinkedChildren ? speakers.firstIndex { $0.id != speakerID && !$0.linkedSubwoofer && $0.connection?.outputID == connection.outputID } : nil)
        var plan = try destinationParent.map { try linkedGroupPlan(parentIndex: $0, outputs: outputs) }
        if hasLinkedChildren && linkedParent == nil { plan?.id = speaker.timingGroupID }
        let groupID: String
        if let plan { groupID = plan.id }
        else if hasLinkedChildren || (!speaker.linkedSubwoofer && speaker.connection?.outputID == connection.outputID && !speaker.timingGroupID.isEmpty) { groupID = speaker.timingGroupID }
        else { groupID = UUID().uuidString }
        if let plan { applyGroup(plan) }
        if hasLinkedChildren && speaker.timingGroupID != groupID {
            for member in speakers.indices where speakers[member].timingGroupID == speaker.timingGroupID {
                speakers[member].timingGroupID = groupID
            }
        }
        speakers[index].connection = connection
        speakers[index].linkedSubwoofer = false
        speakers[index].timingGroupID = groupID
    }

    @discardableResult
    public mutating func addLinkedSubwoofer(name: String, position: Point3, facingRadians: Double, parentSpeakerID: UUID, outputs: [AudioOutput]) throws -> UUID {
        try validatePlacement(name: name, position: position, facingRadians: facingRadians)
        guard let parent = speakers.firstIndex(where: { $0.id == parentSpeakerID }) else { throw AssignmentError("Choose an existing mapped stereo speaker as the parent.") }
        let plan = try linkedGroupPlan(parentIndex: parent, outputs: outputs)
        let id = UUID()
        applyGroup(plan)
        speakers.append(PhysicalSpeaker(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), position: position, facingRadians: facingRadians, connection: nil, linkedSubwoofer: true, timingGroupID: plan.id))
        return id
    }

    public mutating func linkSubwoofer(speakerID: UUID, parentSpeakerID: UUID, outputs: [AudioOutput]) throws {
        guard speakerID != parentSpeakerID,
              let index = speakers.firstIndex(where: { $0.id == speakerID }),
              let parent = speakers.firstIndex(where: { $0.id == parentSpeakerID }) else { throw AssignmentError("Choose a different existing mapped stereo speaker as the parent.") }
        let speaker = speakers[index]
        try validatePlacement(name: speaker.name, position: speaker.position, facingRadians: speaker.facingRadians)
        let plan = try linkedGroupPlan(parentIndex: parent, outputs: outputs)
        if !speaker.linkedSubwoofer && groupHasSubwoofer(speaker.timingGroupID, excluding: speakerID) {
            guard plan.indices.contains(index) || speakers.contains(where: {
                $0.id != speakerID && !$0.linkedSubwoofer && $0.connection != nil && $0.timingGroupID == speaker.timingGroupID
            }) else { throw AssignmentError("This speaker is the only output for linked subwoofers. Relink those subwoofers before converting it to a visual subwoofer.") }
        }
        applyGroup(plan)
        speakers[index].connection = nil
        speakers[index].linkedSubwoofer = true
        speakers[index].timingGroupID = plan.id
    }

    public func channelIsAssigned(_ connection: ChannelConnection, excluding speakerID: UUID? = nil) -> Bool {
        speakers.contains { $0.id != speakerID && !$0.linkedSubwoofer && $0.connection == connection }
    }

    public func assignmentLabel(for speaker: PhysicalSpeaker, outputs: [AudioOutput]) -> String {
        if speaker.linkedSubwoofer {
            let outputIDs = Set(speakers.compactMap { member -> String? in
                guard !speaker.timingGroupID.isEmpty, member.timingGroupID == speaker.timingGroupID, !member.linkedSubwoofer else { return nil }
                return member.connection?.outputID
            })
            guard outputIDs.count == 1, let outputID = outputIDs.first else { return "Output not assigned · Hardware-controlled sub" }
            return "\(outputLabel(outputID, outputs: outputs)) · Hardware-controlled sub"
        }
        guard let connection = speaker.connection else { return "Output not assigned" }
        let output = outputs.first { $0.id == connection.outputID }
        let channel: String
        if connection.channel == 0 { channel = output?.channels == 1 ? "Channel 1 (Mono)" : "Channel 1 (Left)" }
        else if connection.channel == 1 { channel = "Channel 2 (Right)" }
        else { channel = "Unsupported channel" }
        return "\(outputLabel(connection.outputID, outputs: outputs)) · \(channel)"
    }

    private struct AssignmentError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private struct LinkedGroupPlan { var id: String; var indices: [Int] }

    private func validatePlacement(name: String, position: Point3, facingRadians: Double) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssignmentError("Enter a speaker name.") }
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite, facingRadians.isFinite else { throw AssignmentError("Choose a finite location and facing direction in the scanned room.") }
    }

    private func validateConnection(_ connection: ChannelConnection, excluding speakerID: UUID? = nil, outputs: [AudioOutput]) throws -> AudioOutput {
        guard !connection.outputID.isEmpty, let output = outputs.first(where: { $0.id == connection.outputID }) else { throw AssignmentError("This output is not in the Mac's discovery results. Refresh outputs and choose an actual receiver.") }
        guard output.available else { throw AssignmentError("This output is unavailable. Connect the receiver and refresh outputs before assigning it.") }
        guard output.channels > 0, connection.channel >= 0, connection.channel < min(output.channels, 2) else { throw AssignmentError("Choose a supported output channel: channel 1 for mono, or channel 1 (Left) / 2 (Right) for stereo.") }
        guard !channelIsAssigned(connection, excluding: speakerID) else { throw AssignmentError("This output channel is already assigned to another speaker. Choose the other channel or reassign that speaker first.") }
        return output
    }

    private func groupHasSubwoofer(_ groupID: String, excluding speakerID: UUID? = nil) -> Bool {
        !groupID.isEmpty && speakers.contains { $0.id != speakerID && $0.linkedSubwoofer && $0.timingGroupID == groupID }
    }

    private func linkedParentIndex(on outputID: String, excluding speakerID: UUID? = nil) -> Int? {
        speakers.firstIndex { $0.id != speakerID && !$0.linkedSubwoofer && $0.connection?.outputID == outputID && groupHasSubwoofer($0.timingGroupID) }
    }

    private func linkedGroupPlan(parentIndex: Int, outputs: [AudioOutput]) throws -> LinkedGroupPlan {
        let parent = speakers[parentIndex]
        guard !parent.linkedSubwoofer, let connection = parent.connection else { throw AssignmentError("Map the parent speaker to an actual stereo output before linking a subwoofer.") }
        let output = try validateConnection(connection, excluding: parent.id, outputs: outputs)
        guard output.channels >= 2 else { throw AssignmentError("A hardware-linked subwoofer requires a stereo output, not a mono output.") }
        let members = speakers.indices.filter { !speakers[$0].linkedSubwoofer && speakers[$0].connection?.outputID == connection.outputID }
        let groups = Set(members.map { speakers[$0].timingGroupID }.filter { !$0.isEmpty })
        guard !speakers.contains(where: {
            !$0.linkedSubwoofer && groups.contains($0.timingGroupID) && $0.connection.map { $0.outputID != connection.outputID } == true
        }) else { throw AssignmentError("These timing groups span different outputs. Separate their speaker groups before linking a hardware-controlled subwoofer.") }
        for index in members {
            _ = try validateConnection(speakers[index].connection!, excluding: speakers[index].id, outputs: outputs)
        }
        let subs = speakers.indices.filter { speakers[$0].linkedSubwoofer && groups.contains(speakers[$0].timingGroupID) }
        return LinkedGroupPlan(id: parent.timingGroupID.isEmpty ? UUID().uuidString : parent.timingGroupID, indices: members + subs)
    }

    private mutating func applyGroup(_ plan: LinkedGroupPlan) {
        for index in plan.indices {
            speakers[index].timingGroupID = plan.id
            if speakers[index].linkedSubwoofer { speakers[index].connection = nil }
        }
    }

    private func outputLabel(_ outputID: String, outputs: [AudioOutput]) -> String {
        guard let output = outputs.first(where: { $0.id == outputID }) else { return "\(outputID) (unavailable)" }
        return output.available ? output.name : "\(output.name) (unavailable)"
    }
    /// Geometry is a starting point, never measured phase or arrival alignment. Facing zero points toward -Z.
    public func suggestedMixes(for listener: ListeningPosition) -> [ChannelMix] {
        speakers.compactMap { speaker in
            guard let connection = speaker.connection, !speaker.linkedSubwoofer else { return nil }
            let dx = speaker.position.x - listener.position.x, dz = speaker.position.z - listener.position.z
            let azimuth = atan2(dx, -dz) - listener.facingRadians
            let pan = max(-1, min(1, sin(azimuth)))
            return ChannelMix(connection: connection, left: cos((pan + 1) * .pi / 4), right: sin((pan + 1) * .pi / 4), gainDB: 0, delaySeconds: 0, fir: [])
        }
    }
}
public enum CalibrationState: String, Codable, Sendable { case unverified, needsVerification, verified }
public struct MeasurementConditions: Codable, Sendable, Equatable {
    public var microphoneID: String; public var microphoneOrientation: String
    public var sampleRate: Double; public var outputVolume: Double; public var furnitureRevision: String
    public var ambientNoiseDBFS: Double; public var capturedAt: Date
    public init(microphoneID: String, microphoneOrientation: String, sampleRate: Double, outputVolume: Double, furnitureRevision: String, ambientNoiseDBFS: Double, capturedAt: Date = Date()) {
        self.microphoneID = microphoneID; self.microphoneOrientation = microphoneOrientation; self.sampleRate = sampleRate
        self.outputVolume = outputVolume; self.furnitureRevision = furnitureRevision; self.ambientNoiseDBFS = ambientNoiseDBFS; self.capturedAt = capturedAt
    }
}
public struct VerificationProvenance: Codable, Sendable {
    public var captureIDs: [UUID]; public var verifiedAt: Date; public var configurationDigest: String
    public var conditions: MeasurementConditions; public var beforeErrorDB: Double; public var afterErrorDB: Double
    public init(captureIDs: [UUID], verifiedAt: Date, configurationDigest: String, conditions: MeasurementConditions, beforeErrorDB: Double, afterErrorDB: Double) {
        self.captureIDs = captureIDs; self.verifiedAt = verifiedAt; self.configurationDigest = configurationDigest; self.conditions = conditions
        self.beforeErrorDB = beforeErrorDB; self.afterErrorDB = afterErrorDB
    }
}
public struct CalibrationProfile: Codable, Sendable, Identifiable {
    public var id: UUID; public var name: String; public var positionID: UUID; public var outputIDs: [String]
    public var mixes: [ChannelMix]; public var state: CalibrationState; public var configurationDigest: String
    public var conditions: MeasurementConditions?; public var provenance: VerificationProvenance?
    public var measuredBefore: ResponseCurve?; public var measuredAfter: ResponseCurve?; public var predicted: ResponseCurve?
    public init(id: UUID, name: String, positionID: UUID, outputIDs: [String], mixes: [ChannelMix], state: CalibrationState, configurationDigest: String, conditions: MeasurementConditions? = nil, provenance: VerificationProvenance? = nil, measuredBefore: ResponseCurve? = nil, measuredAfter: ResponseCurve? = nil, predicted: ResponseCurve? = nil) {
        self.id = id; self.name = name; self.positionID = positionID; self.outputIDs = outputIDs; self.mixes = mixes
        self.state = state; self.configurationDigest = configurationDigest; self.conditions = conditions; self.provenance = provenance
        self.measuredBefore = measuredBefore; self.measuredAfter = measuredAfter; self.predicted = predicted
    }
    public mutating func invalidate(configurationDigest current: String, conditions currentConditions: MeasurementConditions? = nil) {
        if configurationDigest != current || (currentConditions != nil && conditions != currentConditions) { state = .needsVerification }
    }
    public var hasMeasuredVerification: Bool {
        guard state == .verified, let provenance, Set(provenance.captureIDs).count >= 18,
              !configurationDigest.isEmpty, conditions != nil, let measuredBefore, let measuredAfter,
              measuredBefore.frequencies.count >= 2, measuredAfter.frequencies.count >= 2,
              measuredBefore.frequencies.count == measuredBefore.decibels.count,
              measuredAfter.frequencies.count == measuredAfter.decibels.count,
              measuredBefore.frequencies.allSatisfy({ $0.isFinite && $0 > 0 }),
              measuredAfter.frequencies.allSatisfy({ $0.isFinite && $0 > 0 }),
              measuredBefore.decibels.allSatisfy(\.isFinite), measuredAfter.decibels.allSatisfy(\.isFinite) else { return false }
        return provenance.configurationDigest == configurationDigest && provenance.afterErrorDB.isFinite && provenance.beforeErrorDB.isFinite && provenance.afterErrorDB < provenance.beforeErrorDB
    }
}
