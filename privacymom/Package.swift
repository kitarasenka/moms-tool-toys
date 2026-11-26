// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PrivacyMom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PrivacyMom", path: "Sources/PrivacyMom")
    ]
)
