// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tincan",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Tincan", targets: ["Tincan"]),
        .library(name: "TincanCore", targets: ["TincanCore"]),
        .executable(name: "tincan", targets: ["TincanCLI"]),
    ],
    targets: [
        .target(name: "TincanCore"),
        .target(name: "Tincan", dependencies: ["TincanCore"]),
        .target(name: "TincanCommand", dependencies: ["TincanCore"]),
        .executableTarget(name: "TincanCLI", dependencies: ["TincanCommand"]),
        .testTarget(name: "TincanCoreTests", dependencies: ["TincanCore", "TincanCommand"]),
        .testTarget(name: "TincanTests", dependencies: ["Tincan"]),
    ]
)
