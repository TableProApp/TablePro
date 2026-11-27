import Foundation
import TableProModels
import TableProQuery
import Testing
@testable import TableProMobile

// SQL Server has no session schema to set and resolves `[schema].[table]` in the session's database, which a `USE`
// moves, so every statement names the schema and the database the window shows.
struct SQLBuilderSchemaQualificationTests {
    private func driver() -> MockDatabaseDriver { MockDatabaseDriver() }

    @Test("a select names the schema it was given")
    func selectIsQualified() {
        #expect(SQLBuilder.buildSelect(table: "orders", schema: "sales", type: .mssql, limit: 10, offset: 0)
            .hasPrefix("SELECT * FROM [sales].[orders]"))
        #expect(SQLBuilder.buildCount(table: "orders", schema: "sales", type: .mssql)
            == "SELECT COUNT(*) FROM [sales].[orders]")
    }

    @Test("a delete names the schema, so it cannot remove the default schema's rows")
    func deleteIsQualified() {
        let sql = SQLBuilder.buildDelete(
            table: "orders", schema: "sales", type: .mssql, driver: driver(),
            primaryKeys: [(column: "id", value: "1")], columns: []
        )
        #expect(sql.hasPrefix("DELETE FROM [sales].[orders] WHERE"))
    }

    @Test("an update names the schema")
    func updateIsQualified() {
        let sql = SQLBuilder.buildUpdate(
            table: "orders", schema: "sales", type: .mssql, driver: driver(),
            changes: [(column: "note", value: "x")],
            primaryKeys: [(column: "id", value: "1")], columns: []
        )
        #expect(sql.hasPrefix("UPDATE [sales].[orders] SET"))
    }

    @Test("a filtered select and count name the schema")
    func filteredIsQualified() {
        #expect(SQLBuilder.buildFilteredSelect(
            table: "orders", schema: "sales", type: .mssql,
            filters: [], logicMode: .and, limit: 10, offset: 0
        ).hasPrefix("SELECT * FROM [sales].[orders]"))
        #expect(SQLBuilder.buildFilteredCount(
            table: "orders", schema: "sales", type: .mssql, filters: [], logicMode: .and
        ).hasPrefix("SELECT COUNT(*) FROM [sales].[orders]"))
    }

    @Test("a search select and count name the schema")
    func searchIsQualified() {
        let columns = [ColumnInfo(name: "note", typeName: "nvarchar", ordinalPosition: 0)]
        #expect(SQLBuilder.buildSearchSelect(
            table: "orders", schema: "sales", type: .mssql,
            searchText: "a", searchColumns: columns, limit: 10, offset: 0
        ).hasPrefix("SELECT * FROM [sales].[orders]"))
        #expect(SQLBuilder.buildSearchCount(
            table: "orders", schema: "sales", type: .mssql,
            searchText: "a", searchColumns: columns
        ).hasPrefix("SELECT COUNT(*) FROM [sales].[orders]"))
    }

    @Test("a nil schema leaves the identifier unqualified, for engines that have none")
    func nilSchemaStaysBare() {
        #expect(SQLBuilder.buildCount(table: "orders", schema: nil, type: .mysql)
            == "SELECT COUNT(*) FROM `orders`")
        #expect(SQLBuilder.buildCount(table: "orders", schema: "", type: .mysql)
            == "SELECT COUNT(*) FROM `orders`")
    }

    @Test("SQL Server's row writes and truncate name the window's database in front of the schema")
    func sqlServerWritesNameTheDatabase() {
        let key = [(column: "id", value: "1")]
        #expect(SQLBuilder.buildUpdate(
            table: "orders", schema: "dbo", database: "shop", type: .mssql, driver: driver(),
            changes: [(column: "note", value: "x")], primaryKeys: key, columns: []
        ).hasPrefix("UPDATE [shop].[dbo].[orders] SET"))
        #expect(SQLBuilder.buildDelete(
            table: "orders", schema: "dbo", database: "shop", type: .mssql, driver: driver(),
            primaryKeys: key, columns: []
        ).hasPrefix("DELETE FROM [shop].[dbo].[orders] WHERE"))
        #expect(SQLBuilder.buildInsert(
            table: "orders", schema: "dbo", database: "shop", type: .mssql, driver: driver(),
            columns: ["note"], values: ["x"]
        ) == "INSERT INTO [shop].[dbo].[orders] ([note]) VALUES (N'x')")
        #expect(SQLBuilder.buildInsert(
            table: "orders", schema: "dbo", database: "shop", type: .mssql, driver: driver(), columns: [], values: []
        ) == "INSERT INTO [shop].[dbo].[orders] DEFAULT VALUES")
        #expect(SQLBuilder.truncateStatement(table: "orders", schema: "dbo", database: "shop", type: .mssql)
            == "TRUNCATE TABLE [shop].[dbo].[orders]")
    }

    @Test("SQL Server's browse, count, filter, search and lookup reads name the window's database")
    func sqlServerReadsNameTheDatabase() {
        let columns = [ColumnInfo(name: "note", typeName: "nvarchar", ordinalPosition: 0)]
        let sorted = SortState(columns: [SortColumn(name: "note", ascending: true)])
        let table = "SELECT * FROM [shop].[dbo].[orders] "
        #expect(SQLBuilder.buildSelect(table: "orders", schema: "dbo", database: "shop", type: .mssql, limit: 10, offset: 0)
            .hasPrefix(table))
        #expect(SQLBuilder.buildSelect(
            table: "orders", schema: "dbo", database: "shop", type: .mssql, sortState: sorted, limit: 10, offset: 0
        ).hasPrefix(table))
        #expect(SQLBuilder.buildCount(table: "orders", schema: "dbo", database: "shop", type: .mssql)
            == "SELECT COUNT(*) FROM [shop].[dbo].[orders]")
        #expect(SQLBuilder.buildFilteredSelect(
            table: "orders", schema: "dbo", database: "shop", type: .mssql,
            filters: [], logicMode: .and, limit: 10, offset: 0
        ).hasPrefix(table))
        #expect(SQLBuilder.buildFilteredCount(
            table: "orders", schema: "dbo", database: "shop", type: .mssql, filters: [], logicMode: .and
        ) == "SELECT COUNT(*) FROM [shop].[dbo].[orders]")
        #expect(SQLBuilder.buildSearchSelect(
            table: "orders", schema: "dbo", database: "shop", type: .mssql,
            searchText: "a", searchColumns: columns, limit: 10, offset: 0
        ).hasPrefix(table))
        #expect(SQLBuilder.buildSearchCount(
            table: "orders", schema: "dbo", database: "shop", type: .mssql, searchText: "a", searchColumns: columns
        ).hasPrefix("SELECT COUNT(*) FROM [shop].[dbo].[orders] WHERE"))
        #expect(SQLBuilder.buildSingleRowLookup(
            table: "orders", schema: "dbo", database: "shop", key: [(column: "id", value: "1")], columns: [],
            type: .mssql, driver: driver()
        ).hasPrefix("SELECT * FROM [shop].[dbo].[orders] WHERE"))
    }

    @Test("SQL Server with a database and no schema reads the database's default schema")
    func sqlServerDatabaseWithoutSchema() {
        #expect(SQLBuilder.qualifiedIdentifier(table: "orders", schema: nil, database: "shop", for: .mssql)
            == "[shop]..[orders]")
        #expect(SQLBuilder.qualifiedIdentifier(table: "orders", schema: "", database: "shop", for: .mssql)
            == "[shop]..[orders]")
        #expect(SQLBuilder.qualifiedIdentifier(table: "orders", schema: "dbo", database: "", for: .mssql)
            == "[dbo].[orders]")
        #expect(SQLBuilder.qualifiedIdentifier(table: "orders", schema: "dbo", database: nil, for: .mssql)
            == "[dbo].[orders]")
    }

    @Test("A closing bracket in a SQL Server database name is doubled")
    func sqlServerQuotesTheDatabase() {
        #expect(SQLBuilder.qualifiedIdentifier(table: "orders", schema: "dbo", database: "shop]; DROP TABLE x --", for: .mssql)
            == "[shop]]; DROP TABLE x --].[dbo].[orders]")
    }

    @Test("MySQL and PostgreSQL ignore the database: MySQL's sits in the schema slot, PostgreSQL has no third part")
    func otherEnginesIgnoreTheDatabase() {
        #expect(SQLBuilder.qualifiedIdentifier(table: "orders", schema: "shop", database: "shop", for: .mysql)
            == "`shop`.`orders`")
        #expect(SQLBuilder.qualifiedIdentifier(table: "orders", schema: "public", database: "shop", for: .postgresql)
            == "\"public\".\"orders\"")
        #expect(SQLBuilder.buildDelete(
            table: "orders", schema: "shop", database: "staging", type: .mysql, driver: driver(),
            primaryKeys: [(column: "id", value: "1")], columns: []
        ).hasPrefix("DELETE FROM `shop`.`orders` WHERE"))
        #expect(SQLBuilder.truncateStatement(table: "orders", schema: "public", database: "shop", type: .postgresql)
            == "TRUNCATE TABLE \"public\".\"orders\"")
    }

    @Test("the qualifier follows each dialect's own quoting")
    func dialectQuoting() {
        #expect(SQLBuilder.qualifiedIdentifier(table: "orders", schema: "sales", for: .postgresql)
            == "\"sales\".\"orders\"")
        #expect(SQLBuilder.qualifiedIdentifier(table: "orders", schema: "sales", for: .mssql)
            == "[sales].[orders]")
        #expect(SQLBuilder.qualifiedIdentifier(table: "orders", schema: "sales", for: .mysql)
            == "`sales`.`orders`")
    }
}
