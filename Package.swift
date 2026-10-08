// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription
let package = Package(
    name: "Roomtastic", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RoomtasticShared", targets: ["RoomtasticShared"]),
        .library(name: "RoomtasticTransport", targets: ["RoomtasticTransport"]),
        .executable(name: "RoomtasticService", targets: ["RoomtasticService"]),
        .executable(name: "RoomtasticMac", targets: ["RoomtasticMac"])
    ],
    targets: [
        .target(name: "RoomtasticShared"),
        .target(name: "RoomtasticTransport", dependencies: ["RoomtasticShared"]),
        .target(name: "RoomtasticControl", dependencies: ["RoomtasticShared"]),
        .target(name: "RoomtasticDSP", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Accelerate")]),
        .target(name: "RoomtasticCalibration", dependencies: ["RoomtasticShared"], linkerSettings: [.linkedFramework("Accelerate")]),
        .executableTarget(name: "RoomtasticService", dependencies: ["RoomtasticShared", "RoomtasticTransport", "RoomtasticControl", "RoomtasticDSP", "RoomtasticCalibration"], linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]),
        .executableTarget(name: "RoomtasticMac", dependencies: ["RoomtasticShared", "RoomtasticTransport", "RoomtasticControl"]),
        .testTarget(name: "RoomtasticSharedTests", dependencies: ["RoomtasticShared"]),
        .testTarget(name: "RoomtasticTransportTests", dependencies: ["RoomtasticTransport", "RoomtasticShared"]),
        .testTarget(name: "RoomtasticCalibrationTests", dependencies: ["RoomtasticCalibration"])
    ], cxxLanguageStandard: .cxx17
)
