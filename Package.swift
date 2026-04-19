// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MdReader",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MdReader", targets: ["MdReader"]),
        .executable(name: "MdReaderQL", targets: ["MdReaderQL"]),
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
    ]
)
