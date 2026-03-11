// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mistty",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Mistty",
            dependencies: ["GhosttyKit"],
            path: "Mistty"
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/ghostty/macos/GhosttyKit.xcframework"
        ),
        .testTarget(
            name: "MisttyTests",
            dependencies: ["Mistty"],
            path: "MisttyTests"
        )
    ]
)
