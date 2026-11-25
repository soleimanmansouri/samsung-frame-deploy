// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FrameDeploy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "FrameDeploy", path: "Sources/FrameDeploy")
    ]
)
