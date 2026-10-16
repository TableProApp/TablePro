import Foundation
import Testing
@testable import TablePro

@MainActor
struct ParseSchemaMetadataTests {
    private func column(_ name: String, comment: String?) -> ColumnInfo {
        ColumnInfo(
            name: name,
            dataType: "TEXT",
            isNullable: true,
            isPrimaryKey: false,
            comment: comment
        )
    }

    @Test("Populates columnComments from non-empty ColumnInfo comments")
    func populatesComments() {
        let schema = FetchedTableSchema(
            columns: [column("id", comment: "Primary key"), column("name", comment: "Display name")],
            foreignKeys: nil,
            approximateRowCount: nil
        )
        let parsed = QueryExecutor.parseSchemaMetadata(schema)
        #expect(parsed.columnComments == ["id": "Primary key", "name": "Display name"])
    }

    @Test("Excludes nil and empty comments")
    func excludesNilAndEmpty() {
        let schema = FetchedTableSchema(
            columns: [column("id", comment: nil), column("name", comment: ""), column("email", comment: "Contact")],
            foreignKeys: nil,
            approximateRowCount: nil
        )
        let parsed = QueryExecutor.parseSchemaMetadata(schema)
        #expect(parsed.columnComments == ["email": "Contact"])
    }

    @Test("Keeps each column's declared type, which a result set can report without its length")
    func keepsDeclaredTypes() {
        let schema = FetchedTableSchema(
            columns: [
                ColumnInfo(name: "id", dataType: "CHAR(32)", isNullable: false, isPrimaryKey: true),
                ColumnInfo(name: "name", dataType: "VARCHAR(80)", isNullable: true, isPrimaryKey: false),
            ],
            foreignKeys: nil,
            approximateRowCount: nil
        )
        let parsed = QueryExecutor.parseSchemaMetadata(schema)
        #expect(parsed.columnDeclaredTypes == ["id": "CHAR(32)", "name": "VARCHAR(80)"])

        var rows = TableRows.from(queryRows: [], columns: ["id", "name"], columnTypes: [.text(rawType: "CHAR"), .text(rawType: "VARCHAR")])
        #expect(rows.updateDisplayMetadata(columnDeclaredTypes: parsed.columnDeclaredTypes) == .columnsReplaced)
        #expect(rows.declaredType(at: 0) == "CHAR(32)")
        #expect(ParsedSchemaMetadata.cached(rows: rows, primaryKeyColumns: ["id"]).columnDeclaredTypes == parsed.columnDeclaredTypes)
    }

    @Test("Returns an empty dictionary when no column has a comment")
    func emptyWhenNoComments() {
        let schema = FetchedTableSchema(
            columns: [column("id", comment: nil), column("name", comment: nil)],
            foreignKeys: nil,
            approximateRowCount: nil
        )
        let parsed = QueryExecutor.parseSchemaMetadata(schema)
        #expect(parsed.columnComments.isEmpty)
    }
}
