// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SmartScreenshot",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ScreenshotCore", targets: ["ScreenshotCore"]),
        .executable(name: "ScreenshotLab", targets: ["ScreenshotLab"]),
        .executable(name: "ScreenshotBench", targets: ["ScreenshotBench"]),
        .executable(name: "Snug", targets: ["Snug"])
    ],
    targets: [
        .target(name: "ScreenshotCore"),
        .executableTarget(name: "ScreenshotLab", dependencies: ["ScreenshotCore"]),
        .executableTarget(name: "ScreenshotBench", dependencies: ["ScreenshotCore"]),
        .executableTarget(name: "Snug", dependencies: ["ScreenshotCore"]),
        .testTarget(name: "ScreenshotCoreTests", dependencies: ["ScreenshotCore", "ScreenshotBench"], resources: [.copy("Fixtures")])
    ]
)
