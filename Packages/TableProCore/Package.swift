// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TableProCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "TableProPluginKit", targets: ["TableProPluginKit"]),
        .library(name: "TableProModels", targets: ["TableProModels"]),
        .library(name: "TableProDatabase", targets: ["TableProDatabase"]),
        .library(name: "TableProQuery", targets: ["TableProQuery"]),
        .library(name: "TableProSync", targets: ["TableProSync"]),
        .library(name: "TableProAnalytics", targets: ["TableProAnalytics"])
    ],
    targets: [
        .target(
            name: "TableProPluginKit",
            dependencies: [],
            path: "Sources/TableProPluginKit"
        ),
        .target(
            name: "TableProModels",
            dependencies: ["TableProPluginKit"],
            path: "Sources/TableProModels"
        ),
        .target(
            name: "TableProDatabase",
            dependencies: ["TableProModels"],
            path: "Sources/TableProDatabase"
        ),
        .target(
            name: "TableProQuery",
            dependencies: ["TableProModels", "TableProPluginKit"],
            path: "Sources/TableProQuery"
        ),
        .target(
            name: "TableProSync",
            dependencies: ["TableProModels"],
            path: "Sources/TableProSync"
        ),
        .target(
            name: "TableProAnalytics",
            dependencies: [],
            path: "Sources/TableProAnalytics"
        ),
        .testTarget(
            name: "TableProModelsTests",
            dependencies: ["TableProModels", "TableProPluginKit"],
            path: "Tests/TableProModelsTests"
        ),
        .testTarget(
            name: "TableProDatabaseTests",
            dependencies: ["TableProDatabase", "TableProModels"],
            path: "Tests/TableProDatabaseTests"
        ),
        .testTarget(
            name: "TableProQueryTests",
            dependencies: ["TableProQuery", "TableProModels", "TableProPluginKit"],
            path: "Tests/TableProQueryTests"
        ),
        .testTarget(
            name: "TableProAnalyticsTests",
            dependencies: ["TableProAnalytics"],
            path: "Tests/TableProAnalyticsTests"
        )
    ]
)
