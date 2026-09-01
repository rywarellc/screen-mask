// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenMask",
    platforms: [.macOS(.v15)],
    targets: [
        // Masking model + Core Image pipeline, kept free of UI so it can be tested headlessly.
        .target(
            name: "ScreenMaskKit",
            path: "Sources/ScreenMaskKit"
        ),
        .executableTarget(
            name: "ScreenMask",
            dependencies: ["ScreenMaskKit"],
            path: "Sources/ScreenMask"
        ),
        // Covers AppModel, which lives in the executable target because it owns
        // the player and the SwiftUI state.
        .testTarget(
            name: "ScreenMaskAppTests",
            dependencies: ["ScreenMask", "ScreenMaskKit"],
            path: "Tests/ScreenMaskAppTests"
        ),
        .testTarget(
            name: "ScreenMaskKitTests",
            dependencies: ["ScreenMaskKit"],
            path: "Tests/ScreenMaskKitTests"
        ),
    ]
)
