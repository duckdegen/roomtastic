// SPDX-License-Identifier: MIT
import XCTest
@testable import RoomtasticShared

final class ListenerOrientationTests: XCTestCase {
    func testRearCameraForwardAndListenerLeftAgreeInEveryDirection() throws {
        let center = Point3(x: 2, y: 1.3, z: -4)
        for backward in [Point3(x: 0, y: 0, z: 1), Point3(x: -1, y: 0, z: 0),
                         Point3(x: 0, y: 0, z: -1), Point3(x: 1, y: 0, z: 0)] {
            let heading = try XCTUnwrap(ListenerOrientation.facing(cameraBackward: backward))
            let grid = MeasurementGrid(center: center, facingRadians: heading)
            let forward = try XCTUnwrap(grid.target(pointIndex: 3))
            let left = try XCTUnwrap(grid.target(pointIndex: 1))
            XCTAssertEqual(forward.x - center.x, -backward.x * 0.2, accuracy: 1e-12)
            XCTAssertEqual(forward.z - center.z, -backward.z * 0.2, accuracy: 1e-12)
            XCTAssertEqual(left.x - center.x, -backward.z * 0.2, accuracy: 1e-12)
            XCTAssertEqual(left.z - center.z, backward.x * 0.2, accuracy: 1e-12)
        }
    }
    func testPitchDoesNotReverseHeadingAndVerticalCameraHasNoInventedDirection() throws {
        let level = try XCTUnwrap(ListenerOrientation.facing(cameraBackward: Point3(x: -1, y: 0, z: 0)))
        let tilted = try XCTUnwrap(ListenerOrientation.facing(cameraBackward: Point3(x: -0.8, y: 0.6, z: 0)))
        XCTAssertEqual(tilted, level, accuracy: 1e-12)
        XCTAssertNil(ListenerOrientation.facing(cameraBackward: Point3(x: 0, y: 1, z: 0)))
        XCTAssertNil(ListenerOrientation.facing(cameraBackward: Point3(x: .nan, y: 0, z: 1)))
    }
}
