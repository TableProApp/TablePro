import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ForeignKeyPreviewQuery")
struct ForeignKeyPreviewQueryTests {
    private func dialect(
        paginationStyle: SQLDialectDescriptor.PaginationStyle,
        offsetFetchOrderBy: String = "ORDER BY (SELECT NULL)"
    ) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            paginationStyle: paginationStyle,
            offsetFetchOrderBy: offsetFetchOrderBy
        )
    }

    @Test("A LIMIT dialect gets LIMIT 1")
    func limitDialect() {
        #expect(ForeignKeyPreviewQuery.limitClause(dialect: dialect(paginationStyle: .limit)) == "LIMIT 1")
    }

    @Test("An unknown dialect falls back to LIMIT rather than to nothing")
    func missingDialectFallsBackToLimit() {
        #expect(ForeignKeyPreviewQuery.limitClause(dialect: nil) == "LIMIT 1")
    }

    /// T-SQL parses OFFSET/FETCH as part of ORDER BY, so the clause on its own is Msg 102 and the
    /// popover reported it as a missing row on every SQL Server connection.
    @Test("An OFFSET/FETCH dialect carries its ORDER BY filler")
    func offsetFetchCarriesOrderBy() {
        let clause = ForeignKeyPreviewQuery.limitClause(dialect: dialect(paginationStyle: .offsetFetch))
        #expect(clause == "ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY")
    }

    @Test("A dialect that declares no filler emits OFFSET/FETCH alone")
    func offsetFetchWithoutFillerOmitsOrderBy() {
        let clause = ForeignKeyPreviewQuery.limitClause(
            dialect: dialect(paginationStyle: .offsetFetch, offsetFetchOrderBy: "")
        )
        #expect(clause == "OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY")
    }

    @Test("The statement puts the pagination clause last")
    func statementEndsWithTheClause() {
        let sql = ForeignKeyPreviewQuery.singleRow(
            quotedTable: "[dbo].[customers]",
            quotedColumn: "[id]",
            escapedValue: "42",
            dialect: dialect(paginationStyle: .offsetFetch)
        )
        #expect(
            sql == "SELECT * FROM [dbo].[customers] WHERE [id] = '42' "
                + "ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY"
        )
    }

    @Test("The value arrives already escaped and is not escaped again")
    func escapedValueIsUsedVerbatim() {
        let sql = ForeignKeyPreviewQuery.singleRow(
            quotedTable: "\"users\"",
            quotedColumn: "\"name\"",
            escapedValue: "O''Brien",
            dialect: dialect(paginationStyle: .limit)
        )
        #expect(sql == "SELECT * FROM \"users\" WHERE \"name\" = 'O''Brien' LIMIT 1")
    }
}
