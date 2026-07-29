import Foundation
import Testing
@testable import TablePro

@Suite("QueryExecutor.parseSchemaMetadata - column comments")
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
