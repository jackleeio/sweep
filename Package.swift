// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sweep",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SweepCore"),
        .executableTarget(name: "sweep", dependencies: ["SweepCore"]),
        .executableTarget(name: "SweepApp", dependencies: ["SweepCore"]),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"]),
    ]
)
