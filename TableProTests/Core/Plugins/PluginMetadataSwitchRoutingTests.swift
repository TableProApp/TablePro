//
//  PluginMetadataSwitchRoutingTests.swift
//  TableProTests
//
//  A plugin built before its engine moved to schema-only switching still
//  declares two-tier routing; the registry must detect that and apply the
//  app's switch-routing fields instead.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("Plugin metadata switch-routing normalization")
struct PluginMetadataSwitchRoutingTests {
    private var oracleDefault: PluginMetadataSnapshot? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: DatabaseType.oracle.pluginTypeId)
    }

    private var legacyTwoTier: PluginMetadataSnapshot? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: DatabaseType.mssql.pluginTypeId)
    }

    @Test("legacy two-tier declarations on a schema-only engine are detected")
    func legacyDeclarationIsDetected() throws {
        let oracle = try #require(oracleDefault)
        let legacy = try #require(legacyTwoTier)

        #expect(PluginMetadataRegistry.declaresLegacySchemaOnlyRouting(legacy, registryDefault: oracle))
        #expect(!PluginMetadataRegistry.declaresLegacySchemaOnlyRouting(oracle, registryDefault: oracle))
        #expect(!PluginMetadataRegistry.declaresLegacySchemaOnlyRouting(legacy, registryDefault: legacy))
    }

    @Test("withSwitchRouting carries over only the routing fields")
    func switchRoutingCarriesRoutingFields() throws {
        let oracle = try #require(oracleDefault)
        let legacy = try #require(legacyTwoTier)

        let normalized = legacy.withSwitchRouting(from: oracle)

        #expect(normalized.supportsDatabaseSwitching == false)
        #expect(normalized.schema.databaseGroupingStrategy == .hierarchicalSchema)
        #expect(normalized.schema.defaultSchemaName.isEmpty)
        #expect(normalized.schema.containerEntityName == "Schema")
        #expect(normalized.displayName == legacy.displayName)
        #expect(normalized.schema.tableEntityName == legacy.schema.tableEntityName)
        #expect(normalized.capabilities.supportsSchemaSwitching == legacy.capabilities.supportsSchemaSwitching)
    }
}
