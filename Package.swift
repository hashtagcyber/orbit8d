// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "orbit8d",
    // Core Audio process taps need macOS 14.2.
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "OrbitCore"),
        .executableTarget(name: "Orbit8D", dependencies: ["OrbitCore"]),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"]),
    ]
)
