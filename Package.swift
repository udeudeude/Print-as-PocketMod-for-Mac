// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PrintAsPocketMod",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PocketModCore", targets: ["PocketModCore"]),
        .executable(name: "PocketModApp", targets: ["PocketModApp"]),
    ],
    targets: [
        .target(name: "PocketModCore"),
        .executableTarget(
            name: "PocketModApp",
            dependencies: ["PocketModCore"]
        ),
        .testTarget(
            name: "PocketModCoreTests",
            dependencies: ["PocketModCore"]
        ),
    ]
)
