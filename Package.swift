// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MdReader",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MdReader",
            path: "Sources/MdReader",
            resources: [.process("Resources")]
        )
    ]
)
