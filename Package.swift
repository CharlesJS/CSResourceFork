// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CSResourceFork",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .macCatalyst(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "CSResourceFork",
            targets: ["CSResourceFork"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/CharlesJS/CSErrors", from: "1.2.9"),
        .package(url: "https://github.com/CharlesJS/DataParser", from: "0.3.3"),
        .package(url: "https://github.com/CharlesJS/HFSTypeConversion", from: "0.1.1"),
    ],
    targets: [
        .target(
            name: "CSResourceFork",
            dependencies: ["CSErrors", "DataParser", "HFSTypeConversion"]
        ),
        .testTarget(
            name: "CSResourceForkTests",
            dependencies: ["CSResourceFork"],
            resources: [
                .copy("fixtures")
            ]
        ),
    ]
)
