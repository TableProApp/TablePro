// swift-tools-version: 6.0

import PackageDescription

// The app compiles this code under SWIFT_APPROACHABLE_CONCURRENCY and MemberImportVisibility.
let appModuleSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility")
]

// The Unit plan builds these tests with the app, so nothing here may depend on TableProPluginKit.
let package = Package(
    name: "TableProMacCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "TableProUtilities", targets: ["TableProUtilities"]),
        .library(name: "TableProSSHConfig", targets: ["TableProSSHConfig"]),
        .library(name: "TableProMCP", targets: ["TableProMCP"]),
        .library(name: "TableProMCPTestSupport", targets: ["TableProMCPTestSupport"])
    ],
    dependencies: [
        .package(path: "../TableProCore")
    ],
    targets: [
        .target(
            name: "TableProUtilities",
            dependencies: [
                .product(name: "TableProSQLGrammar", package: "TableProCore"),
                .product(name: "TableProTabularIO", package: "TableProCore")
            ],
            path: "Sources/TableProUtilities",
            swiftSettings: appModuleSettings
        ),
        .target(
            name: "TableProSSHConfig",
            dependencies: [
                "TableProUtilities",
                .product(name: "TableProLogRedaction", package: "TableProCore"),
                .product(name: "TableProSSHTransport", package: "TableProCore")
            ],
            path: "Sources/TableProSSHConfig",
            swiftSettings: appModuleSettings
        ),
        .target(
            name: "TableProMCP",
            dependencies: [
                "TableProUtilities",
                .product(name: "TableProLogRedaction", package: "TableProCore")
            ],
            path: "Sources/TableProMCP",
            swiftSettings: appModuleSettings
        ),
        .target(
            name: "TableProMCPTestSupport",
            dependencies: ["TableProMCP"],
            path: "Tests/TableProMCPTestSupport",
            swiftSettings: appModuleSettings
        ),
        .testTarget(
            name: "TableProUtilitiesTests",
            dependencies: [
                "TableProUtilities",
                .product(name: "TableProTestSupport", package: "TableProCore")
            ],
            path: "Tests/TableProUtilitiesTests",
            swiftSettings: appModuleSettings
        ),
        .testTarget(
            name: "TableProSSHConfigTests",
            dependencies: [
                "TableProSSHConfig",
                .product(name: "TableProTestSupport", package: "TableProCore")
            ],
            path: "Tests/TableProSSHConfigTests",
            swiftSettings: appModuleSettings
        ),
        .testTarget(
            name: "TableProMCPTests",
            dependencies: [
                "TableProMCP",
                "TableProMCPTestSupport",
                "TableProUtilities",
                .product(name: "TableProTestSupport", package: "TableProCore")
            ],
            path: "Tests/TableProMCPTests",
            swiftSettings: appModuleSettings
        )
    ]
)
