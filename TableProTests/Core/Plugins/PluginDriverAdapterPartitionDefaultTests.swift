//
//  PluginDriverAdapterPartitionDefaultTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class PartitionUnawareDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

/// Answers the older requirement alone, the way every plugin built before `fetchPartitionDetails`
/// existed does. The protocol default is what has to bridge it.
private final class LegacyPartitionDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }

    func fetchPartitions(table: String, schema: String?) async throws -> [PluginTableInfo] {
        [
            PluginTableInfo(name: "orders_2024", type: "TABLE", rowCount: 12, schema: "archive", comment: nil),
            PluginTableInfo(name: "orders_2025", type: "PARTITIONED TABLE", schema: "public", comment: nil),
            PluginTableInfo(name: "topic-0", type: "partition", comment: nil),
            PluginTableInfo(name: "orders_remote", type: "foreign_table", schema: "public", comment: nil)
        ]
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

@Suite("Partition support stays optional for plugins")
struct PluginDriverAdapterPartitionDefaultTests {
    @Test("A driver that implements neither partition method resolves through the protocol default")
    func unimplementedFetchPartitionsReturnsEmpty() async throws {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: PartitionUnawareDriver())
        let partitions = try await adapter.fetchPartitionDetails(table: "orders", schema: "public")
        #expect(partitions.isEmpty)
    }

    @Test("A plugin built before fetchPartitionDetails existed still answers through the bridge")
    func legacyDriverBridgesToDetails() async throws {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: LegacyPartitionDriver())
        let partitions = try await adapter.fetchPartitionDetails(table: "orders", schema: "public")

        #expect(partitions.map(\.name) == ["orders_2024", "orders_2025", "topic-0", "orders_remote"])
        #expect(partitions.first?.schema == "archive")
        #expect(partitions.first?.rowCount == 12)
        #expect(partitions.first?.bound == nil)
        #expect(partitions[1].isSubpartitioned)
    }

    /// The Kafka driver answers the old requirement with broker partitions typed `partition`.
    /// Calling one a relation would offer to open and drop a name no server accepts.
    @Test("The bridge reads the declared type rather than assuming every row is a relation")
    func bridgeRefusesToCallABrokerPartitionARelation() async throws {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: LegacyPartitionDriver())
        let partitions = try await adapter.fetchPartitionDetails(table: "orders", schema: "public")

        #expect(partitions[0].isSeparateRelation)
        #expect(partitions[1].isSeparateRelation)
        #expect(!partitions[2].isSeparateRelation)
        #expect(partitions[2].asTableInfo == nil)
    }

    /// A partition keeps the kind of relation it is, not merely the fact of being one. PostgreSQL
    /// 11 allows a foreign table as a partition, and a foreign table is read-only: reporting one as
    /// an ordinary table offers Truncate on another server's data.
    @Test("A foreign-table partition stays a foreign table through the bridge")
    func foreignTablePartitionKeepsItsKind() async throws {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: LegacyPartitionDriver())
        let partitions = try await adapter.fetchPartitionDetails(table: "orders", schema: "public")

        let remote = try #require(partitions.last)
        let remoteTable = try #require(remote.asTableInfo)
        #expect(remote.relationType == .foreignTable)
        #expect(remoteTable.type == .foreignTable)
        #expect(!TableOperationEligibility.canTruncate(remoteTable))
    }

    @Test("A plain partition is truncatable, so the guard is not refusing everything")
    func plainPartitionStaysTruncatable() async throws {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: LegacyPartitionDriver())
        let partitions = try await adapter.fetchPartitionDetails(table: "orders", schema: "public")

        let plain = try #require(partitions[0].asTableInfo)
        #expect(TableOperationEligibility.canTruncate(plain))
    }

    @Test("Two partitions whose components differ only in where a period falls are two rows")
    func partitionIdsEscapeTheirComponents() {
        let first = PartitionInfo(name: "c", schema: "a.b", relationType: .table)
        let second = PartitionInfo(name: "b.c", schema: "a", relationType: .table)

        #expect(first.id != second.id)
    }

    @Test("A partition that is a relation keeps every table affordance, carrying its own schema")
    func relationPartitionResolvesToATable() {
        let parent = DatabaseTreeTableRef(
            database: "shop",
            schema: "public",
            table: TableInfo(name: "orders", type: .partitionedTable, rowCount: nil, schema: "public")
        )
        let ref = DatabaseTreePartitionRef(
            parent: parent,
            partition: PartitionInfo(
                name: "orders_2023",
                schema: "archive",
                bound: "FROM ('2023-01-01') TO ('2024-01-01')",
                relationType: .table
            )
        )

        #expect(ref.tableRef?.schema == "archive")
        #expect(ref.tableRef?.table.name == "orders_2023")
        #expect(ref.tableRef?.qualifyingSchema == "archive")
    }

    @Test("A partition that is not a relation offers no table to act on")
    func intraTablePartitionHasNoTableRef() {
        let parent = DatabaseTreeTableRef(
            database: "shop",
            schema: nil,
            table: TableInfo(name: "events", type: .partitionedTable, rowCount: nil)
        )
        let ref = DatabaseTreePartitionRef(
            parent: parent,
            partition: PartitionInfo(name: "p0", ordinalPosition: 1, relationType: nil)
        )

        #expect(ref.tableRef == nil)
    }
}
