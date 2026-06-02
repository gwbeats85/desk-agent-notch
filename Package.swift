// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkShot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MarkShot", targets: ["MarkShot"])
    ],
    targets: [
        .executableTarget(
            name: "MarkShot",
            path: "Sources/MarkShot"
        ),
        .testTarget(
            name: "MarkShotTests",
            dependencies: ["MarkShot"],
            path: "Tests/MarkShotTests"
        )
    ]
)
