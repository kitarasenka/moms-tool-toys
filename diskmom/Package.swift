// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DiskMom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DiskMom", path: "Sources/DiskMom")
    ]
)
