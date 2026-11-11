import Foundation
import TableProPluginKit
import Testing

// The default stream dropped `isTruncated`, so a result the driver cut reached the export as a whole one.
struct PluginDefaultStreamRowLimitTests {
    private func header(of driver: some PluginDatabaseDriver) async throws -> PluginStreamHeader? {
        for try await element in driver.streamRows(query: "SELECT id FROM t") {
            if case .header(let header) = element { return header }
        }
        return nil
    }

    @Test("A result the driver cut declares the row count it stopped at")
    func cutResultDeclaresItsLimit() async throws {
        let header = try await header(of: CutResultDriver(rowCount: 3, isCut: true))
        #expect(header?.rowLimit == 3)
    }

    @Test("A whole result declares no limit")
    func wholeResultDeclaresNoLimit() async throws {
        let header = try await header(of: CutResultDriver(rowCount: 3, isCut: false))
        #expect(header != nil)
        #expect(header?.rowLimit == nil)
    }
}

private final class CutResultDriver: PluginDatabaseDriver, @unchecked Sendable {
    let supportsSchemas = false
    let supportsTransactions = false
    let currentSchema: String? = nil
    let serverVersion: String? = nil

    private let rowCount: Int
    private let isCut: Bool

    init(rowCount: Int, isCut: Bool) {
        self.rowCount = rowCount
        self.isCut = isCut
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(
            columns: ["id"],
            columnTypeNames: ["INTEGER"],
            rows: (0..<rowCount).map { [.text(String($0))] },
            rowsAffected: 0,
            executionTime: 0,
            isTruncated: isCut
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
