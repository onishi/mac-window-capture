// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WindowCapture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WindowCapture",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "WindowCaptureTests",
            dependencies: ["WindowCapture"]
        ),
    ]
)
