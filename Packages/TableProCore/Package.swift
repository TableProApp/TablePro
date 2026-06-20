// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TableProCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "TableProCoreTypes", targets: ["TableProCoreTypes"]),
        .library(name: "TableProPluginKit", targets: ["TableProPluginKit"]),
        .library(name: "TableProModels", targets: ["TableProModels"]),
        .library(name: "TableProImport", targets: ["TableProImport"]),
        .library(name: "TableProDatabase", targets: ["TableProDatabase"]),
        .library(name: "TableProQuery", targets: ["TableProQuery"]),
        .library(name: "TableProSync", targets: ["TableProSync"]),
        .library(name: "TableProAnalytics", targets: ["TableProAnalytics"]),
        .library(name: "TableProMSSQLCore", targets: ["TableProMSSQLCore"])
    ],
    targets: [
        .target(
            name: "TableProCoreTypes",
            dependencies: [],
            path: "Sources/TableProCoreTypes"
        ),
        .target(
            name: "TableProPluginKit",
            dependencies: [],
            path: "Sources/TableProPluginKit",
            exclude: ["Info.plist"]
        ),
        .target(
            name: "TableProModels",
            dependencies: ["TableProPluginKit", "TableProCoreTypes"],
            path: "Sources/TableProModels"
        ),
        .target(
            name: "TableProImport",
            dependencies: [],
            path: "Sources/TableProImport"
        ),
        .target(
            name: "TableProDatabase",
            dependencies: ["TableProModels", "TableProCoreTypes"],
            path: "Sources/TableProDatabase"
        ),
        .target(
            name: "TableProQuery",
            dependencies: ["TableProModels", "TableProPluginKit", "TableProCoreTypes"],
            path: "Sources/TableProQuery"
        ),
        .target(
            name: "TableProSync",
            dependencies: ["TableProModels", "TableProCoreTypes"],
            path: "Sources/TableProSync"
        ),
        .target(
            name: "TableProAnalytics",
            dependencies: [],
            path: "Sources/TableProAnalytics"
        ),
        .target(
            name: "TableProMSSQLCore",
            dependencies: [],
            path: "Sources/TableProMSSQLCore"
        ),
        .testTarget(
            name: "TableProModelsTests",
            dependencies: ["TableProModels", "TableProPluginKit"],
            path: "Tests/TableProModelsTests"
        ),
        .testTarget(
            name: "TableProImportTests",
            dependencies: ["TableProImport"],
            path: "Tests/TableProImportTests"
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
        ),
        .testTarget(
            name: "TableProMSSQLCoreTests",
            dependencies: ["TableProMSSQLCore"],
            path: "Tests/TableProMSSQLCoreTests"
        ),
        .testTarget(
            name: "TableProSyncTests",
            dependencies: ["TableProSync", "TableProModels"],
            path: "Tests/TableProSyncTests"
        )
    ]
)
