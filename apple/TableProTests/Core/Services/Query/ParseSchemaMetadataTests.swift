import Foundation
import TableProPluginKit
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

    @Test("An editable view is keyed on the view columns its driver named, which carry no key of their own")
    func editableViewSuppliesKeys() {
        var schema = FetchedTableSchema(
            columns: [column("key_id", comment: nil), column("name", comment: nil)],
            foreignKeys: nil,
            approximateRowCount: nil
        )
        let answer = PluginViewRowEditing.editable(TestFixtures.viewTarget(keys: ["key_id"]))
        schema.viewRowEditing = answer
        let parsed = QueryExecutor.parseSchemaMetadata(schema)
        #expect(parsed.primaryKeyColumns == ["key_id"])
        #expect(parsed.viewRowEditing == answer)
    }

    @Test("A read-only view keeps no key and carries its reason")
    func readOnlyViewHasNoKeys() {
        var schema = FetchedTableSchema(columns: [column("name", comment: nil)], foreignKeys: nil, approximateRowCount: nil)
        schema.viewRowEditing = .readOnly(.readsSeveralTables)
        let parsed = QueryExecutor.parseSchemaMetadata(schema)
        #expect(parsed.primaryKeyColumns.isEmpty)
        #expect(parsed.viewRowEditing == .readOnly(.readsSeveralTables))
    }

    @Test("A view's computed and server-owned columns are never written, and its base table's defaults apply")
    func editableViewTakesItsBaseColumns() {
        var schema = FetchedTableSchema(
            columns: ["id", "name", "q2", "ident", "note"].map { column($0, comment: nil) },
            foreignKeys: nil,
            approximateRowCount: nil
        )
        let serial = PluginViewBaseColumn(
            name: "id", isNullable: false, defaultValue: "nextval('t_id_seq')", assignsValue: false, acceptsWrites: true
        )
        let name = PluginViewBaseColumn(
            name: "name", isNullable: false, defaultValue: nil, assignsValue: false, acceptsWrites: true
        )
        let ident = PluginViewBaseColumn(
            name: "ident", isNullable: false, defaultValue: nil, assignsValue: true, acceptsWrites: false
        )
        let note = PluginViewBaseColumn(
            name: "note", isNullable: true, defaultValue: "'n/a'", assignsValue: false, acceptsWrites: true
        )
        schema.viewRowEditing = .editable(TestFixtures.viewTarget(
            keys: ["id"],
            readOnly: ["q2", "ident"],
            baseColumnNames: ["id": "id", "name": "name", "ident": "ident", "note": "note"],
            baseColumns: ["id": serial, "name": name, "ident": ident, "note": note]
        ))
        let parsed = QueryExecutor.parseSchemaMetadata(schema)
        #expect(parsed.generatedColumns == ["q2", "ident"])
        #expect((parsed.columnDefaults["id"] ?? nil) == "nextval('t_id_seq')")
        #expect((parsed.columnDefaults["note"] ?? nil) == "'n/a'")
        #expect(parsed.columnNullable["name"] == false)
        #expect(parsed.columnIdentity["ident"] == .always)
        #expect(parsed.columnIdentity["name"] == nil)
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
