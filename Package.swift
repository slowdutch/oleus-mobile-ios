// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "OleusMobile",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),   // keeps `swift build` runnable for CI sanity checks
    ],
    products: [
        .library(
            name: "OleusMobile",
            targets: ["OleusMobile"]),
    ],
    dependencies: [],
    targets: [
        // Async-signal-safe crash capture — pure C, no Foundation.
        .target(
            name: "OleusCrashCore",
            dependencies: []),
        .target(
            name: "OleusMobile",
            dependencies: ["OleusCrashCore"]),
        .testTarget(
            name: "OleusMobileTests",
            dependencies: ["OleusMobile"]),
    ]
)
