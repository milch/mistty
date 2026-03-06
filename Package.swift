// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mistty",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Mistty",
            path: "Mistty"
        ),
        .testTarget(
            name: "MisttyTests",
            dependencies: ["Mistty"],
            path: "MisttyTests"
        )
    ]
)
