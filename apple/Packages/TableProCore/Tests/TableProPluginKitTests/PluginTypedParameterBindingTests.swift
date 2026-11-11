import Foundation
import TableProPluginKit
import Testing

struct PluginTypedParameterBindingTests {
    private func bound(
        _ values: [String],
        kinds: [PluginColumnKind?]?,
        query: String = "SELECT * FROM t WHERE a = ?"
    ) async throws -> String {
        let driver = RecordingDriver()
        var context = PluginStatementContext()
        context.parameterKinds = kinds
        _ = try await driver.executeParameterized(query: query, parameters: values.map { .text($0) }, context: context)
        return try #require(driver.executed.first)
    }

    @Test("A String parameter is quoted whatever it looks like", arguments: ["1E5", "42", "00123", "-7"])
    func stringIsQuoted(value: String) async throws {
        #expect(try await bound([value], kinds: [.text]) == "SELECT * FROM t WHERE a = '\(value)'")
    }

    @Test("An Integer or Decimal parameter that reads as that number is bare")
    func numbersAreBare() async throws {
        #expect(try await bound(["42"], kinds: [.integer]) == "SELECT * FROM t WHERE a = 42")
        #expect(try await bound(["1E5"], kinds: [.decimal]) == "SELECT * FROM t WHERE a = 1E5")
    }

    @Test("Text that is not the declared number is sent as a string for the server to refuse")
    func notANumberIsQuoted() async throws {
        #expect(try await bound(["1.5"], kinds: [.integer]) == "SELECT * FROM t WHERE a = '1.5'")
        #expect(try await bound(["1; DROP TABLE t"], kinds: [.decimal]) == "SELECT * FROM t WHERE a = '1; DROP TABLE t'")
    }

    @Test("A Boolean parameter is TRUE or FALSE", arguments: [("true", "TRUE"), ("0", "FALSE"), ("Yes", "TRUE")])
    func booleans(value: String, literal: String) async throws {
        #expect(try await bound([value], kinds: [.boolean]) == "SELECT * FROM t WHERE a = \(literal)")
    }

    @Test("A Boolean parameter that is no boolean is a string")
    func notABooleanIsQuoted() async throws {
        #expect(try await bound(["maybe"], kinds: [.boolean]) == "SELECT * FROM t WHERE a = 'maybe'")
    }

    @Test("A Date parameter is a quoted string")
    func dateIsQuoted() async throws {
        #expect(try await bound(["2026-01-01"], kinds: [.other]) == "SELECT * FROM t WHERE a = '2026-01-01'")
    }

    @Test("A value with no type keeps the reading by shape")
    func untypedKeepsTheShape() async throws {
        #expect(try await bound(["42"], kinds: nil) == "SELECT * FROM t WHERE a = 42")
        #expect(try await bound(["42", "x"], kinds: [.text, nil], query: "SELECT ?, ?") == "SELECT '42', 'x'")
        #expect(try await bound(["42"], kinds: [nil]) == "SELECT * FROM t WHERE a = 42")
    }

    @Test("Each parameter takes its own type by position")
    func typesFollowPosition() async throws {
        let sql = try await bound(["7", "7"], kinds: [.integer, .text], query: "SELECT ?, ?")
        #expect(sql == "SELECT 7, '7'")
    }

    @Test("A driver that forwards its context overload keeps the types through withHostContext")
    func forwardingDriverKeepsTheTypes() async throws {
        let driver = ForwardingDriver()
        var context = PluginStatementContext()
        context.parameterKinds = [.text]
        _ = try await driver.executeUserQuery(
            query: "SELECT ?", rowCap: nil, parameters: [.text("5")], context: context
        )
        #expect(driver.inner.executed == ["SELECT '5'"])
    }
}

struct PluginRowChangeDefaultMarkTests {
    @Test("Only a marked column is the default")
    func onlyMarkedColumnsAreDefaults() {
        var change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        #expect(!change.isColumnDefault(0))
        change.defaultColumns = [1]
        #expect(change.isColumnDefault(1))
        #expect(!change.isColumnDefault(0))
    }

    @Test("An engine with no defaults refuses the first change that leaves a cell to one, naming its row")
    func defaultsUnsupportedNamesTheRow() {
        let plain = PluginRowChange(rowIndex: 3, type: .insert, cellChanges: [], originalRow: nil)
        var defaulted = PluginRowChange(rowIndex: 7, type: .update, cellChanges: [], originalRow: nil)
        defaulted.defaultColumns = [0]
        #expect(PluginRowWriteRefusal.columnDefaultsUnsupported(in: [plain]) == nil)
        #expect(PluginRowWriteRefusal.columnDefaultsUnsupported(in: [plain, defaulted])?.rowIndex == 7)
    }
}

struct PluginBoundedStreamDeclaredLimitTests {
    private func stream(rows: Int, rowLimit: Int?) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            var header = PluginStreamHeader(columns: ["id"], columnTypeNames: ["INT"])
            header.rowLimit = rowLimit
            continuation.yield(.header(header))
            continuation.yield(.rows((0..<rows).map { [PluginCellValue.text(String($0))] }))
            continuation.finish()
        }
    }

    @Test("A stream that stopped at the limit it declared is a cut result below the cap")
    func declaredLimitIsACut() async throws {
        let result = try await PluginBoundedStream.collect(stream(rows: 3, rowLimit: 3), rowCap: 10, startedAt: Date())
        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
    }

    @Test("A stream that ended before its declared limit is whole")
    func shortOfTheLimitIsWhole() async throws {
        let result = try await PluginBoundedStream.collect(stream(rows: 2, rowLimit: 3), rowCap: 10, startedAt: Date())
        #expect(!result.isTruncated)
    }
}

private final class RecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    let supportsSchemas = false
    let supportsTransactions = false
    let currentSchema: String? = nil
    let serverVersion: String? = nil
    private let lock = NSLock()
    private var statements: [String] = []

    var executed: [String] { lock.withLock { statements } }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { statements.append(query) }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
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

// The shape of a driver that overrides the context overload to set its own state, then runs the context-free one.
private final class ForwardingDriver: PluginDatabaseDriver, @unchecked Sendable {
    let inner = RecordingDriver()
    let supportsSchemas = false
    let supportsTransactions = false
    let currentSchema: String? = nil
    let serverVersion: String? = nil

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        try await inner.execute(query: query)
    }
    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        try await PluginParameterBinder.withHostContext(context) {
            try await executeUserQuery(query: query, rowCap: rowCap, parameters: parameters)
        }
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
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
