//
//  QueryContextBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

@MainActor
struct QueryContextBuilderTests {
    private let connectionId = UUID()

    private func input(
        _ statement: String,
        schema: String? = "public",
        slot: EngineNamespaceSlot = .schema,
        language: EditorLanguage = .sql
    ) -> QueryContextInput {
        QueryContextInput(
            statement: statement,
            scope: DatabaseScope(connectionId: connectionId, database: "shop", schema: schema),
            namespaceSlot: slot,
            editorLanguage: language,
            grammar: .ansi,
            engineName: "PostgreSQL",
            serverVersion: "16.2"
        )
    }

    private func table(_ name: String, schema: String? = "public", rows: Int? = nil) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: rows, schema: schema)
    }

    @Test("Only the tables the query names are described, in query order, from the tab's scope")
    func describesReferencedTablesOnly() async {
        let driver = ContextFakeDriver()
        driver.tables["public"] = [table("audit"), table("customers", rows: 900), table("orders", rows: 1_200_000)]
        driver.columns["orders"] = [ColumnInfo(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true)]
        driver.columns["customers"] = [ColumnInfo(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true)]
        driver.indexes["orders"] = [IndexInfo(name: "orders_customer_idx", columns: ["customer_id"], isUnique: false, isPrimary: false, type: "BTREE")]
        let metadata = ContextFakeMetadata(driver: driver)

        let snapshot = await QueryContextBuilder(metadata: metadata).build(
            input("SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id")
        )

        #expect(snapshot.tables.map(\.name) == ["orders", "customers"])
        #expect(metadata.scopes.allSatisfy { $0.database == "shop" && $0.connectionId == connectionId })
        guard case .described(let orders) = snapshot.tables.first?.content else {
            Issue.record("orders was not described")
            return
        }
        #expect(orders.approximateRowCount == 1_200_000)
        #expect(orders.indexes.map(\.name) == ["orders_customer_idx"])
        #expect(!driver.describedTables.contains("audit"))
    }

    @Test("A table whose columns cannot be read is reported with the reason, never dropped")
    func unreadableTableIsReported() async {
        let driver = ContextFakeDriver()
        driver.tables["public"] = [table("orders"), table("secrets")]
        driver.columns["orders"] = [ColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true)]
        driver.columnErrors["secrets"] = "permission denied for table secrets"

        let snapshot = await QueryContextBuilder(metadata: ContextFakeMetadata(driver: driver)).build(
            input("SELECT * FROM orders JOIN secrets USING (id)")
        )

        #expect(snapshot.tables.map(\.name) == ["orders", "secrets"])
        #expect(snapshot.tables.last?.content == .unavailable(reason: "permission denied for table secrets"))
        #expect(snapshot.unavailableTableNames == ["secrets"])
    }

    @Test("A failed index read keeps the columns and says the indexes are unknown")
    func failedIndexReadKeepsColumns() async {
        let driver = ContextFakeDriver()
        driver.tables["public"] = [table("orders")]
        driver.columns["orders"] = [ColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true)]
        driver.indexErrors["orders"] = "timeout"

        let snapshot = await QueryContextBuilder(metadata: ContextFakeMetadata(driver: driver)).build(input("SELECT * FROM orders"))

        guard case .described(let structure) = snapshot.tables.first?.content else {
            Issue.record("orders was not described")
            return
        }
        #expect(structure.columns.map(\.name) == ["id"])
        #expect(structure.indexesUnavailableReason == "timeout")
    }

    @Test("Names that are not in the schema, in another database, or over the limit are listed")
    func gapsAreListed() async {
        let driver = ContextFakeDriver()
        let names = (1...(QueryContextBuilder.tableLimit + 1)).map { "t\($0)" }
        driver.tables["public"] = names.map { table($0) }
        let joins = names.map { "JOIN \($0) ON 1 = 1" }.joined(separator: " ")

        let snapshot = await QueryContextBuilder(metadata: ContextFakeMetadata(driver: driver)).build(
            input("SELECT * FROM ghost \(joins) JOIN otherdb.public.remote ON 1 = 1")
        )

        #expect(snapshot.notFound == ["ghost"])
        #expect(snapshot.outsideScope == ["otherdb.public.remote"])
        #expect(snapshot.tables.count == QueryContextBuilder.tableLimit)
        #expect(snapshot.notDescribed == [names.last ?? ""])
    }

    @Test("Names match case-insensitively only when one table fits")
    func caseInsensitiveMatch() async {
        let driver = ContextFakeDriver()
        driver.tables["public"] = [table("Orders"), table("Users"), table("users")]
        driver.columns["Orders"] = [ColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true)]

        let snapshot = await QueryContextBuilder(metadata: ContextFakeMetadata(driver: driver)).build(
            input("SELECT * FROM orders JOIN USERS ON 1 = 1")
        )

        #expect(snapshot.tables.map(\.name) == ["Orders"])
        #expect(snapshot.notFound == ["USERS"])
    }

    @Test("A schema qualifier reads that schema's tables")
    func schemaQualifierIsHonoured() async {
        let driver = ContextFakeDriver()
        driver.tables["public"] = [table("users")]
        driver.tables["auth"] = [table("users", schema: "auth")]
        driver.columns["users"] = [ColumnInfo(name: "id", dataType: "uuid", isNullable: false, isPrimaryKey: true)]
        let metadata = ContextFakeMetadata(driver: driver)

        let snapshot = await QueryContextBuilder(metadata: metadata).build(input("SELECT * FROM auth.users"))

        #expect(snapshot.tables.first?.schema == "auth")
        #expect(driver.describedSchemas == ["auth"])
    }

    @Test("On an engine that qualifies by database, another database is outside the scope")
    func databaseSlot() async {
        let driver = ContextFakeDriver()
        driver.tables[""] = [table("orders", schema: nil)]
        driver.columns["orders"] = [ColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true)]

        let snapshot = await QueryContextBuilder(metadata: ContextFakeMetadata(driver: driver)).build(
            input("SELECT * FROM shop.orders JOIN archive.orders ON 1 = 1", schema: nil, slot: .database)
        )

        #expect(snapshot.tables.map(\.name) == ["orders"])
        #expect(snapshot.outsideScope == ["archive.orders"])
    }

    @Test("A document store only describes tokens that are real collections")
    func documentStoreMatchesInventoryOnly() async {
        let driver = ContextFakeDriver()
        driver.tables[""] = [table("orders", schema: nil), table("users", schema: nil)]
        driver.columns["orders"] = [ColumnInfo(name: "_id", dataType: "ObjectId", isNullable: false, isPrimaryKey: true)]

        let snapshot = await QueryContextBuilder(metadata: ContextFakeMetadata(driver: driver)).build(
            input("db.orders.find({status: 'paid'})", schema: nil, slot: .database, language: .javascript)
        )

        #expect(snapshot.tables.map(\.name) == ["orders"])
        #expect(snapshot.notFound.isEmpty)
        #expect(snapshot.languageTag == "javascript")
    }
}

@MainActor
private final class ContextFakeMetadata: ScopedMetadataProviding {
    private let driver: ContextFakeDriver
    private(set) var scopes: [DatabaseScope] = []

    init(driver: ContextFakeDriver) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        scopes.append(scope)
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}

private struct ContextFakeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class ContextFakeDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection = TestFixtures.makeConnection()
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var tables: [String: [TableInfo]] = [:]
    var columns: [String: [ColumnInfo]] = [:]
    var indexes: [String: [IndexInfo]] = [:]
    var columnErrors: [String: String] = [:]
    var indexErrors: [String: String] = [:]
    private(set) var describedTables: [String] = []
    private(set) var describedSchemas: [String] = []

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func execute(query: String) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func fetchTables() async throws -> [TableInfo] { tables[""] ?? [] }
    func fetchTables(schema: String?) async throws -> [TableInfo] { tables[schema ?? ""] ?? [] }

    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        try await fetchColumns(table: table, schema: nil)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        describedTables.append(table)
        if let schema { describedSchemas.append(schema) }
        if let message = columnErrors[table] { throw ContextFakeError(message: message) }
        return columns[table] ?? []
    }

    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { columns }

    func fetchIndexes(table: String) async throws -> [IndexInfo] {
        if let message = indexErrors[table] { throw ContextFakeError(message: message) }
        return indexes[table] ?? []
    }

    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchViewDefinition(view: String) async throws -> String { "" }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil,
            avgRowLength: nil, rowCount: nil, comment: nil, engine: nil,
            collation: nil, createTime: nil, updateTime: nil
        )
    }

    func fetchDatabases() async throws -> [String] { [] }

    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database, name: database, tableCount: nil, sizeBytes: nil,
            lastAccessed: nil, isSystemDatabase: false, icon: "cylinder"
        )
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {}
    func cancelQuery() throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}
