import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
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
            pagination: .offset,
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

    @Test("A JavaScript editor's own query reaches the collection through the shared accessor")
    func javascriptQueryUsesSharedAccessor() throws {
        let lineTerminators: Set<Unicode.Scalar> = ["\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]
        for name in ["users", "stats", "a\u{2028}b", "c\u{85}d", "e\"f\ng"] {
            let query = try QueryTab.buildBaseTableQuery(tableName: name, databaseType: .mongodb)
            #expect(query.hasPrefix("\(MongoCollectionAccessor.expression(for: name)).find({}).limit("), "\(name)")
            #expect(!query.unicodeScalars.contains { lineTerminators.contains($0) }, "\(name)")
            #expect(QuerySqlParser.extractTableName(from: query) == name, "\(name)")
        }
    }
}
