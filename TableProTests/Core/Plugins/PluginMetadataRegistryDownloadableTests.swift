//
//  PluginMetadataRegistryDownloadableTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("PluginMetadataRegistry isDownloadable preservation")
struct PluginMetadataRegistryDownloadableTests {
    @Test("register preserves isDownloadable from registry default for downloadable types")
    func registerPreservesDownloadable() {
        let registry = PluginMetadataRegistry.shared
        guard let original = registry.snapshot(forTypeId: "SQL Server") else {
            Issue.record("Registry default for SQL Server missing")
            return
        }
        #expect(original.isDownloadable == true)

        let pluginSnapshot = original.withIsDownloadable(false)
        registry.register(snapshot: pluginSnapshot, forTypeId: "SQL Server", preserveIcon: true)

        let resolved = registry.snapshot(forTypeId: "SQL Server")
        #expect(resolved?.isDownloadable == true)

        registry.register(snapshot: original, forTypeId: "SQL Server", preserveIcon: true)
    }

    @Test("unregister restores registry default for downloadable types")
    func unregisterRestoresDefault() {
        let registry = PluginMetadataRegistry.shared
        guard let original = registry.snapshot(forTypeId: "SQL Server") else {
            Issue.record("Registry default for SQL Server missing")
            return
        }

        registry.unregister(typeId: "SQL Server")

        let restored = registry.snapshot(forTypeId: "SQL Server")
        #expect(restored != nil)
        #expect(restored?.isDownloadable == true)
        #expect(restored?.displayName == original.displayName)
        #expect(registry.typeId(forUrlScheme: "sqlserver") == "SQL Server")
    }

    @Test("unregister removes snapshot for non-default types")
    func unregisterRemovesNonDefaultTypes() {
        let registry = PluginMetadataRegistry.shared
        let typeId = "TestThirdPartyDB"
        guard registry.snapshot(forTypeId: typeId) == nil else {
            Issue.record("Test type \(typeId) unexpectedly in registry defaults")
            return
        }

        let snapshot = PluginMetadataSnapshot(
            displayName: typeId, iconName: "cylinder.fill", defaultPort: 1_234,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "thirdparty", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: false, urlSchemes: ["thirdparty"], postConnectActions: [],
            brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            supportsColumnReorder: false,
            capabilities: .defaults, schema: .defaults, editor: .defaults, connection: .defaults
        )
        registry.register(snapshot: snapshot, forTypeId: typeId)
        #expect(registry.snapshot(forTypeId: typeId) != nil)

        registry.unregister(typeId: typeId)

        #expect(registry.snapshot(forTypeId: typeId) == nil)
        #expect(registry.typeId(forUrlScheme: "thirdparty") == nil)
    }

    @Test("isDownloadablePlugin stays true for SQL Server after plugin uninstall")
    func isDownloadablePluginStaysTrueAfterUninstall() {
        let registry = PluginMetadataRegistry.shared
        guard registry.snapshot(forTypeId: "SQL Server") != nil else {
            Issue.record("Registry default for SQL Server missing")
            return
        }

        registry.unregister(typeId: "SQL Server")

        let mssql = DatabaseType.mssql
        #expect(mssql.isDownloadablePlugin == true)
    }
}
