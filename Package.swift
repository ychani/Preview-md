// swift-tools-version: 5.9
import PackageDescription

// The package name feeds the generated resource bundle name
// (`PreviewMD_MdReaderCore.bundle`), which MdReaderResources looks up by name —
// keep the two in sync. Product names are the user-facing executable names
// (`PreviewMD`, `PreviewMD-QL`); target/module names stay `MdReader*` because
// Swift code imports them.
let package = Package(
    name: "PreviewMD",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PreviewMD", targets: ["MdReader"]),
        .executable(name: "PreviewMD-QL", targets: ["MdReaderQL"]),
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
