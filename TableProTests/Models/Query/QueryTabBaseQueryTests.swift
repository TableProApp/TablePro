import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("QueryTab.buildBaseTableQuery")
struct QueryTabBaseQueryTests {
    init() {
        FakeMSSQLPluginRegistration.registerIfNeeded()
    }

    @Test("Editor query for opening a table equals the executed browse query")
    func editorQueryMatchesExecutedQuery() throws {
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        let dialect = PluginManager.shared.sqlDialect(for: .mssql)
        let quote = dialect.map(quoteIdentifierFromDialect)

        let editorQuery = try QueryTab.buildBaseTableQuery(
            tableName: "users",
            databaseType: .mssql,
            schemaName: nil,
            quoteIdentifier: quote
        )

        let executed = TableQueryBuilder(
            databaseType: .mssql,
            pluginDriver: PluginManager.shared.queryBuildingDriver(for: .mssql),
            dialect: dialect,
            dialectQuote: quote
        ).buildBaseQuery(tableName: "users", schemaName: nil, limit: pageSize, offset: 0)

        #expect(editorQuery == executed)
    }

    @Test("Editor query is not truncated and carries no SUBSTRING projection")
    func editorQueryHasNoSubstringProjection() throws {
        let dialect = PluginManager.shared.sqlDialect(for: .mssql)
        let query = try QueryTab.buildBaseTableQuery(
            tableName: "users",
            databaseType: .mssql,
            schemaName: nil,
            quoteIdentifier: dialect.map(quoteIdentifierFromDialect)
        )

        #expect(query.contains("SELECT * FROM"))
        #expect(!query.uppercased().contains("SUBSTRING"))
        #expect(!query.hasSuffix(";"))
    }
}
