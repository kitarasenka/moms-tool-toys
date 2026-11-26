// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CleanerMom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CleanerMom", path: "Sources/CleanerMom")
    ]
)
