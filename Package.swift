// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Kotobane",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KotobaneCore", targets: ["KotobaneCore"])
    ],
    targets: [
        .target(name: "KotobaneCore"),
        .testTarget(name: "KotobaneCoreTests", dependencies: ["KotobaneCore"])
    ]
)
