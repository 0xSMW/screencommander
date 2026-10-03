// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "screencommander",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "screencommander", targets: ["ScreenCommander"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "ScreenCommanderPresence",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .executableTarget(
            name: "ScreenCommander",
            dependencies: [
                "ScreenCommanderPresence",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "ScreenCommanderTests",
            dependencies: ["ScreenCommander", "ScreenCommanderPresence"]
        ),
        .testTarget(
            name: "ScreenCommanderPresenceTests",
            dependencies: ["ScreenCommanderPresence"]
        )
    ]
)
