// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "fn-flow",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-process Parakeet speech-to-text on the Apple Neural Engine (Core ML).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
    ],
    targets: [
        // Build a runnable .app (with mic/accessibility permissions) via scripts/build_app.sh.
        .executableTarget(
            name: "fn_flow",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "fn_flowTests",
            dependencies: ["fn_flow"],
            path: "Tests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
