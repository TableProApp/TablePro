import Foundation
import TableProModels
import Testing
@testable import TableProMobile

@Suite("ClipboardExporter round-trip fidelity")
struct ClipboardExporterFidelityTests {
    private let columns = [
        ColumnInfo(name: "id", typeName: "INT", ordinalPosition: 0),
        ColumnInfo(name: "zip", typeName: "VARCHAR(10)", ordinalPosition: 1),
        ColumnInfo(name: "note", typeName: "TEXT", ordinalPosition: 2)
    ]

    private func csv(_ row: [String?]) -> String {
        ClipboardExporter.exportRows(
            columns: columns, rows: [row], format: .csv,
            tableName: "t", databaseType: .postgresql, driver: nil
        )
    }

    private func json(_ row: [String?]) -> String {
        ClipboardExporter.exportRow(
            columns: columns, row: row, format: .json,
            tableName: "t", databaseType: .postgresql, driver: nil
        )
    }

    private func insert(_ row: [String?], _ type: DatabaseType) -> String {
        ClipboardExporter.exportRow(
            columns: columns, row: row, format: .sqlInsert,
            tableName: "t", databaseType: type, driver: nil
        )
    }

    // MARK: - CSV

    @Test("a NULL and the text NULL do not export the same way")
    func nullIsDistinguishable() {
        let withNull = csv(["1", nil, "x"])
        let withText = csv(["1", "NULL", "x"])
        #expect(withNull != withText)
        #expect(withNull.hasSuffix("1,,x"))
        #expect(withText.hasSuffix("1,\"NULL\",x"))
    }

    @Test("an empty string is quoted so it does not read as NULL")
    func emptyStringIsQuoted() {
        #expect(csv(["1", "", "x"]).hasSuffix("1,\"\",x"))
    }

    @Test("a field with a comma, quote or newline still escapes")
    func csvEscaping() {
        #expect(csv(["1", "a,b", "x"]).hasSuffix("1,\"a,b\",x"))
        #expect(csv(["1", "a\"b", "x"]).hasSuffix("1,\"a\"\"b\",x"))
    }

    // MARK: - JSON

    @Test("a leading-zero string stays a string, so the JSON parses")
    func leadingZeroStaysAString() throws {
        let text = json(["1", "01234", "x"])
        #expect(text.contains("\"zip\": \"01234\""))
        let data = try #require(text.data(using: .utf8))
        _ = try JSONSerialization.jsonObject(with: data)
    }

    @Test("values a JSON parser would reject unquoted stay quoted")
    func nonJsonNumbersStayStrings() throws {
        for value in ["+5", "0x10", "1.", ".5", "1e", "Infinity", "NaN", " 1", "\u{0661}\u{0662}\u{0663}"] {
            let text = json(["1", value, "x"])
            let data = try #require(text.data(using: .utf8))
            _ = try JSONSerialization.jsonObject(with: data)
            #expect(text.contains("\"zip\": \"\(value)\""), "\(value) should stay quoted")
        }
    }

    @Test("real numbers are still emitted unquoted")
    func realNumbersStayNumbers() {
        #expect(json(["1", "0", "x"]).contains("\"zip\": 0"))
        #expect(json(["1", "-12", "x"]).contains("\"zip\": -12"))
        #expect(json(["1", "1.5", "x"]).contains("\"zip\": 1.5"))
        #expect(json(["1", "1e10", "x"]).contains("\"zip\": 1e10"))
    }

    @Test("a NULL is emitted as JSON null")
    func jsonNull() {
        #expect(json(["1", nil, "x"]).contains("\"zip\": null"))
    }

    @Test("control characters are escaped, so the JSON parses and keeps them")
    func controlCharactersEscape() throws {
        let values = ["form\u{0C}feed", "bell\u{07}", "esc\u{1B}[0m", "unit\u{1F}separator"]
        for value in values {
            let text = json(["1", value, "x"])
            let data = try #require(text.data(using: .utf8))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["zip"] as? String == value)
        }
    }

    // MARK: - Cells

    @Test("a cut or binary cell throws and names its column, in every format")
    func incompleteCellsThrow() {
        let cells: [Cell] = [
            .text("1"),
            .truncatedText(prefix: "abc", totalBytes: 5_000, ref: nil),
            .binary(byteCount: 16, ref: nil)
        ]
        for format in ExportFormat.allCases {
            #expect(throws: ClipboardExporter.IncompleteValues(columns: ["zip", "note"])) {
                try ClipboardExporter.exportRow(
                    columns: columns, cells: cells, format: format,
                    tableName: "t", databaseType: .postgresql, driver: nil
                )
            }
        }
    }

    @Test("a cut cell that carries a ref still throws, since only its prefix is here")
    func cutCellWithRefThrows() {
        let ref = CellRef(table: "t", column: "note", primaryKey: [PrimaryKeyComponent(column: "id", value: "1")])
        let cells: [Cell] = [.text("1"), .text("a"), .truncatedText(prefix: "abc", totalBytes: 5_000, ref: ref)]
        #expect(ClipboardExporter.incompleteColumns(columns: columns, cells: cells) == ["note"])
        #expect(throws: ClipboardExporter.IncompleteValues(columns: ["note"])) {
            try ClipboardExporter.exportRow(
                columns: columns, cells: cells, format: .sqlInsert,
                tableName: "t", databaseType: .postgresql, driver: nil
            )
        }
    }

    @Test("rows name each incomplete column once, in column order")
    func incompleteRowsNameColumnsOnce() {
        let rows: [[Cell]] = [
            [.text("1"), .text("a"), .binary(byteCount: 4, ref: nil)],
            [.text("2"), .truncatedText(prefix: "a", totalBytes: 5_000, ref: nil), .binary(byteCount: 4, ref: nil)]
        ]
        #expect(throws: ClipboardExporter.IncompleteValues(columns: ["zip", "note"])) {
            try ClipboardExporter.exportRows(
                columns: columns, rows: rows, format: .csv,
                tableName: "t", databaseType: .postgresql, driver: nil
            )
        }
    }

    @Test("the error message names the columns")
    func incompleteValuesNamesColumns() throws {
        let message = try #require(ClipboardExporter.IncompleteValues(columns: ["zip", "note"]).errorDescription)
        #expect(message.contains("zip"))
        #expect(message.contains("note"))
    }

    @Test("a loaded long value exports whole, with no size suffix")
    func loadedValueExportsWhole() throws {
        let long = String(repeating: "x", count: 5_000)
        let cells: [Cell] = [.text("1"), .null, .text(long)]
        #expect(ClipboardExporter.incompleteColumns(columns: columns, cells: cells).isEmpty)

        let insert = try ClipboardExporter.exportRow(
            columns: columns, cells: cells, format: .sqlInsert,
            tableName: "t", databaseType: .postgresql, driver: nil
        )
        #expect(insert == "INSERT INTO \"t\" (\"id\", \"zip\", \"note\") VALUES ('1', NULL, '\(long)');")

        let text = try ClipboardExporter.exportRows(
            columns: columns, rows: [cells], format: .json,
            tableName: "t", databaseType: .postgresql, driver: nil
        )
        let data = try #require(text.data(using: .utf8))
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.first?["note"] as? String == long)
        #expect(objects.first?["zip"] is NSNull)
    }

    // MARK: - SQL INSERT

    @Test("identifiers are quoted for the dialect, not always ANSI")
    func identifierQuoting() {
        #expect(insert(["1", "a", "b"], .mysql).hasPrefix("INSERT INTO `t` (`id`, `zip`, `note`)"))
        #expect(insert(["1", "a", "b"], .postgresql).hasPrefix("INSERT INTO \"t\" (\"id\", \"zip\", \"note\")"))
        #expect(insert(["1", "a", "b"], .mssql).hasPrefix("INSERT INTO [t] ([id], [zip], [note])"))
    }

    @Test("MySQL escapes a backslash, ANSI dialects do not")
    func literalEscaping() {
        #expect(insert(["1", #"a\b"#, "c"], .mysql).contains(#"'a\\b'"#))
        #expect(insert(["1", #"a\b"#, "c"], .tidb).contains(#"'a\\b'"#))
        #expect(insert(["1", #"a\b"#, "c"], .postgresql).contains(#"'a\b'"#))
        #expect(insert(["1", "it's", "c"], .postgresql).contains("'it''s'"))
    }

    @Test("a NULL stays the NULL keyword rather than a quoted string")
    func insertNull() {
        #expect(insert(["1", nil, "c"], .postgresql).contains(", NULL, "))
    }
}
