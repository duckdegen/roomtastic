// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import RoomtasticShared
@testable import RoomtasticCalibration

final class CalibrationRoutingTests: XCTestCase {
    private func render(_ sweep: CalibrationSweep, _ routing: CalibrationPlaybackRouting, _ output: String) -> [Float] {
        var stereo = [Float](repeating: .nan, count: 512)
        var result: [Float] = []; result.reserveCapacity(sweep.samples.count * 2)
        for offset in stride(from: 0, to: sweep.samples.count, by: 256) {
            stereo.withUnsafeMutableBufferPointer { routing.render(sweep, from: offset, outputID: output, into: $0) }
            result.append(contentsOf: stereo.prefix(min(256, sweep.samples.count - offset) * 2))
        }
        return result
    }
    func testIndividualRightSweepCannotReachOtherDevicesOrLeftChannel() throws {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 8000, duration: 0.5)
        let routing = try CalibrationPlaybackRouting(target: ChannelConnection(outputID: "target", channel: 1), mode: .channel,
                                                     referenceConnection: ChannelConnection(outputID: "anchor", channel: 0))
        let target = render(sweep, routing, "target"), anchor = render(sweep, routing, "anchor"), unrelated = render(sweep, routing, "other")
        let sweepRange = sweep.sweepStart..<(sweep.sweepStart + sweep.reference.count)
        for frame in sweep.samples.indices {
            XCTAssertEqual(target[frame * 2], 0)
            XCTAssertEqual(target[frame * 2 + 1], sweepRange.contains(frame) ? sweep.samples[frame] : 0)
            XCTAssertEqual(anchor[frame * 2], sweepRange.contains(frame) ? 0 : sweep.samples[frame])
            XCTAssertEqual(anchor[frame * 2 + 1], 0)
            XCTAssertEqual(unrelated[frame * 2], 0)
            XCTAssertEqual(unrelated[frame * 2 + 1], 0)
        }
    }
    func testLinkedStereoIsOneDeviceWhileSystemChecksExplicitlyIncludeAllDevices() throws {
        let sweep = try CalibrationAnalyzer.makeSweep(sampleRate: 8000, duration: 0.5)
        let target = ChannelConnection(outputID: "linked", channel: 0), anchor = ChannelConnection(outputID: "anchor", channel: 1)
        let linked = try CalibrationPlaybackRouting(target: target, mode: .linkedCombined, referenceConnection: anchor)
        let system = try CalibrationPlaybackRouting(target: target, mode: .system, referenceConnection: anchor)
        let linkedPCM = render(sweep, linked, "linked"), otherPCM = render(sweep, linked, "other"), systemPCM = render(sweep, system, "other")
        for frame in sweep.sweepStart..<(sweep.sweepStart + sweep.reference.count) {
            XCTAssertEqual(linkedPCM[frame * 2], sweep.samples[frame])
            XCTAssertEqual(linkedPCM[frame * 2 + 1], sweep.samples[frame])
            XCTAssertEqual(otherPCM[frame * 2], 0)
            XCTAssertEqual(otherPCM[frame * 2 + 1], 0)
            XCTAssertEqual(systemPCM[frame * 2], sweep.samples[frame])
            XCTAssertEqual(systemPCM[frame * 2 + 1], sweep.samples[frame])
        }
    }
    func testInvalidChannelCannotBecomeAnAllDeviceSweep() {
        XCTAssertThrowsError(try CalibrationPlaybackRouting(target: ChannelConnection(outputID: "target", channel: 2), mode: .channel,
                                                            referenceConnection: ChannelConnection(outputID: "anchor", channel: 0)))
    }
    func testCalibrationFailurePreservesItsReasonAcrossNSErrorBridging() {
        let reason = "The selected speaker could not be measured."
        let error: Error = CalibrationError.rejected(reason)
        XCTAssertEqual((error as NSError).localizedDescription, reason)
    }
}
