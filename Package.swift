// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickInstall",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "QuickInstall",
            path: "Sources/QuickInstall"
        )
    ]
)
