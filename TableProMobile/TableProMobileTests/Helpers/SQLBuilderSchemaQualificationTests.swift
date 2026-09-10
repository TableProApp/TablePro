import Foundation
import TableProModels
import TableProQuery
import Testing
@testable import TableProMobile

/// SQL Server has no session-level schema to set, so every data statement has to name the schema
/// the toolbar shows. An unqualified one resolves against the login's default schema, which is a
/// different table of the same name.
@Suite("SQLBuilder schema qualification")
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
            primaryKeys: [(column: "id", value: "1")]
        )
        #expect(sql.hasPrefix("DELETE FROM [sales].[orders] WHERE"))
    }

    @Test("an update names the schema")
    func updateIsQualified() {
        let sql = SQLBuilder.buildUpdate(
            table: "orders", schema: "sales", type: .mssql, driver: driver(),
            changes: [(column: "note", value: "x")],
            primaryKeys: [(column: "id", value: "1")]
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
