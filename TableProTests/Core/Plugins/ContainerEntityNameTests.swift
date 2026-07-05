//
//  ContainerEntityNameTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("Container entity name and switch target")
struct ContainerEntityNameTests {
    private func snapshot(forTypeId typeId: String) -> PluginMetadataSnapshot? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: typeId)
    }

    // MARK: - Container entity names

    @Test("BigQuery container is Dataset")
    func bigQueryContainerIsDataset() {
        #expect(PluginManager.shared.containerEntityName(for: .bigQuery) == "Dataset")
    }

    @Test("Cassandra and ScyllaDB containers are Keyspace")
    func cassandraFamilyContainerIsKeyspace() {
        #expect(PluginManager.shared.containerEntityName(for: .cassandra) == "Keyspace")
        #expect(PluginManager.shared.containerEntityName(for: .scylladb) == "Keyspace")
    }

    @Test("Relational engines keep Database as container")
    func relationalEnginesUseDatabase() {
        for type in [DatabaseType.mysql, .postgresql, .sqlite, .mssql, .clickhouse] {
            #expect(PluginManager.shared.containerEntityName(for: type) == "Database")
        }
    }

    @Test("Unknown type falls back to Database")
    func unknownTypeFallsBackToDatabase() {
        let unknown = DatabaseType(rawValue: "FuturePlugin")
        #expect(PluginManager.shared.containerEntityName(for: unknown) == "Database")
    }

    @Test("Plural form appends s")
    func pluralFormAppendsS() {
        #expect(PluginManager.shared.containerEntityNamePlural(for: .bigQuery) == "Datasets")
        #expect(PluginManager.shared.containerEntityNamePlural(for: .cassandra) == "Keyspaces")
        #expect(PluginManager.shared.containerEntityNamePlural(for: .mysql) == "Databases")
    }

    @Test("DriverPlugin defaults provide Database container")
    func driverPluginDefaultIsDatabase() {
        #expect(snapshot(forTypeId: "MySQL")?.schema.containerEntityName == "Database")
        #expect(PluginMetadataSnapshot.SchemaInfo.defaults.containerEntityName == "Database")
    }

    // MARK: - Container switch target

    @Test("Database-switching engines target databases")
    func databaseSwitchingEnginesTargetDatabases() {
        #expect(PluginManager.shared.containerSwitchTarget(for: .mysql) == .database)
        #expect(PluginManager.shared.containerSwitchTarget(for: .cassandra) == .database)
    }

    @Test("Schema-switching-only engines target schemas")
    func schemaOnlyEnginesTargetSchemas() {
        #expect(PluginManager.shared.containerSwitchTarget(for: .bigQuery) == .schema)
    }

    @Test("Oracle switches schemas, not databases")
    func oracleSwitchesSchemas() {
        #expect(PluginManager.shared.containerSwitchTarget(for: .oracle) == .schema)
        #expect(PluginManager.shared.supportsDatabaseSwitching(for: .oracle) == false)
        #expect(PluginManager.shared.supportsSchemaSwitching(for: .oracle) == true)
    }

    @Test("Oracle container is Schema with hierarchical grouping")
    func oracleContainerIsSchema() {
        #expect(PluginManager.shared.containerEntityName(for: .oracle) == "Schema")
        #expect(PluginManager.shared.databaseGroupingStrategy(for: .oracle) == .hierarchicalSchema)
        #expect(PluginManager.shared.supportsDatabaseTree(for: .oracle) == false)
        #expect(snapshot(forTypeId: "Oracle")?.schema.defaultSchemaName == "")
    }

    @Test("Engines supporting both prefer databases")
    func dualModeEnginesPreferDatabases() {
        #expect(PluginManager.shared.containerSwitchTarget(for: .postgresql) == .database)
    }

    @Test("Engines without switching have no target")
    func nonSwitchingEnginesHaveNoTarget() {
        #expect(PluginManager.shared.containerSwitchTarget(for: .redis) == nil)
        #expect(PluginManager.shared.supportsContainerSwitching(for: .redis) == false)
    }

    @Test("BigQuery supports container switching through schemas")
    func bigQuerySupportsContainerSwitching() {
        #expect(PluginManager.shared.supportsContainerSwitching(for: .bigQuery) == true)
    }
}
