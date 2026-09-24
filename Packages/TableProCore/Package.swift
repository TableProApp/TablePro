// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TableProCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "TableProCoreTypes", targets: ["TableProCoreTypes"]),
        .library(name: "TableProGeometry", targets: ["TableProGeometry"]),
        .library(name: "TableProPluginKit", targets: ["TableProPluginKit"]),
        .library(name: "TableProModels", targets: ["TableProModels"]),
        .library(name: "TableProImport", targets: ["TableProImport"]),
        .library(name: "TableProDatabase", targets: ["TableProDatabase"]),
        .library(name: "TableProQuery", targets: ["TableProQuery"]),
        .library(name: "TableProSyncTransport", targets: ["TableProSyncTransport"]),
        .library(name: "TableProSync", targets: ["TableProSync"]),
        .library(name: "TableProAnalytics", targets: ["TableProAnalytics"]),
        .library(name: "TableProMSSQLCore", targets: ["TableProMSSQLCore"]),
        .library(name: "TableProTeradataCore", targets: ["TableProTeradataCore"]),
        .library(name: "TableProTrinoCore", targets: ["TableProTrinoCore"]),
        .library(name: "TableProGoogleCloud", targets: ["TableProGoogleCloud"]),
        .library(name: "TableProSpannerCore", targets: ["TableProSpannerCore"]),
        .library(name: "TableProWeaviateCore", targets: ["TableProWeaviateCore"]),
        .library(name: "TableProNumberFormatting", targets: ["TableProNumberFormatting"]),
        .library(name: "TableProDocumentPath", targets: ["TableProDocumentPath"]),
        .library(name: "TableProLogRedaction", targets: ["TableProLogRedaction"]),
        .library(name: "TableProR2SQLCore", targets: ["TableProR2SQLCore"]),
        .library(name: "TableProConnectionLibrary", targets: ["TableProConnectionLibrary"]),
        .library(name: "TableProSQLGrammar", targets: ["TableProSQLGrammar"]),
        .library(name: "TableProSSHTransport", targets: ["TableProSSHTransport"]),
        .library(name: "CSQLite", targets: ["CSQLite"]),
        .library(name: "TableProSQLiteCore", targets: ["TableProSQLiteCore"]),
        .library(name: "TableProTabularIO", targets: ["TableProTabularIO"]),
        .library(name: "TableProTabular", targets: ["TableProTabular"])
    ],
    targets: [
        .target(
            name: "TableProNumberFormatting",
            dependencies: [],
            path: "Sources/TableProNumberFormatting"
        ),
        .target(
            name: "TableProDocumentPath",
            dependencies: [],
            path: "Sources/TableProDocumentPath"
        ),
        .target(
            name: "TableProLogRedaction",
            dependencies: [],
            path: "Sources/TableProLogRedaction"
        ),
        .target(
            name: "TableProCoreTypes",
            dependencies: [],
            path: "Sources/TableProCoreTypes"
        ),
        .target(
            name: "TableProGeometry",
            dependencies: [],
            path: "Sources/TableProGeometry"
        ),
        .target(
            name: "TableProPluginKit",
            dependencies: [],
            path: "Sources/TableProPluginKit"
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
            dependencies: ["TableProModels", "TableProCoreTypes", "TableProPluginKit"],
            path: "Sources/TableProDatabase"
        ),
        .target(
            name: "TableProQuery",
            dependencies: ["TableProModels", "TableProPluginKit", "TableProCoreTypes", "TableProSQLGrammar"],
            path: "Sources/TableProQuery"
        ),
        .target(
            name: "TableProSyncTransport",
            dependencies: [],
            path: "Sources/TableProSyncTransport"
        ),
        .target(
            name: "TableProSync",
            dependencies: ["TableProSyncTransport", "TableProModels", "TableProCoreTypes"],
            path: "Sources/TableProSync"
        ),
        .target(
            name: "TableProAnalytics",
            dependencies: [],
            path: "Sources/TableProAnalytics"
        ),
        .target(
            name: "TableProMSSQLCore",
            dependencies: ["TableProCoreTypes"],
            path: "Sources/TableProMSSQLCore"
        ),
        .target(
            name: "TableProTeradataCore",
            dependencies: [],
            path: "Sources/TableProTeradataCore"
        ),
        .target(
            name: "TableProTrinoCore",
            dependencies: [],
            path: "Sources/TableProTrinoCore"
        ),
        .target(
            name: "TableProGoogleCloud",
            dependencies: [],
            path: "Sources/TableProGoogleCloud"
        ),
        .target(
            name: "TableProSpannerCore",
            dependencies: ["TableProGoogleCloud"],
            path: "Sources/TableProSpannerCore"
        ),
        .target(
            name: "TableProWeaviateCore",
            dependencies: [],
            path: "Sources/TableProWeaviateCore"
        ),
        .target(
            name: "TableProR2SQLCore",
            dependencies: [],
            path: "Sources/TableProR2SQLCore"
        ),
        .target(
            name: "TableProConnectionLibrary",
            dependencies: [],
            path: "Sources/TableProConnectionLibrary"
        ),
        .target(
            name: "TableProSQLGrammar",
            dependencies: [],
            path: "Sources/TableProSQLGrammar"
        ),
        .target(
            name: "TableProSSHTransport",
            dependencies: [],
            path: "Sources/TableProSSHTransport"
        ),
        .target(
            name: "CSQLite",
            dependencies: [],
            path: "Sources/CSQLite"
        ),
        .target(
            name: "TableProTabularIO",
            dependencies: [],
            path: "Sources/TableProTabularIO"
        ),
        .target(
            name: "TableProTabular",
            dependencies: ["TableProTabularIO"],
            path: "Sources/TableProTabular"
        ),
        .target(
            name: "TableProSQLiteCore",
            dependencies: ["CSQLite"],
            path: "Sources/TableProSQLiteCore"
        ),
        .testTarget(
            name: "TableProTabularIOTests",
            dependencies: ["TableProTabularIO", "TableProPluginKit"],
            path: "Tests/TableProTabularIOTests"
        ),
        .testTarget(
            name: "TableProTabularTests",
            dependencies: ["TableProTabular", "TableProTabularIO"],
            path: "Tests/TableProTabularTests"
        ),
        .testTarget(
            name: "TableProConnectionLibraryTests",
            dependencies: ["TableProConnectionLibrary"],
            path: "Tests/TableProConnectionLibraryTests"
        ),
        .testTarget(
            name: "TableProCoreTypesTests",
            dependencies: ["TableProCoreTypes"],
            path: "Tests/TableProCoreTypesTests"
        ),
        .testTarget(
            name: "TableProSSHTransportTests",
            dependencies: ["TableProSSHTransport"],
            path: "Tests/TableProSSHTransportTests"
        ),
        .testTarget(
            name: "TableProGeometryTests",
            dependencies: ["TableProGeometry"],
            path: "Tests/TableProGeometryTests"
        ),
        .testTarget(
            name: "TableProNumberFormattingTests",
            dependencies: ["TableProNumberFormatting"],
            path: "Tests/TableProNumberFormattingTests"
        ),
        .testTarget(
            name: "TableProDocumentPathTests",
            dependencies: ["TableProDocumentPath"],
            path: "Tests/TableProDocumentPathTests"
        ),
        .testTarget(
            name: "TableProLogRedactionTests",
            dependencies: ["TableProLogRedaction"],
            path: "Tests/TableProLogRedactionTests"
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
            dependencies: ["TableProDatabase", "TableProModels", "TableProPluginKit"],
            path: "Tests/TableProDatabaseTests"
        ),
        .testTarget(
            name: "TableProQueryTests",
            dependencies: ["TableProQuery", "TableProModels", "TableProPluginKit"],
            path: "Tests/TableProQueryTests"
        ),
        .testTarget(
            name: "TableProSQLGrammarTests",
            dependencies: ["TableProSQLGrammar"],
            path: "Tests/TableProSQLGrammarTests"
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
            name: "TableProTeradataCoreTests",
            dependencies: ["TableProTeradataCore"],
            path: "Tests/TableProTeradataCoreTests"
        ),
        .testTarget(
            name: "TableProTrinoCoreTests",
            dependencies: ["TableProTrinoCore"],
            path: "Tests/TableProTrinoCoreTests"
        ),
        .testTarget(
            name: "TableProGoogleCloudTests",
            dependencies: ["TableProGoogleCloud"],
            path: "Tests/TableProGoogleCloudTests"
        ),
        .testTarget(
            name: "TableProSpannerCoreTests",
            dependencies: ["TableProSpannerCore", "TableProGoogleCloud"],
            path: "Tests/TableProSpannerCoreTests"
        ),
        .testTarget(
            name: "TableProWeaviateCoreTests",
            dependencies: ["TableProWeaviateCore"],
            path: "Tests/TableProWeaviateCoreTests"
        ),
        .testTarget(
            name: "TableProR2SQLCoreTests",
            dependencies: ["TableProR2SQLCore"],
            path: "Tests/TableProR2SQLCoreTests"
        ),
        .testTarget(
            name: "TableProSyncTests",
            dependencies: ["TableProSync", "TableProSyncTransport", "TableProModels"],
            path: "Tests/TableProSyncTests"
        ),
        .testTarget(
            name: "TableProPluginKitTests",
            dependencies: ["TableProPluginKit"],
            path: "Tests/TableProPluginKitTests"
        )
    ]
)
