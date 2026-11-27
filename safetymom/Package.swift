// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SafetyMom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SafetyMom", path: "Sources/SafetyMom", linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
