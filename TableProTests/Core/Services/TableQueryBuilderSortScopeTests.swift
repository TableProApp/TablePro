//
//  TableQueryBuilderSortScopeTests.swift
//  TableProTests
//
//  A sort index only means something next to the list it was taken from. The grid indexes the
//  full result; a scoped browse query hands the driver a shorter list. These pin that the
//  builder re-resolves between the two instead of passing one list's index to the other.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class SortRecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    var receivedSortColumns: [(columnIndex: Int, ascending: Bool)] = []
    var receivedColumns: [String] = []

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
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

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        receivedSortColumns = sortColumns
        receivedColumns = columns
        return "recorded"
    }

    func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        receivedSortColumns = sortColumns
        receivedColumns = columns
        return "recorded"
    }

    /// The name the driver would order by, resolved the way every plugin browse builder does it.
    var resolvedSortNames: [String] {
        receivedSortColumns.compactMap { sortColumn in
            guard sortColumn.columnIndex >= 0, sortColumn.columnIndex < receivedColumns.count else { return nil }
            return receivedColumns[sortColumn.columnIndex]
        }
    }
}

@Suite("TableQueryBuilder sort scope")
struct TableQueryBuilderSortScopeTests {
    private let displayColumns = ["_id", "name", "email", "createdAt"]

    private func makeBuilder(_ driver: SortRecordingDriver) -> TableQueryBuilder {
        TableQueryBuilder(databaseType: .mongodb, pluginDriver: driver)
    }

    /// Issue #2234: after hiding columns, the sort index landed outside the scoped list and the
    /// driver dropped the sort entirely.
    @Test("A sort survives a scoped projection and still names its own column")
    func sortSurvivesScopedProjection() {
        let driver = SortRecordingDriver()
        let sortState = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .descending, columnName: "createdAt"),
        ])

        _ = makeBuilder(driver).buildBaseQuery(
            tableName: "events",
            sortState: sortState,
            columns: displayColumns,
            selectColumns: ["_id", "createdAt"]
        )

        #expect(driver.receivedColumns == ["_id", "createdAt"])
        #expect(driver.resolvedSortNames == ["createdAt"])
        #expect(driver.receivedSortColumns.first?.ascending == false)
    }

    @Test("An unscoped sort still names its own column")
    func sortWithoutScope() {
        let driver = SortRecordingDriver()
        let sortState = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .ascending, columnName: "createdAt"),
        ])

        _ = makeBuilder(driver).buildBaseQuery(
            tableName: "events",
            sortState: sortState,
            columns: displayColumns,
            selectColumns: nil
        )

        #expect(driver.resolvedSortNames == ["createdAt"])
    }

    /// Before the fix this produced a valid-looking index into the scoped list and the driver
    /// silently ordered by a different column.
    @Test("A scoped projection never lets an index resolve to a different column")
    func neverResolvesToAnotherColumn() {
        let driver = SortRecordingDriver()
        let sortState = SortState(columns: [
            SortColumn(columnIndex: 2, direction: .ascending, columnName: "email"),
        ])

        _ = makeBuilder(driver).buildBaseQuery(
            tableName: "events",
            sortState: sortState,
            columns: displayColumns,
            selectColumns: ["_id", "name", "createdAt"]
        )

        #expect(!driver.resolvedSortNames.contains("createdAt"))
        #expect(driver.resolvedSortNames.isEmpty)
    }

    @Test("A filtered browse query resolves its sort the same way")
    func filteredQueryResolvesSort() {
        let driver = SortRecordingDriver()
        let sortState = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .ascending, columnName: "createdAt"),
        ])

        _ = makeBuilder(driver).buildFilteredQuery(
            tableName: "events",
            filters: [],
            sortState: sortState,
            columns: displayColumns,
            selectColumns: ["_id", "createdAt"]
        )

        #expect(driver.resolvedSortNames == ["createdAt"])
    }

    @Test("Multi-column sort keeps order and direction through a scoped projection")
    func multiColumnSortSurvives() {
        let driver = SortRecordingDriver()
        let sortState = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .descending, columnName: "createdAt"),
            SortColumn(columnIndex: 1, direction: .ascending, columnName: "name"),
        ])

        _ = makeBuilder(driver).buildBaseQuery(
            tableName: "events",
            sortState: sortState,
            columns: displayColumns,
            selectColumns: ["_id", "name", "createdAt"]
        )

        #expect(driver.resolvedSortNames == ["createdAt", "name"])
        #expect(driver.receivedSortColumns.map(\.ascending) == [false, true])
    }

    // MARK: - SQL fallback path

    @Test("The SQL fallback orders by the stamped name, not the stored position")
    func sqlFallbackUsesName() {
        let sortState = SortState(columns: [
            SortColumn(columnIndex: 99, direction: .descending, columnName: "createdAt"),
        ])
        let query = TableQueryBuilder(databaseType: .mysql).buildBaseQuery(
            tableName: "events",
            sortState: sortState,
            columns: displayColumns,
            selectColumns: ["id", "createdAt"]
        )
        #expect(query.contains("ORDER BY"))
        #expect(query.contains("createdAt"))
        #expect(query.contains("DESC"))
    }
}
