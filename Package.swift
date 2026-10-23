// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Whiplash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Whiplash",
            path: "Sources/Whiplash"
        ),
        .testTarget(
            name: "WhiplashTests",
            dependencies: ["Whiplash"],
            path: "Tests/WhiplashTests"
        ),
    ]
)
