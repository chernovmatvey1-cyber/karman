// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Karman",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Karman", path: "Sources/Karman")
    ]
)
