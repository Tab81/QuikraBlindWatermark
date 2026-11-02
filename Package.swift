// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BlindWaterMark",
    platforms: [
        .macOS("13.0"),
        .iOS("16.4"),
        .tvOS("16.4"),
        .watchOS("9.4"),
        .visionOS("1.0"),
    ],
    products: [
        .library(name: "BWM", targets: ["BWM"]),
        .library(name: "BlindWatermarkKit", targets: ["BlindWatermarkKit"]),
    ],
    targets: [
        .target(
            name: "BWM",
            path: "Sources/BWM",
            publicHeadersPath: ".",
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(
            name: "BlindWatermarkKit",
            dependencies: ["BWM"],
            path: "Sources/BlindWatermarkKit"
        ),
        .testTarget(
            name: "BlindWatermarkKitTests",
            dependencies: ["BlindWatermarkKit"],
            path: "Tests/BlindWatermarkKitTests",
            resources: [.process("Fixtures")]
        ),
        .target(
            name: "D1SweepSupport",
            dependencies: ["BWM"],
            path: "Tests/D1SweepSupport",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "D1Sweep",
            dependencies: ["BWM", "D1SweepSupport"],
            path: "Tools/D1Sweep"
        ),
    ]
)
