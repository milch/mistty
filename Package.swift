// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mistty",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "MisttyShared",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "MisttyShared"
        ),
        .executableTarget(
            name: "Mistty",
            dependencies: [
                "GhosttyKit",
                "MisttyShared",
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Mistty",
            exclude: ["Resources/Info.plist", "Resources/AppIcon.icns"],
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
            path: "MisttyCLI",
            linkerSettings: [
                // Embed Mistty's Info.plist into the mach-o `__TEXT,__info_plist`
                // section so `mistty-cli version` can report a version number
                // even when the binary is invoked from outside the .app (e.g.
                // a bare copy on $PATH, or `.build/debug/MisttyCLI`).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Mistty/Resources/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "MisttyTests",
            dependencies: [
                "Mistty",
                "MisttyShared",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "MisttyTests",
            exclude: ["Snapshots/__Snapshots__"]
        )
    ]
)
