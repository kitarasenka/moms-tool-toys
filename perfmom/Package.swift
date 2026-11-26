// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PerfMom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PerfMom",
            path: "Sources/PerfMom",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security")]
        )
    ]
)
