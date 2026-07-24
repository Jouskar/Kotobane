// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Kotobane",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KotobaneCore", targets: ["KotobaneCore"]),
        .executable(
            name: "kotobane-launch-shim",
            targets: ["KotobaneLaunchShim"]
        ),
    ],
    targets: [
        .target(name: "KotobaneCore"),
        .executableTarget(
            name: "KotobaneLaunchShim",
            path: "Sources/KotobaneLaunchShim"
        ),
        .testTarget(name: "KotobaneCoreTests", dependencies: ["KotobaneCore"])
    ]
)
