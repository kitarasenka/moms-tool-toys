// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PerfMon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PerfMon",
            path: "Sources/PerfMon",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security")]
        )
    ]
)
