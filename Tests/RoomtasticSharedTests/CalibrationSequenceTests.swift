// SPDX-License-Identifier: MIT
import XCTest
@testable import RoomtasticShared

final class CalibrationSequenceTests: XCTestCase {
    func testAllChannelsRunBeforeRequiringMovementAndVerificationUsesFreshPositions() {
        var sequence = CalibrationSequence(signalCount: 3)
        for point in 0..<9 {
            for channel in 0..<3 {
                XCTAssertEqual(sequence.purpose, .calibration)
                XCTAssertEqual(sequence.pointIndex, point)
                XCTAssertEqual(sequence.signalIndex, channel)
                XCTAssertEqual(sequence.acceptCapture(), channel < 2 ? .channel : .position)
            }
        }
        for purpose in [SweepPurpose.systemBefore, .systemAfter] {
            for point in 0..<9 {
                XCTAssertEqual(sequence.purpose, purpose)
                XCTAssertEqual(sequence.pointIndex, point)
                let next = sequence.acceptCapture()
                XCTAssertEqual(next, purpose == .systemAfter && point == 8 ? .finished : .position)
            }
        }
        XCTAssertTrue(sequence.isComplete)
        XCTAssertEqual(sequence.acceptCapture(), .finished)
    }

}
