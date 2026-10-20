import Foundation
import TableProModels
import TableProQuery
import Testing
@testable import TableProMobile

struct SQLBuilderFilterLiteralTests {
    private let idFilter = [TableFilter(columnName: "id", filterOperator: .equal, value: "5")]
    private let codeFilter = [TableFilter(columnName: "code", filterOperator: .equal, value: "02134")]
    private let codeColumns = [ColumnInfo(name: "code", typeName: "TEXT")]
    private let sorted = SortState(columns: [SortColumn(name: "id", ascending: true)])

    @Test("A SQL Server filtered select and count close the bracket around the column")
    func mssqlFilteredSelectAndCount() {
        #expect(SQLBuilder.buildFilteredSelect(
            table: "orders", schema: nil, type: .mssql,
            filters: idFilter, logicMode: .and, limit: 10, offset: 0
        ).hasPrefix("SELECT * FROM [orders] WHERE [id] = 5 "))
        #expect(SQLBuilder.buildFilteredSelect(
            table: "orders", schema: nil, type: .mssql,
            filters: idFilter, logicMode: .and, sortState: sorted, limit: 10, offset: 0
        ).hasPrefix("SELECT * FROM [orders] WHERE [id] = 5 ORDER BY [id] ASC"))
        #expect(SQLBuilder.buildFilteredCount(
            table: "orders", schema: nil, type: .mssql, filters: idFilter, logicMode: .and
        ) == "SELECT COUNT(*) FROM [orders] WHERE [id] = 5")
    }

    @Test("A SQL Server search with a filter closes the bracket around the column")
    func mssqlSearchSelectAndCount() {
        #expect(SQLBuilder.buildSearchSelect(
            table: "orders", schema: nil, type: .mssql,
            searchText: "", searchColumns: [], filters: idFilter, limit: 10, offset: 0
        ).hasPrefix("SELECT * FROM [orders] WHERE ([id] = 5) "))
        #expect(SQLBuilder.buildSearchCount(
            table: "orders", schema: nil, type: .mssql,
            searchText: "", searchColumns: [], filters: idFilter
        ) == "SELECT COUNT(*) FROM [orders] WHERE ([id] = 5)")
    }

    @Test("Every filtered and search builder hands the column types to the filter")
    func columnsReachTheFilter() {
        let quoted = "\"code\" = '02134'"
        #expect(SQLBuilder.buildFilteredSelect(
            table: "zips", schema: nil, type: .sqlite,
            filters: codeFilter, logicMode: .and, columns: codeColumns, limit: 10, offset: 0
        ).contains(quoted))
        #expect(SQLBuilder.buildFilteredSelect(
            table: "zips", schema: nil, type: .sqlite,
            filters: codeFilter, logicMode: .and, columns: codeColumns, sortState: sorted, limit: 10, offset: 0
        ).contains(quoted))
        #expect(SQLBuilder.buildFilteredCount(
            table: "zips", schema: nil, type: .sqlite,
            filters: codeFilter, logicMode: .and, columns: codeColumns
        ).contains(quoted))
        #expect(SQLBuilder.buildSearchSelect(
            table: "zips", schema: nil, type: .sqlite,
            searchText: "", searchColumns: [], filters: codeFilter, columns: codeColumns, limit: 10, offset: 0
        ).contains(quoted))
        #expect(SQLBuilder.buildSearchCount(
            table: "zips", schema: nil, type: .sqlite,
            searchText: "", searchColumns: [], filters: codeFilter, columns: codeColumns
        ).contains(quoted))
    }

    @Test("A MySQL filter value ending in a backslash leaves the literal closed")
    func mysqlTrailingBackslash() {
        let filters = [TableFilter(columnName: "path", filterOperator: .equal, value: "C:\\temp\\")]
        #expect(SQLBuilder.buildFilteredCount(
            table: "files", schema: nil, type: .mysql, filters: filters, logicMode: .and
        ) == "SELECT COUNT(*) FROM `files` WHERE `path` = 'C:\\\\temp\\\\'")
    }

    private func count(_ type: DatabaseType, _ filter: TableFilter, _ column: ColumnInfo) -> String {
        SQLBuilder.buildFilteredCount(table: "t", schema: nil, type: type, filters: [filter], logicMode: .and, columns: [column])
    }

    // Open Table on a PostgreSQL bit(3) key ran `"b" = 101`, which has no operator, and the browser showed the error.
    @Test("A PostgreSQL bit or boolean filter compares a quoted value")
    func postgresBitAndBooleanAreQuoted() {
        let bit = ColumnInfo(name: "b", typeName: "bit")
        #expect(count(.postgresql, TableFilter(columnName: "b", value: "101"), bit) == "SELECT COUNT(*) FROM \"t\" WHERE \"b\" = '101'")
        let flag = ColumnInfo(name: "f", typeName: "boolean")
        #expect(count(.postgresql, TableFilter(columnName: "f", value: "1"), flag) == "SELECT COUNT(*) FROM \"t\" WHERE \"f\" = '1'")
    }

    @Test("Contains on a non-character column reads it as the engine's text type")
    func patternOnNonCharacterColumnIsCast() {
        let id = ColumnInfo(name: "id", typeName: "integer")
        let contains = TableFilter(columnName: "id", filterOperator: .contains, value: "5")
        #expect(count(.postgresql, contains, id).hasSuffix("WHERE CAST(\"id\" AS TEXT) LIKE '%5%' ESCAPE '!'"))
        #expect(count(.duckdb, contains, ColumnInfo(name: "id", typeName: "INTEGER"))
            .hasSuffix("WHERE CAST(\"id\" AS VARCHAR) LIKE '%5%' ESCAPE '!'"))
        #expect(count(.mysql, contains, id).hasSuffix("WHERE `id` LIKE '%5%'"))
        let uuid = TableFilter(columnName: "u", filterOperator: .contains, value: "a0")
        #expect(count(.postgresql, uuid, ColumnInfo(name: "u", typeName: "uuid"))
            .hasSuffix("WHERE CAST(\"u\" AS TEXT) ILIKE '%a0%' ESCAPE '!'"))
        let day = TableFilter(columnName: "d", filterOperator: .contains, value: "2026")
        #expect(count(.redshift, day, ColumnInfo(name: "d", typeName: "date"))
            .hasSuffix("WHERE LOWER(CAST(\"d\" AS TEXT)) LIKE LOWER('%2026%') ESCAPE '!'"))
        let name = ColumnInfo(name: "name", typeName: "character varying")
        #expect(count(.postgresql, TableFilter(columnName: "name", filterOperator: .contains, value: "a"), name)
            .hasSuffix("WHERE \"name\" ILIKE '%a%' ESCAPE '!'"))
    }
}

