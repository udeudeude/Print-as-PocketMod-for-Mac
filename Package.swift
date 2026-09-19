// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PrintAsPocketMod",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PocketModCore", targets: ["PocketModCore"]),
        .executable(name: "PocketModApp", targets: ["PocketModApp"]),
        .executable(name: "PocketModCLI", targets: ["PocketModCLI"]),
    ],
    targets: [
        .target(
            name: "PocketModCore",
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "PocketModApp",
            dependencies: ["PocketModCore"],
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "PocketModCLI",
            dependencies: ["PocketModCore"],
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "PocketModCoreTests",
            dependencies: ["PocketModCore"]
        ),
    ]
)
