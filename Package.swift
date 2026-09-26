// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "fn-flow",
    platforms: [.macOS(.v14)],
    targets: [
        // Build a runnable .app (with mic/accessibility permissions) via scripts/build_app.sh.
        .executableTarget(
            name: "fn_flow",
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
