// swift-tools-version: 5.9
import PackageDescription

// Package-level name stays identifier-safe (`PreviewMD`) because it feeds the
// generated resource bundle name (`PreviewMD_MdReaderCore.bundle`). The
// user-facing product names use the hyphenated "Preview-MD".
let package = Package(
    name: "PreviewMD",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Preview-MD", targets: ["MdReader"]),
        .executable(name: "Preview-MD-QL", targets: ["MdReaderQL"]),
        .library(name: "MdReaderCore", targets: ["MdReaderCore"]),
    ],
    targets: [
        .target(
            name: "MdReaderCore",
            path: "Sources/MdReaderCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "MdReader",
            dependencies: ["MdReaderCore"],
            path: "Sources/MdReader"
        ),
        .executableTarget(
            name: "MdReaderQL",
            dependencies: ["MdReaderCore"],
            path: "Sources/MdReaderQL"
        ),
        .testTarget(
            name: "MdReaderCoreTests",
            dependencies: ["MdReaderCore"],
            path: "Tests/MdReaderCoreTests"
        ),
    ]
)
