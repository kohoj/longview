// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Longview",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "longview", targets: ["LongviewCLI"])
    ],
    targets: [
        .target(
            name: "LongviewCore",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
        .target(
            name: "LongviewCapture",
            dependencies: ["LongviewCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .target(
            name: "LongviewCLIKit",
            dependencies: ["LongviewCore", "LongviewCapture"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "LongviewCLI",
            dependencies: ["LongviewCLIKit"]
        ),
        .executableTarget(
            name: "LongviewFixtureApp",
            path: "Fixtures/LongviewFixtureApp"
        ),
        .testTarget(
            name: "LongviewCoreTests",
            dependencies: ["LongviewCore"]
        ),
        .testTarget(
            name: "LongviewCaptureTests",
            dependencies: ["LongviewCapture"]
        ),
        .testTarget(
            name: "LongviewCLIKitTests",
            dependencies: ["LongviewCLIKit"]
        ),
    ]
)
