//
//  PluginDriverAdapterTableTypeMappingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StubTableTypeDriver: PluginDatabaseDriver, @unchecked Sendable {
    var stubbedSupportsSchemas = false
    var stubbedCurrentSchema: String?

    var supportsSchemas: Bool { stubbedSupportsSchemas }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { stubbedCurrentSchema }
    var serverVersion: String? { nil }

    var stubbedTables: [PluginTableInfo] = []
    var stubbedPartitions: [PluginTableInfo] = []
    private(set) var requestedPartitionTable: String?
    private(set) var requestedTableSchema: String??

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        requestedTableSchema = .some(schema)
        return stubbedTables
    }

    func fetchPartitions(table: String, schema: String?) async throws -> [PluginTableInfo] {
        requestedPartitionTable = table
        return stubbedPartitions
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

@Suite("PluginDriverAdapter table type mapping")
struct PluginDriverAdapterTableTypeMappingTests {
    private func makeAdapter(driver: StubTableTypeDriver) -> PluginDriverAdapter {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        return PluginDriverAdapter(connection: connection, pluginDriver: driver)
    }

    @Test("Maps TABLE/BASE TABLE/PREFIX strings to .table")
    func mapsTableVariants() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [
            PluginTableInfo(name: "users", type: "TABLE"),
            PluginTableInfo(name: "orders", type: "BASE TABLE"),
            PluginTableInfo(name: "PREFIX", type: "prefix")
        ]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.count == 3)
        #expect(tables.allSatisfy { $0.type == .table })
    }

    @Test("Maps VIEW string to .view")
    func mapsView() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "user_summary", type: "VIEW")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .view)
    }

    @Test("Maps MATERIALIZED VIEW string to .materializedView")
    func mapsMaterializedView() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "daily_sales", type: "MATERIALIZED VIEW")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .materializedView)
    }

    @Test("Maps materialized_view variant to .materializedView")
    func mapsMaterializedViewUnderscore() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "daily_sales", type: "materialized_view")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .materializedView)
    }

    @Test("Maps FOREIGN TABLE string to .foreignTable")
    func mapsForeignTable() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "remote_users", type: "FOREIGN TABLE")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .foreignTable)
    }

    @Test("Maps foreign_table variant to .foreignTable")
    func mapsForeignTableUnderscore() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "remote_users", type: "foreign_table")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .foreignTable)
    }

    @Test("Maps system table variants to .systemTable")
    func mapsSystemTable() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [
            PluginTableInfo(name: "pg_class", type: "SYSTEM TABLE"),
            PluginTableInfo(name: "sqlite_master", type: "system base table"),
            PluginTableInfo(name: "sys_views", type: "system view")
        ]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.count == 3)
        #expect(tables.allSatisfy { $0.type == .systemTable })
    }

    @Test("Maps the Redshift external classifier output to an external table")
    func mapsExternalTable() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [
            PluginTableInfo(
                name: "customers",
                type: RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: "TABLE")
            ),
            PluginTableInfo(
                name: "orders",
                type: RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: " ")
            ),
            PluginTableInfo(name: "events", type: "external_table")
        ]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.count == 3)
        #expect(tables.allSatisfy { $0.type == .externalTable })
        #expect(tables.allSatisfy { !$0.type.allowsRowEditing })
    }

    @Test("Maps unknown type to .table with warning")
    func mapsUnknownToTable() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "thing", type: "GIBBERISH")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .table)
    }

    @Test("Type matching is case-insensitive")
    func caseInsensitiveMatching() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [
            PluginTableInfo(name: "t1", type: "table"),
            PluginTableInfo(name: "v1", type: "View"),
            PluginTableInfo(name: "m1", type: "Materialized View"),
            PluginTableInfo(name: "f1", type: "Foreign Table")
        ]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables[0].type == .table)
        #expect(tables[1].type == .view)
        #expect(tables[2].type == .materializedView)
        #expect(tables[3].type == .foreignTable)
    }

    @Test("TableType raw value round-trip for new cases")
    func rawValueRoundTrip() {
        #expect(TableInfo.TableType.materializedView.rawValue == "MATERIALIZED VIEW")
        #expect(TableInfo.TableType.foreignTable.rawValue == "FOREIGN TABLE")
        #expect(TableInfo.TableType.partitionedTable.rawValue == "PARTITIONED TABLE")
        #expect(TableInfo.TableType(rawValue: "MATERIALIZED VIEW") == .materializedView)
        #expect(TableInfo.TableType(rawValue: "FOREIGN TABLE") == .foreignTable)
        #expect(TableInfo.TableType(rawValue: "PARTITIONED TABLE") == .partitionedTable)
    }

    @Test("Maps PARTITIONED TABLE variants to .partitionedTable rather than falling back to .table")
    func mapsPartitionedTable() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [
            PluginTableInfo(name: "orders", type: "PARTITIONED TABLE"),
            PluginTableInfo(name: "events", type: "partitioned_table"),
            PluginTableInfo(name: "logs", type: "Partitioned Table")
        ]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.count == 3)
        #expect(tables.allSatisfy { $0.type == .partitionedTable })
    }

    @Test("A partitioned parent stays distinct from an ordinary table")
    func partitionedTableIsDistinctFromTable() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [
            PluginTableInfo(name: "orders", type: "PARTITIONED TABLE"),
            PluginTableInfo(name: "users", type: "BASE TABLE")
        ]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables[0].type == .partitionedTable)
        #expect(tables[1].type == .table)
    }

    @Test("fetchPartitions bridges plugin rows and resolves the schema")
    func fetchPartitionsBridgesRows() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedPartitions = [
            PluginTableInfo(name: "orders_2024_01", type: "TABLE"),
            PluginTableInfo(name: "orders_2024_02", type: "PARTITIONED TABLE")
        ]
        let adapter = makeAdapter(driver: driver)
        let partitions = try await adapter.fetchPartitions(table: "orders", schema: "app")
        #expect(driver.requestedPartitionTable == "orders")
        #expect(partitions.map(\.name) == ["orders_2024_01", "orders_2024_02"])
        #expect(partitions[0].type == .table)
        #expect(partitions[1].type == .partitionedTable)
        #expect(partitions.allSatisfy { $0.schema == "app" })
    }

    @Test("Plugin schema propagates to TableInfo when set on PluginTableInfo")
    func pluginSchemaPropagates() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [
            PluginTableInfo(name: "users", type: "TABLE", schema: "analytics"),
            PluginTableInfo(name: "orders", type: "TABLE", schema: "public")
        ]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        let bySchema = Dictionary(grouping: tables, by: { $0.schema ?? "" })
        #expect(bySchema["analytics"]?.first?.name == "users")
        #expect(bySchema["public"]?.first?.name == "orders")
    }

    @Test("fetchTables(schema:) resolves missing PluginTableInfo schema to requested schema")
    func explicitSchemaFallback() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "logs", type: "TABLE")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables(schema: "audit")
        #expect(tables.first?.schema == "audit")
    }

    @Test("fetchTables() stamps the schema the rows were actually read from")
    func defaultFetchStampsCurrentSchema() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedSupportsSchemas = true
        driver.stubbedCurrentSchema = "custom"
        driver.stubbedTables = [PluginTableInfo(name: "def_encounter", type: "TABLE")]
        let adapter = makeAdapter(driver: driver)

        let tables = try await adapter.fetchTables()

        #expect(driver.requestedTableSchema == .some("custom"))
        #expect(tables.first?.schema == "custom")
    }

    @Test("fetchTables() stays schema-less for an engine without schemas")
    func defaultFetchStaysSchemaLess() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "users", type: "TABLE")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.schema == nil)
    }
}
