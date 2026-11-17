import Foundation
import TableProModels
import TableProQuery
import Testing
@testable import TableProMobile

struct SQLBuilderExportSelectTests {
    private let idFilter = [TableFilter(columnName: "id", filterOperator: .equal, value: "5")]
    private let sorted = SortState(columns: [SortColumn(name: "name", ascending: false)])

    @Test("A table export reads every row, with no page limit on any engine")
    func exportSelectHasNoPagination() {
        for type in [DatabaseType.postgresql, .mysql, .mssql, .oracle, .sqlite, .clickhouse] {
            let sql = SQLBuilder.buildExportSelect(table: "orders", schema: nil, type: type)
            #expect(!sql.contains("LIMIT"), "\(type.rawValue)")
            #expect(!sql.contains("FETCH NEXT"), "\(type.rawValue)")
            #expect(!sql.contains("OFFSET"), "\(type.rawValue)")
        }
        #expect(SQLBuilder.buildExportSelect(table: "orders", schema: "public", type: .postgresql)
            == "SELECT * FROM \"public\".\"orders\"")
    }

    @Test("The browser's filter and sort carry over, as the export of a filtered view")
    func exportSelectKeepsFilterAndSort() {
        #expect(SQLBuilder.buildExportSelect(
            table: "orders", schema: nil, type: .mssql, filters: idFilter, sortState: sorted
        ) == "SELECT * FROM [orders] WHERE ([id] = 5) ORDER BY [name] DESC")
    }

    @Test("A search narrows the export the way it narrows the page")
    func exportSelectKeepsSearch() {
        let columns = [ColumnInfo(name: "name", typeName: "text", ordinalPosition: 0)]
        let sql = SQLBuilder.buildExportSelect(
            table: "people", schema: nil, type: .postgresql, searchText: "ada", searchColumns: columns
        )
        #expect(sql.hasPrefix("SELECT * FROM \"people\" WHERE (CAST(\"name\" AS TEXT) ILIKE '%ada%'"))
    }

    @Test("Selected rows are read again by each one's whole key")
    func rowsSelectMatchesEveryKey() {
        let columns = [
            ColumnInfo(name: "tenant", typeName: "integer", isPrimaryKey: true, ordinalPosition: 0),
            ColumnInfo(name: "id", typeName: "integer", isPrimaryKey: true, ordinalPosition: 1)
        ]
        let sql = SQLBuilder.buildRowsSelect(
            table: "orders", schema: "public", type: .postgresql,
            keys: [[(column: "tenant", value: "1"), (column: "id", value: "7")], [(column: "tenant", value: "2"), (column: "id", value: "7")]],
            columns: columns, driver: MockDatabaseDriver()
        )
        #expect(sql == "SELECT * FROM \"public\".\"orders\" WHERE (\"tenant\" = 1 AND \"id\" = 7) OR (\"tenant\" = 2 AND \"id\" = 7)")
        #expect(SQLBuilder.buildRowsSelect(
            table: "orders", schema: nil, type: .postgresql, keys: [], columns: columns, driver: MockDatabaseDriver()
        ) == "SELECT * FROM \"orders\" WHERE 1 = 0")
    }
}
