// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EdgeDial",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "EdgeDial",
            path: "Sources/EdgeDial"
        ),
        .testTarget(
            name: "EdgeDialTests",
            dependencies: ["EdgeDial"],
            path: "Tests/EdgeDialTests"
        ),
    ]
)
