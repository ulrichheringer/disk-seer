// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DiskSeer",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DiskSeer", targets: ["DiskSeer"]),
        .executable(name: "diskseer-cli", targets: ["diskseer-cli"]),
        .library(name: "DiskSeerCore", targets: ["DiskSeerCore"]),
    ],
    targets: [
        .target(
            name: "DiskSeerCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DiskSeer",
            dependencies: ["DiskSeerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "diskseer-cli",
            dependencies: ["DiskSeerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DiskSeerCoreTests",
            dependencies: ["DiskSeerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
