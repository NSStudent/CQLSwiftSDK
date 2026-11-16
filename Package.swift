// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CQLSwiftSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CQL", targets: ["CQL"]),
        .executable(name: "cql-swift", targets: ["cql-swift"]),
    ],
    dependencies: [
        .package(url: "https://github.com/NSStudent/fischer-core.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "CQL",
            dependencies: [
                .product(name: "FischerCore", package: "fischer-core"),
            ]
        ),
        .executableTarget(
            name: "cql-swift",
            dependencies: ["CQL"]
        ),
        .testTarget(
            name: "CQLTests",
            dependencies: ["CQL"],
            resources: [.copy("Resources")]
        ),
    ]
)
