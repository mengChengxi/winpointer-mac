// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "winpointer-mac",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "winpointer", targets: ["WinPointerCLI"]),
        .executable(name: "winpointer-core-tests", targets: ["WinPointerCoreSmokeTests"]),
        .library(name: "WinPointerCore", targets: ["WinPointerCore"]),
    ],
    targets: [
        .target(
            name: "WinPointerHIDShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "WinPointerCore",
            dependencies: ["WinPointerHIDShim"],
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "WinPointerCLI",
            dependencies: ["WinPointerCore"]
        ),
        .executableTarget(
            name: "WinPointerCoreSmokeTests",
            dependencies: ["WinPointerCore"]
        ),
    ]
)
