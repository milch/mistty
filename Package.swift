// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mistty",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "MisttyShared", path: "MisttyShared"),
        .executableTarget(
            name: "Mistty",
            dependencies: [
                "GhosttyKit",
                "MisttyShared",
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Mistty",
            exclude: ["Resources/Info.plist"],
            resources: [
                .process("Resources/Fonts"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Mistty/Resources/Info.plist",
                ]),
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/ghostty/macos/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "MisttyCLI",
            dependencies: [
                "MisttyShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "MisttyCLI"
        ),
        .testTarget(
            name: "MisttyTests",
            dependencies: ["Mistty", "MisttyShared"],
            path: "MisttyTests"
        )
    ]
)
