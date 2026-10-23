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
        // Univocal Connect: Swift SDK, conformant mock server, and its CLI.
        // `Sources/UnivocalClient` has no PreviewMD dependencies and is meant to
        // be extracted into its own package (see its README).
        .library(name: "UnivocalClient", targets: ["UnivocalClient"]),
        .library(name: "UnivocalMock", targets: ["UnivocalMock"]),
        .executable(name: "univocal-mock", targets: ["UnivocalMockCLI"]),
    ],
    targets: [
        .target(
            name: "MdReaderCore",
            path: "Sources/MdReaderCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "MdReader",
            dependencies: ["MdReaderCore", "UnivocalClient"],
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
        .target(
            name: "UnivocalClient",
            path: "Sources/UnivocalClient",
            exclude: ["README.md"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "UnivocalMock",
            dependencies: ["UnivocalClient"],
            path: "Sources/UnivocalMock",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "UnivocalMockCLI",
            dependencies: ["UnivocalMock", "UnivocalClient"],
            path: "Sources/UnivocalMockCLI"
        ),
        .testTarget(
            name: "UnivocalClientTests",
            dependencies: ["UnivocalClient", "UnivocalMock"],
            path: "Tests/UnivocalClientTests"
        ),
        // Read Aloud controller tests (app target, fake backend).
        .testTarget(
            name: "MdReaderTests",
            dependencies: ["MdReader", "UnivocalClient", "UnivocalMock"],
            path: "Tests/MdReaderTests"
        ),
    ]
)
