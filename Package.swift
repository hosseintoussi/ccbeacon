// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ccbeacon",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CCBeaconCore",
            path: "Sources/CCBeaconCore"
        ),
        .executableTarget(
            name: "ccbeacon",
            dependencies: ["CCBeaconCore"],
            path: "Sources/ccbeacon"
        ),
        .executableTarget(
            name: "CCBeaconTests",
            dependencies: ["CCBeaconCore"],
            path: "Tests/CCBeaconCoreTests"
        ),
    ]
)
