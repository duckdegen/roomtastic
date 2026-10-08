// SPDX-License-Identifier: MIT
import XCTest
@testable import RoomtasticShared

final class MeasurementGridTests: XCTestCase {
    func testGridFollowsMeasuredCenterAndListenerFacingWithoutChangingHeight() throws {
        let actual = Point3(x: -3.5, y: 1.17, z: 2.8)
        let grid = MeasurementGrid(center: actual, facingRadians: .pi / 2)
        XCTAssertEqual(grid.target(pointIndex: 0), actual)
        let left = try XCTUnwrap(grid.target(pointIndex: 1))
        let forward = try XCTUnwrap(grid.target(pointIndex: 3))
        XCTAssertEqual(left.x, actual.x, accuracy: 1e-12)
        XCTAssertEqual(left.z, actual.z - 0.2, accuracy: 1e-12)
        XCTAssertEqual(forward.x, actual.x + 0.2, accuracy: 1e-12)
        XCTAssertEqual(forward.z, actual.z, accuracy: 1e-12)
        XCTAssertEqual(left.y, actual.y)
        XCTAssertEqual(forward.y, actual.y)
        XCTAssertNil(grid.target(pointIndex: -1))
        XCTAssertNil(grid.target(pointIndex: 9))
        XCTAssertNil(MeasurementGrid.localOffset(pointIndex: -1))
        XCTAssertNil(MeasurementGrid.localOffset(pointIndex: 9))

        for facing in [0.0, .pi / 2, -.pi / 3, .pi] {
            let rotated = MeasurementGrid(center: actual, facingRadians: facing)
            for pointIndex in 0..<9 {
                let offset = try XCTUnwrap(MeasurementGrid.localOffset(pointIndex: pointIndex))
                let target = try XCTUnwrap(rotated.target(pointIndex: pointIndex))
                let local = rotated.localPosition(worldPosition: target)
                XCTAssertEqual(local.x, offset.x, accuracy: 1e-12)
                XCTAssertEqual(local.y, 0, accuracy: 1e-12)
                XCTAssertEqual(local.z, offset.z, accuracy: 1e-12)
            }
            let raised = Point3(x: 0.13, y: 0.08, z: -0.07)
            let roundTrip = rotated.localPosition(worldPosition: rotated.worldPosition(localPosition: raised))
            XCTAssertEqual(roundTrip.x, raised.x, accuracy: 1e-12)
            XCTAssertEqual(roundTrip.y, raised.y, accuracy: 1e-12)
            XCTAssertEqual(roundTrip.z, raised.z, accuracy: 1e-12)

            // Going Left, then Right, must not move the origin for the Forward target.
            let localLeft = rotated.localPosition(worldPosition: try XCTUnwrap(rotated.target(pointIndex: 1)))
            let localRight = rotated.localPosition(worldPosition: try XCTUnwrap(rotated.target(pointIndex: 2)))
            let localForward = rotated.localPosition(worldPosition: try XCTUnwrap(rotated.target(pointIndex: 3)))
            XCTAssertEqual(localRight.x - localLeft.x, 0.4, accuracy: 1e-12)
            XCTAssertEqual(localForward.x - localRight.x, -0.2, accuracy: 1e-12)
            XCTAssertEqual(localForward.z - localRight.z, -0.2, accuracy: 1e-12)
            XCTAssertEqual(rotated.target(pointIndex: 0), actual)
        }
    }
}
