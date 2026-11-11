import Foundation
import TableProPluginKit
import Testing

struct PluginReadOnlyModeTests {
    @Test("A new context asks for no Read-Only mode and no byte limit")
    func contextDefaults() {
        let context = PluginStatementContext()

        #expect(!context.enforcesReadOnly)
        #expect(context.resultByteLimit == nil)
        #expect(context == PluginStatementContext(enforcesReadOnly: false, resultByteLimit: nil))
    }

    @Test("The initializer sets both fields, and equality reads them")
    func contextInitializerSetsTheFields() {
        let context = PluginStatementContext(enforcesReadOnly: true, resultByteLimit: 4_096)

        #expect(context.enforcesReadOnly)
        #expect(context.resultByteLimit == 4_096)
        #expect(context != PluginStatementContext())
        #expect(PluginStatementContext(resultByteLimit: 1) != PluginStatementContext(resultByteLimit: 2))
    }

    @Test("The Read-Only capability is bit 24 and shares no bit with another capability")
    func capabilityBit() {
        let others: [PluginCapabilities] = [
            .materializedViews, .foreignTables, .storedProcedures, .userFunctions, .alterTableDDL, .foreignKeyToggle,
            .truncateTable, .multiSchema, .parameterizedQueries, .cancelQuery, .batchExecute, .transactions,
            .userManagement, .schemaCompare, .dataCompare, .resultSetBatches, .cellExpressions, .uuidCellText,
            .temporaryTables, .rowWrites, .repeatingPrimaryKey, .readOnlyStatements, .statementPolicy,
            .columnDefaultMarks,
        ]

        #expect(PluginCapabilities.enforcesReadOnlyMode.rawValue == 1 << 24)
        for other in others {
            #expect(other.isDisjoint(with: .enforcesReadOnlyMode), "\(other.rawValue)")
        }
    }

    @Test("The default bounded read with a context runs the context-free one for a plain read")
    func defaultForwardsAPlainRead() async throws {
        let driver = BoundedReadDriver()
        let context = PluginStatementContext(resultByteLimit: 1_024)

        let result = try await driver.executeBoundedQuery(query: "SELECT 1", rowCap: 5, context: context)

        #expect(result?.rows.count == 1)
        #expect(driver.calls == [5])
    }

    @Test(
        "The default bounded read with a context hands back what the context-free one cannot honor",
        arguments: Restriction.allCases
    )
    func defaultRefusesARestrictedRead(restriction: Restriction) async throws {
        let driver = BoundedReadDriver()

        let result = try await driver.executeBoundedQuery(query: "SELECT 1", rowCap: 5, context: restriction.context)

        #expect(result == nil)
        #expect(driver.calls.isEmpty)
    }

    enum Restriction: CaseIterable, Sendable {
        case enforcesReadOnly
        case readOnly
        case readsCatalog
        case refusesDestructive
        case refusesServerCode

        var context: PluginStatementContext {
            var context = PluginStatementContext()
            switch self {
            case .enforcesReadOnly: context.enforcesReadOnly = true
            case .readOnly: context.readOnly = true
            case .readsCatalog: context.readsCatalog = true
            case .refusesDestructive: context.allowsDestructive = false
            case .refusesServerCode: context.allowsServerCode = false
            }
            return context
        }
    }
}

private final class BoundedReadDriver: PluginDatabaseDriver, @unchecked Sendable {
    let supportsSchemas = false
    let supportsTransactions = false
    let currentSchema: String? = nil
    let serverVersion: String? = nil

    private let lock = NSLock()
    private var rowCaps: [Int] = []

    var calls: [Int] {
        lock.withLock { rowCaps }
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        lock.withLock { rowCaps.append(rowCap) }
        return PluginQueryResult(
            columns: ["one"],
            columnTypeNames: ["INTEGER"],
            rows: [[.text("1")]],
            rowsAffected: 0,
            executionTime: 0
        )
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
