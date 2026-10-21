//
//  UnloadedValueReaderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct UnloadedValueReaderTests {
    private final class Recorder {
        var statements: [ParameterizedStatement] = []
    }

    private static func reader(
        keys: [String] = ["id"],
        style: ParameterStyle = .questionMark,
        recorder: Recorder = Recorder(),
        answer: @escaping (ParameterizedStatement) -> [[PluginCellValue]] = { _ in [] }
    ) -> UnloadedValueReader {
        UnloadedValueReader(
            tableName: "files",
            schemaName: nil,
            keyColumns: keys,
            databaseType: .mysql,
            parameterStyle: style,
            quote: { "`\($0)`" },
            run: { statement in
                recorder.statements.append(statement)
                return answer(statement)
            }
        )
    }

    @Test("One value is read by its primary key, nothing else from the row")
    func singleKeyStatement() throws {
        let statement = try #require(Self.reader().statement(columns: ["data"], keys: [["7"]]))
        #expect(statement.sql == "SELECT `id`, `data` FROM `files` WHERE `id` IN (?)")
        #expect(statement.parameters.compactMap { $0 as? String } == ["7"])
    }

    @Test("A composite key matches every key column of each row")
    func compositeKeyStatement() throws {
        let statement = try #require(Self.reader(keys: ["a", "b"], style: .dollar).statement(
            columns: ["data", "thumb"], keys: [["1", "x"], ["2", "y"]]
        ))
        #expect(statement.sql == """
            SELECT `a`, `b`, `data`, `thumb` FROM `files` WHERE (`a` = $1 AND `b` = $2) OR (`a` = $3 AND `b` = $4)
            """)
        #expect(statement.parameters.count == 4)
    }

    @Test("Batches stop at the key count and at the byte budget")
    func batching() {
        let many = (0..<250).map { UnloadedValueReader.Request(key: [.text(String($0))], byteCount: 10) }
        #expect(UnloadedValueReader.batches(of: many).map(\.count) == [100, 100, 50])

        let large = (0..<3).map {
            UnloadedValueReader.Request(key: [.text(String($0))], byteCount: 20 * 1_024 * 1_024)
        }
        #expect(UnloadedValueReader.batches(of: large).map(\.count) == [1, 1, 1])
    }

    @Test("Values come back keyed by the key the page read")
    func readMapsByKey() async throws {
        let recorder = Recorder()
        let reader = Self.reader(recorder: recorder) { _ in
            [["2", .bytes(Data([2]))], ["1", .bytes(Data([1]))]]
        }
        let values = try await reader.read(
            columns: ["data"],
            requests: [.init(key: ["1"], byteCount: 1), .init(key: ["2"], byteCount: 1)]
        )
        #expect(recorder.statements.count == 1)
        #expect(values[["1"]] == [.bytes(Data([1]))])
        #expect(values[["2"]] == [.bytes(Data([2]))])
    }
}

private final class BlobAnsweringDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    private let lock = NSLock()
    private var received: [String] = []
    private let rows: [[PluginCellValue]]

    init(connection: DatabaseConnection, rows: [[PluginCellValue]]) {
        self.connection = connection
        self.rows = rows
    }

    var queries: [String] { lock.withLock { received } }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        lock.withLock { received.append(query) }
        return QueryResult(
            columns: ["id", "data"],
            columnTypes: [.integer(rawType: "INT"), .blob(rawType: "LONGBLOB")],
            rows: rows,
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    func execute(query: String) async throws -> QueryResult { try await executeUserQuery(query: query, rowCap: nil, parameters: nil) }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        try await executeUserQuery(query: query, rowCap: nil, parameters: parameters)
    }
    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func ping() async throws {}
    func cancelQuery() throws {}
    func applyQueryTimeout(_ seconds: Int) async throws {}
    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database, name: database, tableCount: nil, sizeBytes: nil,
            lastAccessed: nil, isSystemDatabase: false, icon: "cylinder"
        )
    }
    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil, avgRowLength: nil,
            rowCount: nil, comment: nil, engine: nil, collation: nil, createTime: nil, updateTime: nil
        )
    }
    func fetchViewDefinition(view: String) async throws -> String { "" }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

@MainActor
struct UnloadedValueLoadTests {
    @Test("Opening one unloaded cell reads only that value, by key, into the grid's rows")
    func loadFillsOneCell() async {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let driver = BlobAnsweringDriver(connection: connection, rows: [["2", .bytes(Data([7, 7]))]])
        let fixture = CoordinatorFixture(connection: connection, driver: driver)
        var tab = QueryTab(title: "files", query: "", tabType: .table, tableName: "files")
        tab.tableContext.primaryKeyColumns = ["id"]
        let page = TableRows.from(
            queryRows: [["1", .null], ["2", .null]],
            columns: ["id", "data"],
            columnTypes: [.integer(rawType: "INT"), .blob(rawType: "LONGBLOB")],
            unloadedCells: [0: [1: 10], 1: [1: 20]]
        )
        fixture.addTab(tab, rows: page)

        let loaded = await fixture.coordinator.loadUnloadedValues(
            tabId: tab.id, rowIDs: [.existing(1)], columns: IndexSet(integer: 1)
        )

        #expect(loaded)
        #expect(driver.queries == ["SELECT `id`, `data` FROM `files` WHERE `id` IN (?)"])
        let rows = fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id)
        #expect(rows.value(at: 1, column: 1) == .bytes(Data([7, 7])))
        #expect(rows.unloadedByteCount(row: 1, column: 1) == nil)
        #expect(rows.unloadedByteCount(row: 0, column: 1) == 10)
    }

    @Test("A row the table no longer holds leaves its cell unloaded and reports it")
    func missingRowStaysUnloaded() async {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let driver = BlobAnsweringDriver(connection: connection, rows: [])
        let fixture = CoordinatorFixture(connection: connection, driver: driver)
        var tab = QueryTab(title: "files", query: "", tabType: .table, tableName: "files")
        tab.tableContext.primaryKeyColumns = ["id"]
        fixture.addTab(tab, rows: TableRows.from(
            queryRows: [["1", .null]],
            columns: ["id", "data"],
            columnTypes: [.integer(rawType: "INT"), .blob(rawType: "LONGBLOB")],
            unloadedCells: [0: [1: 10]]
        ))

        let loaded = await fixture.coordinator.loadUnloadedValues(tabId: tab.id, rowIDs: [.existing(0)])

        #expect(!loaded)
        #expect(fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id).unloadedByteCount(row: 0, column: 1) == 10)
    }
}

@MainActor
struct UnloadedValueExportTests {
    @MainActor
    private final class BatchLog {
        var counts: [Int] = []
    }
    private static func page(rowCount: Int) -> TableRows {
        TableRows.from(
            queryRows: (0..<rowCount).map { [.text(String($0)), .null] },
            columns: ["id", "data"],
            columnTypes: [.integer(rawType: "INT"), .blob(rawType: "LONGBLOB")],
            unloadedCells: Dictionary(uniqueKeysWithValues: (0..<rowCount).map { ($0, [1: 100]) })
        )
    }

    private static func exportedRows(
        _ source: QueryResultExportDataSource
    ) async throws -> [[PluginCellValue]] {
        var rows: [[PluginCellValue]] = []
        for try await element in source.streamRows(table: "files", databaseName: "d") {
            if case .rows(let chunk) = element { rows.append(contentsOf: chunk) }
        }
        return rows
    }

    @Test("Export Results writes the values the page left on the server, read a chunk at a time")
    func exportFillsUnloadedValues() async throws {
        let batches = BatchLog()
        let source = QueryResultExportDataSource(
            tableRows: Self.page(rowCount: 120),
            databaseType: .mysql,
            driver: nil,
            fillUnloaded: { rows in
                batches.counts.append(rows.count)
                return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, [1: PluginCellValue.bytes(Data([1]))]) })
            }
        )

        let rows = try await Self.exportedRows(source)

        #expect(rows.count == 120)
        #expect(rows.allSatisfy { $0[1] == .bytes(Data([1])) })
        #expect(batches.counts == [50, 50, 20])
    }

    @Test("An export stops rather than write an empty cell for a value it could not read")
    func exportFailsOnMissingValue() async {
        let source = QueryResultExportDataSource(
            tableRows: Self.page(rowCount: 2),
            databaseType: .mysql,
            driver: nil,
            fillUnloaded: { _ in [:] }
        )

        await #expect(throws: UnloadedValueError.self) {
            _ = try await Self.exportedRows(source)
        }
    }
}
