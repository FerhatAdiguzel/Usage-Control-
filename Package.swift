// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageMonitor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "UsageMonitor",
            path: "Sources/UsageMonitor"
        )
    ]
)
