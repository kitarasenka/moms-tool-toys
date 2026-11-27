// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DesktopMom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DesktopMom", path: "Sources/DesktopMom")
    ]
)
