// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SmartScreenshot",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ScreenshotCore", targets: ["ScreenshotCore"]),
        .executable(name: "ScreenshotLab", targets: ["ScreenshotLab"]),
        .executable(name: "ScreenshotBench", targets: ["ScreenshotBench"])
    ],
    targets: [
        .target(name: "ScreenshotCore"),
        .executableTarget(name: "ScreenshotLab", dependencies: ["ScreenshotCore"]),
        .executableTarget(name: "ScreenshotBench", dependencies: ["ScreenshotCore"]),
        .testTarget(name: "ScreenshotCoreTests", dependencies: ["ScreenshotCore"], resources: [.copy("Fixtures")])
    ]
)
