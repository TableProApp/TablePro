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
        .library(name: "TableProMCPTestSupport", targets: ["TableProMCPTestSupport"]),
        .library(name: "TableProCloudAPI", targets: ["TableProCloudAPI"])
    ],
    dependencies: [
        .package(path: "../TableProCore"),
        // Exact: the versions clients.md (macOS, Dependencies) names.
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.1"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.4.0")
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
        // openapi.json is a copy of tablepro-cloud's api/v2.json; scripts/update-cloud-api.sh refreshes it.
        .target(
            name: "TableProCloudAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession")
            ],
            path: "Sources/TableProCloudAPI",
            swiftSettings: appModuleSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
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
