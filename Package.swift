// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mistty",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Mistty",
            dependencies: [
                "GhosttyKit",
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Mistty",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
            ]
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
