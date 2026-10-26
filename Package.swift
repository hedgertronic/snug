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
        // Sparkle 2.10.0's own manifest is this binary target. Depending on it directly keeps the build working in a checkout whose
        // directory is named "sparkle", where a package dependency would share the root package's identity.
        .binaryTarget(name: "Sparkle", url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
                      checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"),
        .executableTarget(name: "ScreenshotLab", dependencies: ["ScreenshotCore"]),
        .executableTarget(name: "ScreenshotBench", dependencies: ["ScreenshotCore"]),
        .executableTarget(name: "Snug", dependencies: ["ScreenshotCore", "Sparkle"],
                         // Snug.app embeds Sparkle.framework in Contents/Frameworks.
                         linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ScreenshotCoreTests", dependencies: ["ScreenshotCore", "ScreenshotBench"], resources: [.copy("Fixtures")])
    ]
)
