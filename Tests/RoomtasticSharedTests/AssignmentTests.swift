// SPDX-License-Identifier: MIT
import XCTest
@testable import RoomtasticShared

final class AssignmentTests: XCTestCase {
    private let position = Point3(x: 1.2, y: 0.7, z: -2.4)
    private let stereo = AudioOutput(id: "airplay:receiver-a", name: "Original receiver", kind: .airplay, channels: 2, sampleRate: 48_000, available: true)
    private let second = AudioOutput(id: "wired:receiver-b", name: "Other receiver", kind: .wired, channels: 2, sampleRate: 48_000, available: true)

    private func emptyRoom() -> RoomModel {
        RoomModel(id: UUID(), name: "Scanned room", speakers: [], positions: [
            ListeningPosition(id: UUID(), name: "Sofa", position: Point3(x: 0.5, y: 1, z: 2), facingRadians: 0.3)
        ], geometry: ScannedGeometry(surfaces: [], capturedAt: Date(timeIntervalSince1970: 100), roomPlanArchive: Data([1, 2, 3])))
    }
    private func bytes(_ room: RoomModel) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(room)
    }
    private func add(_ name: String, channel: Int, output: AudioOutput, to room: inout RoomModel) throws -> UUID {
        try room.addConnectedSpeaker(name: name, position: position, facingRadians: 0.4,
                                     connection: ChannelConnection(outputID: output.id, channel: channel), outputs: [output])
    }
    private func speaker(_ id: UUID, in room: RoomModel) throws -> PhysicalSpeaker {
        try XCTUnwrap(room.speakers.first { $0.id == id })
    }

    func testInvalidNewAssignmentsLeaveEntireRoomUntouched() throws {
        var room = emptyRoom()
        _ = try add("Left", channel: 0, output: stereo, to: &room)
        let before = try bytes(room)
        var unavailable = second; unavailable.available = false
        var multichannel = second; multichannel.channels = 8
        let rejected: [(ChannelConnection, [AudioOutput])] = [
            (ChannelConnection(outputID: "unknown", channel: 0), [stereo]),
            (ChannelConnection(outputID: second.id, channel: 0), [unavailable]),
            (ChannelConnection(outputID: stereo.id, channel: 0), [stereo]),
            (ChannelConnection(outputID: stereo.id, channel: -1), [stereo]),
            (ChannelConnection(outputID: stereo.id, channel: 2), [stereo]),
            (ChannelConnection(outputID: second.id, channel: 2), [multichannel])
        ]
        for (connection, outputs) in rejected {
            XCTAssertThrowsError(try room.addConnectedSpeaker(name: "New speaker", position: position, facingRadians: 0, connection: connection, outputs: outputs))
            XCTAssertEqual(try bytes(room), before)
        }
        let free = ChannelConnection(outputID: stereo.id, channel: 1)
        XCTAssertThrowsError(try room.addConnectedSpeaker(name: " \n ", position: position, facingRadians: 0, connection: free, outputs: [stereo]))
        XCTAssertThrowsError(try room.addConnectedSpeaker(name: "Right", position: Point3(x: .nan, y: 1, z: 1), facingRadians: 0, connection: free, outputs: [stereo]))
        XCTAssertThrowsError(try room.addConnectedSpeaker(name: "Right", position: position, facingRadians: .infinity, connection: free, outputs: [stereo]))
        XCTAssertEqual(try bytes(room), before)
    }

    func testRejectedReassignmentPreservesSavedRouteAndLocation() throws {
        var room = emptyRoom()
        let left = try add("Left", channel: 0, output: stereo, to: &room)
        _ = try add("Right", channel: 1, output: stereo, to: &room)
        let before = try bytes(room)
        var unavailable = second; unavailable.available = false
        XCTAssertThrowsError(try room.setSpeakerConnection(speakerID: left, connection: ChannelConnection(outputID: stereo.id, channel: 1), outputs: [stereo]))
        XCTAssertEqual(try bytes(room), before)
        XCTAssertThrowsError(try room.setSpeakerConnection(speakerID: left, connection: ChannelConnection(outputID: second.id, channel: 0), outputs: [unavailable]))
        XCTAssertEqual(try bytes(room), before)
        XCTAssertThrowsError(try room.setSpeakerConnection(speakerID: left, connection: ChannelConnection(outputID: "unknown", channel: 0), outputs: [stereo]))
        XCTAssertEqual(try bytes(room), before)
    }

    func testLinkingSubUnifiesStereoAndExistingVisualSubs() throws {
        var room = emptyRoom()
        let left = try add("Left", channel: 0, output: stereo, to: &room)
        let right = try add("Right", channel: 1, output: stereo, to: &room)
        let leftGroup = try speaker(left, in: room).timingGroupID
        let rightGroup = try speaker(right, in: room).timingGroupID
        let existingSub = UUID()
        room.speakers.append(PhysicalSpeaker(id: existingSub, name: "Existing visual sub", position: position, facingRadians: 0.7, connection: nil, linkedSubwoofer: true, timingGroupID: rightGroup))
        let newSub = try room.addLinkedSubwoofer(name: "Bass unit", position: position, facingRadians: 0.2, parentSpeakerID: left, outputs: [stereo])
        for id in [left, right, existingSub, newSub] {
            XCTAssertEqual(try speaker(id, in: room).timingGroupID, leftGroup)
            XCTAssertEqual(try speaker(id, in: room).position, position)
        }
        for id in [existingSub, newSub] { XCTAssertNil(try speaker(id, in: room).connection) }
        XCTAssertEqual(room.suggestedMixes(for: room.positions[0]).map(\.connection), [ChannelConnection(outputID: stereo.id, channel: 0), ChannelConnection(outputID: stereo.id, channel: 1)])
    }

    func testCrossOutputGroupCannotBeMergedAndFailureIsAtomic() throws {
        var room = emptyRoom()
        let parent = try add("Left", channel: 0, output: stereo, to: &room)
        _ = try add("Other room", channel: 0, output: second, to: &room)
        room.speakers[1].timingGroupID = room.speakers[0].timingGroupID
        let legacy = UUID()
        room.speakers.append(PhysicalSpeaker(id: legacy, name: "Legacy tag", position: position, facingRadians: 0.3, connection: nil, linkedSubwoofer: false, timingGroupID: UUID().uuidString))
        let before = try bytes(room)
        XCTAssertThrowsError(try room.addLinkedSubwoofer(name: "Sub", position: position, facingRadians: 0, parentSpeakerID: parent, outputs: [stereo, second]))
        XCTAssertEqual(try bytes(room), before)
        XCTAssertThrowsError(try room.linkSubwoofer(speakerID: legacy, parentSpeakerID: parent, outputs: [stereo, second]))
        XCTAssertEqual(try bytes(room), before)
    }

    func testLinkedSubRequiresMappedAvailableStereoParent() throws {
        var room = emptyRoom()
        var mono = second; mono.channels = 1
        let parent = try add("Mono", channel: 0, output: mono, to: &room)
        let before = try bytes(room)
        XCTAssertThrowsError(try room.addLinkedSubwoofer(name: "Sub", position: position, facingRadians: 0, parentSpeakerID: parent, outputs: [mono]))
        var unavailable = second; unavailable.available = false
        XCTAssertThrowsError(try room.addLinkedSubwoofer(name: "Sub", position: position, facingRadians: 0, parentSpeakerID: parent, outputs: [unavailable]))
        XCTAssertThrowsError(try room.addLinkedSubwoofer(name: "Sub", position: position, facingRadians: 0, parentSpeakerID: UUID(), outputs: [stereo]))
        XCTAssertEqual(try bytes(room), before)
    }

    func testLaterSpeakerAndReassignedSpeakerInheritLinkedGroup() throws {
        var room = emptyRoom()
        let left = try add("Left", channel: 0, output: stereo, to: &room)
        let sub = try room.addLinkedSubwoofer(name: "Sub", position: position, facingRadians: 0, parentSpeakerID: left, outputs: [stereo])
        let right = try add("Right", channel: 1, output: stereo, to: &room)
        XCTAssertEqual(try speaker(right, in: room).timingGroupID, try speaker(sub, in: room).timingGroupID)
        room.speakers.removeAll { $0.id == right }
        let replacement = try add("Replacement", channel: 1, output: second, to: &room)
        try room.setSpeakerConnection(speakerID: replacement, connection: ChannelConnection(outputID: stereo.id, channel: 1), outputs: [stereo, second])
        XCTAssertEqual(try speaker(replacement, in: room).timingGroupID, try speaker(left, in: room).timingGroupID)
        XCTAssertEqual(try speaker(replacement, in: room).position, position)
        XCTAssertFalse(room.channelIsAssigned(ChannelConnection(outputID: second.id, channel: 1)))
        XCTAssertTrue(room.channelIsAssigned(ChannelConnection(outputID: stereo.id, channel: 1)))
        XCTAssertFalse(room.channelIsAssigned(ChannelConnection(outputID: stereo.id, channel: 1), excluding: replacement))
    }

    func testReassignmentCannotSplitLinkedStereoSystem() throws {
        var room = emptyRoom()
        let left = try add("Left", channel: 0, output: stereo, to: &room)
        _ = try add("Right", channel: 1, output: stereo, to: &room)
        _ = try room.addLinkedSubwoofer(name: "Sub", position: position, facingRadians: 0, parentSpeakerID: left, outputs: [stereo])
        let before = try bytes(room)
        XCTAssertThrowsError(try room.setSpeakerConnection(speakerID: left, connection: ChannelConnection(outputID: second.id, channel: 0), outputs: [stereo, second]))
        XCTAssertEqual(try bytes(room), before)
    }

    func testSoleLinkedParentCanMoveWithoutStrandingSub() throws {
        var room = emptyRoom()
        let left = try add("Left", channel: 0, output: stereo, to: &room)
        let sub = try room.addLinkedSubwoofer(name: "Sub", position: position, facingRadians: 0, parentSpeakerID: left, outputs: [stereo])
        let right = try add("Right at destination", channel: 1, output: second, to: &room)
        try room.setSpeakerConnection(speakerID: left, connection: ChannelConnection(outputID: second.id, channel: 0), outputs: [stereo, second])
        XCTAssertEqual(try speaker(left, in: room).timingGroupID, try speaker(sub, in: room).timingGroupID)
        XCTAssertEqual(try speaker(right, in: room).timingGroupID, try speaker(sub, in: room).timingGroupID)
        XCTAssertNil(try speaker(sub, in: room).connection)
        XCTAssertTrue(room.assignmentLabel(for: try speaker(sub, in: room), outputs: [stereo, second]).contains(second.name))
    }

    func testConvertingOnlyParentCannotStrandExistingSubs() throws {
        var room = emptyRoom()
        let parent = try add("Parent", channel: 0, output: stereo, to: &room)
        _ = try room.addLinkedSubwoofer(name: "Sub", position: position, facingRadians: 0, parentSpeakerID: parent, outputs: [stereo])
        let other = try add("Other system", channel: 0, output: second, to: &room)
        let before = try bytes(room)
        XCTAssertThrowsError(try room.linkSubwoofer(speakerID: parent, parentSpeakerID: other, outputs: [stereo, second]))
        XCTAssertEqual(try bytes(room), before)
        let right = try add("Right", channel: 1, output: stereo, to: &room)
        try room.linkSubwoofer(speakerID: parent, parentSpeakerID: right, outputs: [stereo])
        XCTAssertNil(try speaker(parent, in: room).connection)
        XCTAssertTrue(try speaker(parent, in: room).linkedSubwoofer)
        XCTAssertEqual(try speaker(parent, in: room).position, position)
    }

    func testLatestReceiverNameLabelsStableSavedAssignments() throws {
        var room = emptyRoom()
        let parent = try add("Left", channel: 0, output: stereo, to: &room)
        let sub = try room.addLinkedSubwoofer(name: "Sub", position: position, facingRadians: 0, parentSpeakerID: parent, outputs: [stereo])
        let savedConnection = try speaker(parent, in: room).connection
        var renamed = stereo; renamed.name = "Renamed receiver"
        let label = room.assignmentLabel(for: try speaker(parent, in: room), outputs: [renamed])
        XCTAssertTrue(label.contains(renamed.name)); XCTAssertFalse(label.contains(stereo.name))
        XCTAssertTrue(label.contains("Left"))
        let subLabel = room.assignmentLabel(for: try speaker(sub, in: room), outputs: [renamed])
        XCTAssertTrue(subLabel.contains(renamed.name)); XCTAssertTrue(subLabel.contains("Hardware-controlled sub"))
        XCTAssertFalse(subLabel.contains("Channel"))
        room.speakers[0].name = "Physical left renamed"
        room.speakers[0].position = Point3(x: 2, y: 1, z: -3)
        let restored = try JSONDecoder().decode(RoomModel.self, from: bytes(room))
        XCTAssertEqual(try speaker(parent, in: restored).connection, savedConnection)
        XCTAssertEqual(try speaker(parent, in: restored).position, Point3(x: 2, y: 1, z: -3))
        renamed.available = false
        XCTAssertTrue(restored.assignmentLabel(for: try speaker(parent, in: restored), outputs: [renamed]).contains("unavailable"))
        var legacy = try speaker(parent, in: restored); legacy.connection = nil
        XCTAssertEqual(restored.assignmentLabel(for: legacy, outputs: [renamed]), "Output not assigned")
    }
}
