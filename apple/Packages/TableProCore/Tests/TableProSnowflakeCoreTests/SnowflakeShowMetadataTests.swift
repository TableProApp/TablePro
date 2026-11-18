//
//  SnowflakeShowMetadataTests.swift
//  TableProSnowflakeCoreTests
//

import TableProSnowflakeCore
import Testing

struct SnowflakeShowMetadataTests {
    private static let columnHeader = [
        "table_name", "schema_name", "column_name", "data_type", "null?", "default", "kind", "expression", "comment"
    ]

    private func columnRow(
        _ name: String,
        type: String,
        null: String = "true",
        defaultValue: String = "",
        comment: String = ""
    ) -> [String?] {
        ["T", "S", name, type, null, defaultValue, "COLUMN", "", comment]
    }

    private func columns(_ rows: [[String?]]) -> [SnowflakeShownColumn]? {
        SnowflakeShowMetadata.columns(from: SnowflakeShowRows(columns: Self.columnHeader, rows: rows))
    }

    @Test("Internal type names read as the names INFORMATION_SCHEMA reports", arguments: [
        (#"{"type":"FIXED","precision":38,"scale":0,"nullable":true}"#, "NUMBER"),
        (#"{"type":"REAL","nullable":true}"#, "FLOAT"),
        (#"{"type":"TEXT","length":16777216,"byteLength":16777216,"nullable":true,"fixed":false}"#, "TEXT"),
        (#"{"type":"TIMESTAMP_NTZ","precision":0,"scale":9,"nullable":true}"#, "TIMESTAMP_NTZ"),
        (#"{"type":"VARIANT","nullable":true}"#, "VARIANT"),
        (#"{"type":"boolean","nullable":true}"#, "BOOLEAN")
    ])
    func mapsTypeNames(json: String, expected: String) {
        #expect(columns([columnRow("A", type: json)])?.first?.dataType == expected)
    }

    @Test("Columns keep the order the server listed them in")
    func keepsServerOrder() {
        let read = columns([
            columnRow("Z", type: #"{"type":"TEXT"}"#),
            columnRow("A", type: #"{"type":"TEXT"}"#)
        ])
        #expect(read?.map(\.name) == ["Z", "A"])
    }

    @Test("Nullability comes from the type, then from the null? column")
    func readsNullability() {
        let read = columns([
            columnRow("A", type: #"{"type":"TEXT","nullable":false}"#, null: "true"),
            columnRow("B", type: #"{"type":"TEXT"}"#, null: "false"),
            columnRow("C", type: #"{"type":"TEXT"}"#, null: "true")
        ])
        #expect(read?.map(\.isNullable) == [false, false, true])
    }

    @Test("An empty default or comment is no default or comment")
    func emptyTextIsAbsent() {
        let read = columns([
            columnRow("A", type: #"{"type":"TEXT"}"#),
            columnRow("B", type: #"{"type":"TEXT"}"#, defaultValue: "'x'", comment: "note")
        ])
        #expect(read?[0].defaultValue == nil)
        #expect(read?[0].comment == nil)
        #expect(read?[1].defaultValue == "'x'")
        #expect(read?[1].comment == "note")
    }

    @Test("An answer that cannot be read falls back", arguments: [
        [[String?]](),
        [["T", "S", "A", "not json", "true", "", "COLUMN", "", ""]],
        [["T", "S", nil, #"{"type":"TEXT"}"#, "true", "", "COLUMN", "", ""]]
    ])
    func unreadableAnswerIsNil(rows: [[String?]]) {
        #expect(columns(rows) == nil)
    }

    @Test("An answer missing the expected columns falls back")
    func missingHeaderIsNil() {
        let result = SnowflakeShowRows(columns: ["name"], rows: [["A"]])
        #expect(SnowflakeShowMetadata.columns(from: result) == nil)
    }

    private static let tableHeader = ["created_on", "name", "comment", "cluster_by", "rows", "bytes"]

    @Test("A table is read from the row with its exact name")
    func matchesExactTableName() {
        let result = SnowflakeShowRows(columns: Self.tableHeader, rows: [
            ["d", "ORDERS", "upper", "LINEAR(A)", "9", "90"],
            ["d", "orders", "", "", "5", "50"]
        ])

        let table = SnowflakeShowMetadata.table(named: "orders", in: result)
        #expect(table?.rowCount == 5)
        #expect(table?.bytes == 50)
        #expect(table?.comment == nil)
        #expect(table?.clusterBy == nil)
    }

    @Test("A pattern that matched only another spelling is no answer")
    func otherSpellingIsNil() {
        let result = SnowflakeShowRows(columns: Self.tableHeader, rows: [["d", "ORDERS", "", "", "9", "90"]])
        #expect(SnowflakeShowMetadata.table(named: "orders", in: result) == nil)
    }

    @Test("Counts the server does not report stay absent")
    func missingCountsAreNil() {
        let result = SnowflakeShowRows(columns: Self.tableHeader, rows: [["d", "T", "", "", nil, ""]])
        let table = SnowflakeShowMetadata.table(named: "T", in: result)
        #expect(table?.rowCount == nil)
        #expect(table?.bytes == nil)
    }
}
