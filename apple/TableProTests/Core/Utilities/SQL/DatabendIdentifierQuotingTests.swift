//
//  DatabendIdentifierQuotingTests.swift
//  TableProTests
//
//  Measured on Databend 1.2.880: `orders``backup` reads as orders aliased backup, so a browse or a grid write on
//  that table reached orders. "orders`backup" reads as the one name on 1.2.880 and 1.2.958.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DatabendIdentifierQuotingTests {
    @Test("The dialect quoter spells a Databend name as its driver does")
    func dialectQuoterMatchesTheDriver() throws {
        let dialect = try resolveSQLDialect(for: .databend)
        let quote = quoteIdentifierFromDialect(dialect, databaseType: .databend)
        #expect(quote("orders") == "`orders`")
        #expect(quote("orders`backup") == "\"orders`backup\"")
        #expect(quote("bs`\\b") == "\"bs`\\b\"")
        #expect(quoteIdentifierFromDialect(dialect, databaseType: .mysql)("orders`backup") == "`orders``backup`")
    }

    @Test("A table tab browses a name holding a backtick as that table")
    func browseQueryNamesTheTable() throws {
        let query = try QueryTab.buildBaseTableQuery(tableName: "orders`backup", databaseType: .databend)
        #expect(query.hasPrefix("SELECT * FROM \"orders`backup\" "))
    }

    @Test("A grid delete and update name the table that was browsed")
    func rowWritesNameTheTable() throws {
        let generator = try SQLStatementGenerator(
            tableName: "orders`backup", columns: ["id", "total"], primaryKeyColumns: [], databaseType: .databend
        )
        let row: [PluginCellValue] = ["1", "10.00"]
        let delete = RowChange(rowID: .existing(0), type: .delete, cellChanges: [], originalRow: row)
        let statements = generator.generateStatements(
            from: [delete], insertedRowData: [:], deletedRowIDs: [.existing(0)], insertedRowIDs: []
        )
        #expect(statements.map(\.sql) == ["DELETE FROM \"orders`backup\" WHERE (`id` = ? AND `total` = ?)"])

        let update = RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [CellChange(columnIndex: 1, columnName: "total", oldValue: "10.00", newValue: "11.00")],
            originalRow: row
        )
        let updateSQL = try #require(generator.generateUpdateSQL(for: update)).sql
        #expect(updateSQL.hasPrefix("UPDATE \"orders`backup\" SET `total` = ? WHERE "))
    }

    @Test("A page query from the builder names the table that was browsed")
    func pageQueryNamesTheTable() throws {
        let dialect = try resolveSQLDialect(for: .databend)
        let builder = TableQueryBuilder(
            databaseType: .databend,
            dialect: dialect,
            pagination: .offset,
            dialectQuote: quoteIdentifierFromDialect(dialect, databaseType: .databend)
        )
        let query = builder.buildBaseQuery(tableName: "orders`backup", columns: ["id`x"], limit: 10, offset: 0)
        #expect(query.hasPrefix("SELECT * FROM \"orders`backup\" "))
    }

    @Test("An MCP SQL export writes the name the way Databend reads it")
    func mcpExportQuotesTheName() throws {
        let databend = try #require(MCPSqlExportDialect.resolve(for: .databend))
        #expect(databend.quote("orders`backup") == "\"orders`backup\"")
        let mysql = try #require(MCPSqlExportDialect.resolve(for: .mysql))
        #expect(mysql.quote("orders`backup") == "`orders``backup`")
    }
}
