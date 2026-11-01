// swift-tools-version: 6.0

import PackageDescription

// The plugins and the iOS app compile this code under SWIFT_APPROACHABLE_CONCURRENCY and MemberImportVisibility.
let pluginCoreSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "TableProCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "TableProCoreTypes", targets: ["TableProCoreTypes"]),
        .library(name: "TableProGeometry", targets: ["TableProGeometry"]),
        .library(name: "TableProTheme", targets: ["TableProTheme"]),
        .library(name: "TableProPluginKit", targets: ["TableProPluginKit"]),
        .library(name: "TableProModels", targets: ["TableProModels"]),
        .library(name: "TableProImport", targets: ["TableProImport"]),
        .library(name: "TableProDatabase", targets: ["TableProDatabase"]),
        .library(name: "TableProQuery", targets: ["TableProQuery"]),
        .library(name: "TableProSyncTransport", targets: ["TableProSyncTransport"]),
        .library(name: "TableProSync", targets: ["TableProSync"]),
        .library(name: "TableProAnalytics", targets: ["TableProAnalytics"]),
        .library(name: "TableProMSSQLCore", targets: ["TableProMSSQLCore"]),
        .library(name: "TableProKerberos", targets: ["TableProKerberos"]),
        .library(name: "TableProTeradataCore", targets: ["TableProTeradataCore"]),
        .library(name: "TableProTrinoCore", targets: ["TableProTrinoCore"]),
        .library(name: "TableProDamengCore", targets: ["TableProDamengCore"]),
        .library(name: "TableProTLSClientIdentity", targets: ["TableProTLSClientIdentity"]),
        .library(name: "TableProTLSTestFixtures", targets: ["TableProTLSTestFixtures"]),
        .library(name: "TableProGoogleCloud", targets: ["TableProGoogleCloud"]),
        .library(name: "TableProSpannerCore", targets: ["TableProSpannerCore"]),
        .library(name: "TableProWeaviateCore", targets: ["TableProWeaviateCore"]),
        .library(name: "TableProQdrantCore", targets: ["TableProQdrantCore"]),
        .library(name: "TableProInfluxDBCore", targets: ["TableProInfluxDBCore"]),
        .library(name: "TableProNeo4jCore", targets: ["TableProNeo4jCore"]),
        .library(name: "TableProFirebaseCore", targets: ["TableProFirebaseCore"]),
        .library(name: "TableProBigtableCore", targets: ["TableProBigtableCore"]),
        .library(name: "TableProNumberFormatting", targets: ["TableProNumberFormatting"]),
        .library(name: "TableProDocumentPath", targets: ["TableProDocumentPath"]),
        .library(name: "TableProJavaScriptText", targets: ["TableProJavaScriptText"]),
        .library(name: "TableProLogRedaction", targets: ["TableProLogRedaction"]),
        .library(name: "TableProR2SQLCore", targets: ["TableProR2SQLCore"]),
        .library(name: "TableProConnectionLibrary", targets: ["TableProConnectionLibrary"]),
        .library(name: "TableProSQLGrammar", targets: ["TableProSQLGrammar"]),
        .library(name: "TableProSQLVocabulary", targets: ["TableProSQLVocabulary"]),
        .library(name: "TableProAutocomplete", targets: ["TableProAutocomplete"]),
        .library(name: "TableProSSHTransport", targets: ["TableProSSHTransport"]),
        .library(name: "CSQLite", targets: ["CSQLite"]),
        .library(name: "TableProSQLiteCore", targets: ["TableProSQLiteCore"]),
        .library(name: "TableProTabularIO", targets: ["TableProTabularIO"]),
        .library(name: "TableProTabular", targets: ["TableProTabular"]),
        .library(name: "TableProMySQLCore", targets: ["TableProMySQLCore"]),
        .library(name: "TableProPostgreSQLCore", targets: ["TableProPostgreSQLCore"]),
        .library(name: "TableProRedisCore", targets: ["TableProRedisCore"]),
        .library(name: "TableProMemcachedCore", targets: ["TableProMemcachedCore"]),
        .library(name: "TableProTestSupport", targets: ["TableProTestSupport"])
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
            name: "TableProJavaScriptText",
            dependencies: [],
            path: "Sources/TableProJavaScriptText"
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
            name: "TableProTheme",
            dependencies: [],
            path: "Sources/TableProTheme"
        ),
        .target(
            name: "TableProPluginKit",
            dependencies: [],
            path: "Sources/TableProPluginKit"
        ),
        .target(
            name: "TableProModels",
            dependencies: ["TableProPluginKit", "TableProCoreTypes", "TableProSSHTransport"],
            path: "Sources/TableProModels"
        ),
        .target(
            name: "TableProImport",
            dependencies: ["TableProConnectionLibrary", "TableProSSHTransport"],
            path: "Sources/TableProImport"
        ),
        .target(
            name: "TableProDatabase",
            dependencies: ["TableProModels", "TableProCoreTypes", "TableProPluginKit", "TableProSQLGrammar", "TableProSSHTransport"],
            path: "Sources/TableProDatabase"
        ),
        .target(
            name: "TableProQuery",
            dependencies: [
                "TableProModels", "TableProPluginKit", "TableProCoreTypes", "TableProSQLGrammar", "TableProRedisCore"
            ],
            path: "Sources/TableProQuery"
        ),
        .target(
            name: "TableProSyncTransport",
            dependencies: [],
            path: "Sources/TableProSyncTransport"
        ),
        .target(
            name: "TableProSync",
            dependencies: ["TableProSyncTransport", "TableProModels", "TableProCoreTypes", "TableProConnectionLibrary"],
            path: "Sources/TableProSync"
        ),
        .target(
            name: "TableProAnalytics",
            dependencies: [],
            path: "Sources/TableProAnalytics"
        ),
        .target(
            name: "TableProMSSQLCore",
            dependencies: ["TableProCoreTypes", "TableProSQLGrammar"],
            path: "Sources/TableProMSSQLCore"
        ),
        .target(
            name: "TableProKerberos",
            dependencies: ["TableProCoreTypes"],
            path: "Sources/TableProKerberos"
        ),
        .target(
            name: "TableProTeradataCore",
            dependencies: [],
            path: "Sources/TableProTeradataCore"
        ),
        .target(
            name: "TableProTrinoCore",
            dependencies: ["TableProSQLGrammar", "TableProTLSClientIdentity"],
            path: "Sources/TableProTrinoCore"
        ),
        .target(
            name: "TableProDamengCore",
            dependencies: ["TableProSQLGrammar"],
            path: "Sources/TableProDamengCore",
            swiftSettings: pluginCoreSettings
        ),
        .target(
            name: "TableProTLSClientIdentity",
            dependencies: [],
            path: "Sources/TableProTLSClientIdentity"
        ),
        .target(
            name: "TableProTLSTestFixtures",
            dependencies: [],
            path: "Tests/TableProTLSTestFixtures"
        ),
        .target(
            name: "TableProTestSupport",
            dependencies: [],
            path: "Tests/TableProTestSupport"
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
            name: "TableProQdrantCore",
            dependencies: [],
            path: "Sources/TableProQdrantCore",
            swiftSettings: pluginCoreSettings
        ),
        .target(
            name: "TableProInfluxDBCore",
            dependencies: [],
            path: "Sources/TableProInfluxDBCore"
        ),
        .target(
            name: "TableProNeo4jCore",
            dependencies: [],
            path: "Sources/TableProNeo4jCore"
        ),
        .target(
            name: "TableProBigtableCore",
            dependencies: ["TableProGoogleCloud"],
            path: "Sources/TableProBigtableCore"
        ),
        .target(
            name: "TableProFirebaseCore",
            dependencies: ["TableProGoogleCloud"],
            path: "Sources/TableProFirebaseCore"
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
        // Linked by the macOS app, six plugin bundles and the iOS app, so never TableProPluginKit.
        .target(
            name: "TableProSQLVocabulary",
            dependencies: [],
            path: "Sources/TableProSQLVocabulary",
            swiftSettings: pluginCoreSettings
        ),
        // The macOS app links it, so never TableProPluginKit.
        .target(
            name: "TableProAutocomplete",
            dependencies: ["TableProSQLGrammar", "TableProSQLVocabulary"],
            path: "Sources/TableProAutocomplete",
            swiftSettings: pluginCoreSettings
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
            dependencies: ["TableProTabularIO", "TableProNumberFormatting"],
            path: "Sources/TableProTabular"
        ),
        .target(
            name: "TableProSQLiteCore",
            dependencies: ["CSQLite"],
            path: "Sources/TableProSQLiteCore"
        ),
        // Linked by a plugin bundle, so never TableProPluginKit: the plugin would carry its own copy of PluginKit's types.
        .target(
            name: "TableProMySQLCore",
            dependencies: ["TableProGeometry"],
            path: "Sources/TableProMySQLCore",
            swiftSettings: pluginCoreSettings
        ),
        .target(
            name: "TableProPostgreSQLCore",
            dependencies: [],
            path: "Sources/TableProPostgreSQLCore",
            swiftSettings: pluginCoreSettings
        ),
        .target(
            name: "TableProMemcachedCore",
            dependencies: [],
            path: "Sources/TableProMemcachedCore",
            swiftSettings: pluginCoreSettings
        ),
        .target(
            name: "TableProRedisCore",
            dependencies: [],
            path: "Sources/TableProRedisCore",
            swiftSettings: pluginCoreSettings
        ),
        .testTarget(
            name: "TableProBigtableCoreTests",
            dependencies: ["TableProBigtableCore", "TableProGoogleCloud"],
            path: "Tests/TableProBigtableCoreTests"
        ),
        .testTarget(
            name: "TableProNeo4jCoreTests",
            dependencies: ["TableProNeo4jCore"],
            path: "Tests/TableProNeo4jCoreTests"
        ),
        .testTarget(
            name: "TableProFirebaseCoreTests",
            dependencies: ["TableProFirebaseCore"],
            path: "Tests/TableProFirebaseCoreTests"
        ),
        .testTarget(
            name: "TableProSpannerCoreTests",
            dependencies: ["TableProSpannerCore"],
            path: "Tests/TableProSpannerCoreTests"
        ),
        .testTarget(
            name: "TableProTeradataCoreTests",
            dependencies: ["TableProTeradataCore"],
            path: "Tests/TableProTeradataCoreTests"
        ),
        .testTarget(
            name: "TableProQdrantCoreTests",
            dependencies: ["TableProQdrantCore"],
            path: "Tests/TableProQdrantCoreTests",
            swiftSettings: pluginCoreSettings
        ),
        .testTarget(
            name: "TableProInfluxDBCoreTests",
            dependencies: ["TableProInfluxDBCore"],
            path: "Tests/TableProInfluxDBCoreTests"
        ),
        .testTarget(
            name: "TableProTrinoCoreTests",
            dependencies: ["TableProTrinoCore", "TableProSQLGrammar"],
            path: "Tests/TableProTrinoCoreTests"
        ),
        .testTarget(
            name: "TableProDamengCoreTests",
            dependencies: ["TableProDamengCore", "TableProSQLGrammar"],
            path: "Tests/TableProDamengCoreTests",
            swiftSettings: pluginCoreSettings
        ),
        .testTarget(
            name: "TableProTabularIOTests",
            dependencies: ["TableProTabularIO", "TableProPluginKit"],
            path: "Tests/TableProTabularIOTests"
        ),
        .testTarget(
            name: "TableProTabularTests",
            dependencies: ["TableProTabular", "TableProTabularIO", "TableProNumberFormatting"],
            path: "Tests/TableProTabularTests"
        ),
        .testTarget(
            name: "TableProConnectionLibraryTests",
            dependencies: ["TableProConnectionLibrary"],
            path: "Tests/TableProConnectionLibraryTests"
        ),
        .testTarget(
            name: "TableProCoreTypesTests",
            dependencies: ["TableProCoreTypes", "TableProTestSupport"],
            path: "Tests/TableProCoreTypesTests"
        ),
        .testTarget(
            name: "TableProSSHTransportTests",
            dependencies: ["TableProSSHTransport", "TableProTestSupport"],
            path: "Tests/TableProSSHTransportTests"
        ),
        .testTarget(
            name: "TableProGeometryTests",
            dependencies: ["TableProGeometry"],
            path: "Tests/TableProGeometryTests"
        ),
        .testTarget(
            name: "TableProThemeTests",
            dependencies: ["TableProTheme"],
            path: "Tests/TableProThemeTests"
        ),
        .testTarget(
            name: "TableProNumberFormattingTests",
            dependencies: ["TableProNumberFormatting"],
            path: "Tests/TableProNumberFormattingTests"
        ),
        .testTarget(
            name: "TableProJavaScriptTextTests",
            dependencies: ["TableProJavaScriptText"],
            path: "Tests/TableProJavaScriptTextTests"
        ),
        .testTarget(
            name: "TableProLogRedactionTests",
            dependencies: ["TableProLogRedaction"],
            path: "Tests/TableProLogRedactionTests"
        ),
        .testTarget(
            name: "TableProModelsTests",
            dependencies: ["TableProModels", "TableProPluginKit", "TableProSSHTransport"],
            path: "Tests/TableProModelsTests"
        ),
        .testTarget(
            name: "TableProImportTests",
            dependencies: ["TableProImport"],
            path: "Tests/TableProImportTests"
        ),
        .testTarget(
            name: "TableProDatabaseTests",
            dependencies: ["TableProDatabase", "TableProModels", "TableProPluginKit", "TableProSSHTransport", "TableProTestSupport"],
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
            name: "TableProSQLVocabularyTests",
            dependencies: ["TableProSQLVocabulary", "TableProPluginKit"],
            path: "Tests/TableProSQLVocabularyTests",
            swiftSettings: pluginCoreSettings
        ),
        .testTarget(
            name: "TableProAutocompleteTests",
            dependencies: ["TableProAutocomplete", "TableProSQLGrammar"],
            path: "Tests/TableProAutocompleteTests",
            swiftSettings: pluginCoreSettings
        ),
        .testTarget(
            name: "TableProAnalyticsTests",
            dependencies: ["TableProAnalytics"],
            path: "Tests/TableProAnalyticsTests"
        ),
        .testTarget(
            name: "TableProMSSQLCoreTests",
            dependencies: ["TableProMSSQLCore", "TableProTestSupport"],
            path: "Tests/TableProMSSQLCoreTests"
        ),
        .testTarget(
            name: "TableProKerberosTests",
            dependencies: ["TableProKerberos"],
            path: "Tests/TableProKerberosTests"
        ),
        .testTarget(
            name: "TableProTLSClientIdentityTests",
            dependencies: ["TableProTLSClientIdentity", "TableProTLSTestFixtures"],
            path: "Tests/TableProTLSClientIdentityTests"
        ),
        .testTarget(
            name: "TableProGoogleCloudTests",
            dependencies: ["TableProGoogleCloud", "TableProTestSupport"],
            path: "Tests/TableProGoogleCloudTests"
        ),
        .testTarget(
            name: "TableProSyncTests",
            dependencies: ["TableProSync", "TableProSyncTransport", "TableProModels", "TableProSSHTransport"],
            path: "Tests/TableProSyncTests"
        ),
        .testTarget(
            name: "TableProPluginKitTests",
            dependencies: ["TableProPluginKit"],
            path: "Tests/TableProPluginKitTests"
        ),
        .testTarget(
            name: "TableProMySQLCoreTests",
            dependencies: ["TableProMySQLCore"],
            path: "Tests/TableProMySQLCoreTests",
            swiftSettings: pluginCoreSettings
        ),
        .testTarget(
            name: "TableProPostgreSQLCoreTests",
            dependencies: ["TableProPostgreSQLCore"],
            path: "Tests/TableProPostgreSQLCoreTests",
            swiftSettings: pluginCoreSettings
        ),
        .testTarget(
            name: "TableProMemcachedCoreTests",
            dependencies: ["TableProMemcachedCore"],
            path: "Tests/TableProMemcachedCoreTests",
            swiftSettings: pluginCoreSettings
        ),
        .testTarget(
            name: "TableProRedisCoreTests",
            dependencies: ["TableProRedisCore"],
            path: "Tests/TableProRedisCoreTests",
            swiftSettings: pluginCoreSettings
        )
    ]
)
