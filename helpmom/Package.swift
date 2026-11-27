// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HelpMom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HelpMom", path: "Sources/HelpMom")
    ]
)
