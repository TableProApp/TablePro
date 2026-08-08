// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TableProOracle",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "TableProOracleCore", targets: ["TableProOracleCore"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/TableProApp/oracle-nio",
            revision: "23c77812ed90259243a761d7fdea19db47d3ca41"
        ),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4")
    ],
    targets: [
        .target(
            name: "TableProOracleCore",
            dependencies: [
                .product(name: "OracleNIO", package: "oracle-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/TableProOracleCore"
        ),
        .testTarget(
            name: "TableProOracleCoreTests",
            dependencies: ["TableProOracleCore"],
            path: "Tests/TableProOracleCoreTests"
        )
    ]
)
