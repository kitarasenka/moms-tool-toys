// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "KeyMom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "KeyMom", path: "Sources/KeyMom")
    ]
)
