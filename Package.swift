// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "nemotron-flow",
    platforms: [.macOS(.v14)],
    targets: [
        // Build a runnable .app (with mic/accessibility permissions) via scripts/build_app.sh.
        .executableTarget(
            name: "nemotron_flow",
            path: "Sources",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
