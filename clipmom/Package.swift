// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClipMom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClipMom", path: "Sources/ClipMom")
    ]
)
