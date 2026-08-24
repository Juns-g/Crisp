// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrispControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrispControlCore", targets: ["CrispControlCore"]),
        .library(name: "CrispControlCLI", targets: ["CrispControlCLI"]),
        .executable(name: "crispctl", targets: ["crispctl"]),
        .executable(name: "crisp-control-test-host", targets: ["CrispControlTestHost"])
    ],
    targets: [
        .target(name: "CrispControlCore"),
        .target(name: "CrispControlCLI", dependencies: ["CrispControlCore"]),
        .executableTarget(name: "crispctl", dependencies: ["CrispControlCLI", "CrispControlCore"]),
        .executableTarget(name: "CrispControlTestHost", dependencies: ["CrispControlCore"]),
        .testTarget(name: "CrispControlCoreTests", dependencies: ["CrispControlCore"]),
        .testTarget(name: "CrispControlCLITests", dependencies: ["CrispControlCLI", "CrispControlCore"])
    ]
)
