//
//  OracleRowWriterTests.swift
//  TableProTests
//
//  The Oracle plugin's grid save statements. Every shape below was run against Oracle 23ai, with real VARCHAR2 and
//  RAW binds, under the default NLS_DATE_FORMAT DD-MON-RR: the masked dates and timestamps, the suffixed binary
//  literals, the NULL literal into an object column and the keyless match all write or find the row.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct OracleRowWriterTests {
    private static let columns = ["ID", "D", "T", "TZ", "TL", "N", "BF", "BD", "R", "V", "O", "CL"]
    private static let typeNames = [
        "ID": "NUMBER", "D": "DATE", "T": "TIMESTAMP(3)", "TZ": "TIMESTAMP(6) WITH TIME ZONE",
        "TL": "TIMESTAMP(6) WITH LOCAL TIME ZONE", "N": "NUMBER(10,2)", "BF": "BINARY_FLOAT", "BD": "BINARY_DOUBLE",
        "R": "RAW(16)", "V": "VARCHAR2(20 CHAR)", "O": "\"HR\".\"ADDR\"", "CL": "CLOB"
    ]

    private static let original: [PluginCellValue] = [
        .text("7"), .text("2026-10-06 15:22:20"), .text("2026-10-06 15:22:20.050"),
        .text("2026-10-06 15:22:20.000001+02:00"), .text("2026-10-06 23:15:03.444429"), .text("123.45"),
        .text("1.5"), .text("inf"), .bytes(Data([0xDE, 0xAD])), .text("abc"), .null, .null
    ]

    private func writer(
        keys: [String] = ["ID"],
        columns: [String] = OracleRowWriterTests.columns,
        typeNames: [String: String] = OracleRowWriterTests.typeNames,
        configure: (inout PluginRowWriteContext) -> Void = { _ in }
    ) -> OracleRowWriter {
        var context = PluginRowWriteContext()
        context.columnTypeNames = typeNames
        configure(&context)
        var writer = OracleRowWriter(qualifiedTable: "\"T1\"", columns: columns, primaryKeyColumns: keys)
        writer.context = context
        return writer
    }

    private func update(
        _ column: String,
        to value: PluginCellValue,
        row: Int = 0,
        original: [PluginCellValue]? = OracleRowWriterTests.original
    ) -> PluginRowChange {
        let index = Self.columns.firstIndex(of: column) ?? 0
        let old = original.map { $0[index] } ?? .null
        return PluginRowChange(
            rowIndex: row,
            type: .update,
            cellChanges: [(columnIndex: index, columnName: column, oldValue: old, newValue: value)],
            originalRow: original
        )
    }

    private func updates(_ writer: OracleRowWriter, _ changes: [PluginRowChange]) throws -> [PluginRowWrite] {
        try writer.rowWrites(for: changes, insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: [])
    }

    private func insert(_ writer: OracleRowWriter, _ values: [PluginCellValue]) throws -> PluginRowWrite? {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        return try writer.rowWrites(
            for: [change], insertedRowData: [0: values], deletedRowIndices: [], insertedRowIndices: [0]
        ).first
    }

    private func deletes(_ writer: OracleRowWriter, rows: [[PluginCellValue]]) throws -> [PluginRowWrite] {
        let changes = rows.enumerated().map { index, row in
            PluginRowChange(rowIndex: index, type: .delete, cellChanges: [], originalRow: row)
        }
        return try writer.rowWrites(
            for: changes, insertedRowData: [:], deletedRowIndices: Set(changes.map { $0.rowIndex }),
            insertedRowIndices: []
        )
    }

    // MARK: - Row match

    @Test("A keyed row is found by its primary key alone")
    func keyedMatch() throws {
        let write = try #require(try updates(writer(), [update("V", to: .text("new"))]).first)
        #expect(write.statement == "UPDATE \"T1\" SET \"V\" = 'new' WHERE \"ID\" = 7")
        #expect(write.parameters.isEmpty)
        #expect(write.rowIndices == [0])
    }

    @Test("A keyless row is found by every column, NULLs with IS NULL, and one row at most")
    func keylessMatch() throws {
        let columns = ["A", "B", "C"]
        let keyless = writer(keys: [], columns: columns, typeNames: ["A": "NUMBER", "B": "VARCHAR2(5 BYTE)", "C": "DATE"])
        let change = PluginRowChange(
            rowIndex: 3,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "B", oldValue: .text("x"), newValue: .text("y"))],
            originalRow: [.text("1"), .text("x"), .null]
        )
        let write = try #require(try updates(keyless, [change]).first)
        #expect(write.statement == "UPDATE \"T1\" SET \"B\" = 'y' WHERE \"A\" = 1 AND \"B\" = 'x' AND \"C\" IS NULL AND ROWNUM = 1")
        #expect(write.parameters.isEmpty)
    }

    @Test("A keyless match that needs an excluded column is refused, and a NULL one is matched")
    func keylessExcludedColumn() throws {
        let columns = ["A", "NOTE"]
        let keyless = writer(keys: [], columns: columns, typeNames: ["A": "NUMBER"]) { $0.rowMatchExcludedColumns = ["NOTE"] }
        let needed = PluginRowChange(
            rowIndex: 4,
            type: .update,
            cellChanges: [(columnIndex: 0, columnName: "A", oldValue: .text("1"), newValue: .text("2"))],
            originalRow: [.text("1"), .text("long text")]
        )
        #expect(throws: PluginRowWriteRefusal.self) { try updates(keyless, [needed]) }
        do {
            _ = try updates(keyless, [needed])
        } catch let refusal as PluginRowWriteRefusal {
            #expect(refusal.rowIndex == 4)
        }

        let nullNote = PluginRowChange(
            rowIndex: 5,
            type: .update,
            cellChanges: [(columnIndex: 0, columnName: "A", oldValue: .text("1"), newValue: .text("2"))],
            originalRow: [.text("1"), .null]
        )
        let write = try #require(try updates(keyless, [nullNote]).first)
        #expect(write.statement == "UPDATE \"T1\" SET \"A\" = 2 WHERE \"A\" = 1 AND \"NOTE\" IS NULL AND ROWNUM = 1")
    }

    /// CLOB fails `=` with ORA-22848 and a JSON column compared with its own text matches nothing.
    @Test("A keyless match refuses a LOB, JSON or object value even when the host excluded nothing")
    func keylessUncomparableTypes() {
        for typeName in ["CLOB", "JSON", "BLOB", "LONG", "VECTOR(3, FLOAT32)", "\"HR\".\"ADDR\"", "object"] {
            let keyless = writer(keys: [], columns: ["A", "X"], typeNames: ["A": "NUMBER", "X": typeName])
            let change = PluginRowChange(
                rowIndex: 0,
                type: .delete,
                cellChanges: [],
                originalRow: [.text("1"), .text("value")]
            )
            #expect(throws: PluginRowWriteRefusal.self, "\(typeName)") {
                try keyless.rowWrites(for: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: [])
            }
        }
    }

    @Test("A keyed row whose key is not loaded is refused")
    func keyedMissingKey() {
        var original = Self.original
        original[0] = .null
        #expect(throws: PluginRowWriteRefusal.self) {
            try updates(writer(), [update("V", to: .text("x"), original: original)])
        }
    }

    @Test("An update with no cell changes writes nothing and refuses nothing")
    func emptyUpdate() throws {
        let probe = PluginRowChange(rowIndex: 0, type: .update, cellChanges: [], originalRow: nil)
        #expect(try updates(writer(), [probe]).isEmpty)
        #expect(try updates(OracleRowWriter(qualifiedTable: "\"T1\"", columns: [], primaryKeyColumns: []), [probe]).isEmpty)
    }

    // MARK: - Values

    /// Bound bare, the same text fails with ORA-01861 under the default DD-MON-RR.
    @Test("Dates and timestamps are converted with explicit masks")
    func temporalMasks() throws {
        let columns = ["D", "T", "TZ", "TL"]
        let values: [PluginCellValue] = [
            .text("2026-10-06 15:22:20"), .text("2026-10-06 15:22:20.05"),
            .text("2026-10-06 15:22:20.000001+02:00"), .text("2026-10-06 08:04:05.123456+07:00")
        ]
        let expected = "INSERT INTO \"T1\" (\"D\", \"T\", \"TZ\", \"TL\") VALUES ("
            + "TO_DATE('2026-10-06 15:22:20', 'YYYY-MM-DD HH24:MI:SS'), "
            + "TO_TIMESTAMP('2026-10-06 15:22:20.05', 'YYYY-MM-DD HH24:MI:SS.FF'), "
            + "TO_TIMESTAMP_TZ('2026-10-06 15:22:20.000001+02:00', 'YYYY-MM-DD HH24:MI:SS.FFTZH:TZM'), "
            + "TO_TIMESTAMP_TZ('2026-10-06 08:04:05.123456+07:00', 'YYYY-MM-DD HH24:MI:SS.FFTZH:TZM'))"

        let fromSchema = try #require(try insert(writer(keys: [], columns: columns), values))
        #expect(fromSchema.statement == expected)
        #expect(fromSchema.parameters.isEmpty)

        let headerNames = [
            "D": "date", "T": "timestamp", "TZ": "timestamp with time zone", "TL": "timestamp with local time zone"
        ]
        let fromHeaders = try #require(try insert(writer(keys: [], columns: columns, typeNames: headerNames), values))
        #expect(fromHeaders.statement == expected)
    }

    /// The value reads as the session's wall clock with that instant's offset, which `TO_TIMESTAMP` rejects with
    /// ORA-01830. Measured on 23ai, the read text matches the row again with the session at `+07:00` and at
    /// `America/New_York` against a `+00:00` database.
    @Test("A TIMESTAMP WITH LOCAL TIME ZONE value keeps its offset in SET and in a keyless match")
    func localTimeZoneRoundTrip() throws {
        let keyless = writer(
            keys: [], columns: ["A", "TL"],
            typeNames: ["A": "NUMBER", "TL": "TIMESTAMP(6) WITH LOCAL TIME ZONE"]
        )
        let read = PluginCellValue.text("2026-10-06 08:04:05.123456+07:00")
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "TL", oldValue: read, newValue: .text("2026-10-05 21:04:05-04:00"))],
            originalRow: [.text("0"), read]
        )
        let write = try #require(try updates(keyless, [change]).first)
        #expect(write.statement == "UPDATE \"T1\" SET "
            + "\"TL\" = TO_TIMESTAMP_TZ('2026-10-05 21:04:05-04:00', 'YYYY-MM-DD HH24:MI:SS.FFTZH:TZM') "
            + "WHERE \"A\" = 0 AND "
            + "\"TL\" = TO_TIMESTAMP_TZ('2026-10-06 08:04:05.123456+07:00', 'YYYY-MM-DD HH24:MI:SS.FFTZH:TZM') "
            + "AND ROWNUM = 1")
        #expect(write.parameters.isEmpty)
    }

    @Test("A column with no known type is bound as it always was")
    func untypedColumnIsBound() throws {
        let write = try #require(try insert(writer(keys: [], columns: ["D"], typeNames: [:]), [.text("2026-10-06")]))
        #expect(write.statement == "INSERT INTO \"T1\" (\"D\") VALUES (?)")
        #expect(write.parameters == [.text("2026-10-06")])
    }

    /// A bound `123.45` fails with ORA-01722 where the decimal separator is a comma.
    @Test("A valid number is written as a literal, anything else is bound")
    func numbers() throws {
        let cases: [(value: String, sql: String)] = [
            ("123.45", "123.45"), ("-0.5", "-0.5"), ("1e-05", "1e-05"), (".5", ".5"), ("+5", "+5"),
            ("12,5", "?"), ("1; DROP TABLE T1", "?"), ("\u{FF11}\u{FF12}", "?"), ("1e", "?"), ("", "?"), ("NaN", "?")
        ]
        for testCase in cases {
            let write = try #require(try updates(writer(), [update("N", to: .text(testCase.value))]).first)
            #expect(write.statement == "UPDATE \"T1\" SET \"N\" = \(testCase.sql) WHERE \"ID\" = 7", "\(testCase.value)")
        }
    }

    /// A bare `1.7976931348623157e+308` is read as a NUMBER first and overflows it (ORA-01426).
    @Test("Binary floating-point literals carry their suffix, and inf or nan is bound")
    func binaryFloatingPoint() throws {
        let float = try #require(try updates(writer(), [update("BF", to: .text("3.4028235e+38"))]).first)
        #expect(float.statement == "UPDATE \"T1\" SET \"BF\" = 3.4028235e+38f WHERE \"ID\" = 7")
        let double = try #require(try updates(writer(), [update("BD", to: .text("1.7976931348623157e+308"))]).first)
        #expect(double.statement == "UPDATE \"T1\" SET \"BD\" = 1.7976931348623157e+308d WHERE \"ID\" = 7")
        let infinity = try #require(try updates(writer(), [update("BD", to: .text("-inf"))]).first)
        #expect(infinity.statement == "UPDATE \"T1\" SET \"BD\" = ? WHERE \"ID\" = 7")
        #expect(infinity.parameters == [.text("-inf")])
    }

    /// Left as `?`, `00123` would be written unquoted by the placeholder writer and stored in a VARCHAR2 as `123`.
    @Test("Numeric-looking text into a text column stays quoted, in SET and in a keyless match")
    func leadingZeroTextStaysQuoted() throws {
        let set = try #require(try updates(writer(), [update("V", to: .text("00123"))]).first)
        #expect(set.statement == "UPDATE \"T1\" SET \"V\" = '00123' WHERE \"ID\" = 7")
        #expect(set.parameters.isEmpty)

        let keyless = writer(keys: [], columns: ["A", "B"], typeNames: ["A": "NUMBER", "B": "VARCHAR2(10 BYTE)"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 0, columnName: "A", oldValue: .text("1"), newValue: .text("2"))],
            originalRow: [.text("1"), .text("00123")]
        )
        let match = try #require(try updates(keyless, [change]).first)
        #expect(match.statement == "UPDATE \"T1\" SET \"A\" = 2 WHERE \"A\" = 1 AND \"B\" = '00123' AND ROWNUM = 1")

        let row = try #require(try insert(writer(keys: [], columns: ["V"]), [.text("00123")]))
        #expect(row.statement == "INSERT INTO \"T1\" (\"V\") VALUES ('00123')")
    }

    @Test("Numeric-looking text into a number column is a numeric literal")
    func leadingZeroIntoNumber() throws {
        let write = try #require(try updates(writer(), [update("N", to: .text("00123"))]).first)
        #expect(write.statement == "UPDATE \"T1\" SET \"N\" = 00123 WHERE \"ID\" = 7")
    }

    @Test("Text for a column of no known type keeps the placeholder")
    func unknownTypeKeepsPlaceholder() throws {
        let untyped = writer(keys: ["ID"], columns: ["ID", "V"], typeNames: ["ID": "NUMBER"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "V", oldValue: .null, newValue: .text("00123"))],
            originalRow: [.text("7"), .null]
        )
        let write = try #require(try updates(untyped, [change]).first)
        #expect(write.statement == "UPDATE \"T1\" SET \"V\" = ? WHERE \"ID\" = 7")
        #expect(write.parameters == [.text("00123")])
    }

    /// A string literal over 4,000 bytes fails with ORA-01704, so such text is left to be bound.
    @Test("Text over the literal limit keeps the placeholder")
    func longTextKeepsPlaceholder() throws {
        let long = String(repeating: "x", count: 4_001)
        let text = try #require(try updates(writer(), [update("V", to: .text(long))]).first)
        #expect(text.statement == "UPDATE \"T1\" SET \"V\" = ? WHERE \"ID\" = 7")
        #expect(text.parameters == [.text(long)])
        let clob = try #require(try updates(writer(), [update("CL", to: .text(long))]).first)
        #expect(clob.statement == "UPDATE \"T1\" SET \"CL\" = ? WHERE \"ID\" = 7")
        let date = try #require(try updates(writer(), [update("D", to: .text(long))]).first)
        #expect(date.statement == "UPDATE \"T1\" SET \"D\" = TO_DATE(?, 'YYYY-MM-DD HH24:MI:SS') WHERE \"ID\" = 7")
    }

    /// A NULL bind into an object-type column fails with ORA-00932.
    @Test("NULL is the literal, never a bind")
    func nullLiteral() throws {
        let write = try #require(try updates(writer(), [update("O", to: .null)]).first)
        #expect(write.statement == "UPDATE \"T1\" SET \"O\" = NULL WHERE \"ID\" = 7")
        #expect(write.parameters.isEmpty)
    }

    @Test("Bytes and text are bound")
    func bytesAndText() throws {
        let bytes = try #require(try updates(writer(), [update("R", to: .bytes(Data([1, 2])))]).first)
        #expect(bytes.statement == "UPDATE \"T1\" SET \"R\" = ? WHERE \"ID\" = 7")
        #expect(bytes.parameters == [.bytes(Data([1, 2]))])
        let text = try #require(try updates(writer(), [update("V", to: .text("it's 42"))]).first)
        #expect(text.statement == "UPDATE \"T1\" SET \"V\" = 'it''s 42' WHERE \"ID\" = 7")
        #expect(text.parameters.isEmpty)
    }

    @Test("The server's clock functions are written as keywords on temporal columns only")
    func temporalFunctions() throws {
        let date = try #require(try updates(writer(), [update("D", to: .text("sysdate"))]).first)
        #expect(date.statement == "UPDATE \"T1\" SET \"D\" = SYSDATE WHERE \"ID\" = 7")
        let stamp = try #require(try updates(writer(), [update("TZ", to: .text("CURRENT_TIMESTAMP"))]).first)
        #expect(stamp.statement == "UPDATE \"T1\" SET \"TZ\" = CURRENT_TIMESTAMP WHERE \"ID\" = 7")
        let text = try #require(try updates(writer(), [update("V", to: .text("SYSDATE"))]).first)
        #expect(text.statement == "UPDATE \"T1\" SET \"V\" = 'SYSDATE' WHERE \"ID\" = 7")
    }

    @Test("The default marker is the DEFAULT keyword")
    func defaultMarker() throws {
        let write = try #require(try updates(writer(), [update("V", to: OracleRowWriter.defaultMarker)]).first)
        #expect(write.statement == "UPDATE \"T1\" SET \"V\" = DEFAULT WHERE \"ID\" = 7")
        let row = try #require(try insert(
            writer(keys: [], columns: ["A", "B"], typeNames: ["A": "NUMBER"]), [.text("1"), OracleRowWriter.defaultMarker]
        ))
        #expect(row.statement == "INSERT INTO \"T1\" (\"A\", \"B\") VALUES (1, DEFAULT)")
    }

    // MARK: - Server-owned columns

    @Test("An insert leaves out the columns the server owns")
    func insertSkipsServerOwned() throws {
        let owned = writer(keys: ["ID"], columns: ["ID", "V"], typeNames: ["ID": "NUMBER"]) { $0.serverOwnedColumns = ["ID"] }
        let write = try #require(try insert(owned, [.text("99"), .text("x")]))
        #expect(write.statement == "INSERT INTO \"T1\" (\"V\") VALUES (?)")
        #expect(write.parameters == [.text("x")])

        let allOwned = writer(keys: ["ID"], columns: ["ID"], typeNames: [:]) { $0.serverOwnedColumns = ["ID"] }
        let defaults = try #require(try insert(allOwned, [.text("99")]))
        #expect(defaults.statement == "INSERT INTO \"T1\" (\"ID\") VALUES (DEFAULT)")
    }

    @Test("An update that gives a server-owned column a value is refused")
    func updateRefusesServerOwned() {
        let owned = writer { $0.serverOwnedColumns = ["V"] }
        #expect(throws: PluginRowWriteRefusal.self) { try updates(owned, [update("V", to: .text("x"))]) }
    }

    // MARK: - Deletes

    /// One statement with 32,767 binds took 30 seconds on 23ai; 1,000 took 0.07.
    @Test("Keyed deletes are batched at most 1,000 key values a statement")
    func keyedDeleteBatches() throws {
        let rows = (0..<2_500).map { index in [PluginCellValue.text("\(index)")] }
        let writes = try deletes(writer(keys: ["ID"], columns: ["ID"], typeNames: ["ID": "NUMBER"]), rows: rows)
        #expect(writes.map { $0.rowIndices.count } == [1_000, 1_000, 500])
        #expect(writes.first?.statement.hasPrefix("DELETE FROM \"T1\" WHERE \"ID\" = 0 OR \"ID\" = 1 OR") == true)
        #expect(Set(writes.flatMap { $0.rowIndices }) == Set(0..<2_500))

        let composite = writer(keys: ["ID", "K"], columns: ["ID", "K"], typeNames: ["ID": "NUMBER", "K": "VARCHAR2(5 BYTE)"])
        let pairs = (0..<1_200).map { index in [PluginCellValue.text("\(index)"), .text("k")] }
        let compositeWrites = try deletes(composite, rows: pairs)
        #expect(compositeWrites.map { $0.rowIndices.count } == [500, 500, 200])
        #expect(compositeWrites.first?.parameters.isEmpty == true)
        #expect(compositeWrites.first?.statement.hasPrefix(
            "DELETE FROM \"T1\" WHERE (\"ID\" = 0 AND \"K\" = 'k') OR (\"ID\" = 1 AND \"K\" = 'k')"
        ) == true)
    }

    @Test("Keyless deletes go one row at a time")
    func keylessDeletes() throws {
        let keyless = writer(keys: [], columns: ["A", "B"], typeNames: ["A": "NUMBER", "B": "VARCHAR2(5 BYTE)"])
        let writes = try deletes(keyless, rows: [[.text("1"), .text("x")], [.text("2"), .null]])
        #expect(writes.map { $0.statement } == [
            "DELETE FROM \"T1\" WHERE \"A\" = 1 AND \"B\" = 'x' AND ROWNUM = 1",
            "DELETE FROM \"T1\" WHERE \"A\" = 2 AND \"B\" IS NULL AND ROWNUM = 1"
        ])
        #expect(writes.map { $0.rowIndices } == [[0], [1]])
    }

    /// Moving the delete after the insert fails the insert with ORA-00001 when it reuses the deleted row's key.
    @Test("A delete stays ahead of an insert that reuses its key")
    func deleteKeepsItsPlace() throws {
        let keyed = writer(keys: ["ID"], columns: ["ID", "V"], typeNames: ["ID": "NUMBER", "V": "VARCHAR2(5 BYTE)"])
        let delete = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.text("7"), .text("a")])
        let insert = PluginRowChange(rowIndex: 1, type: .insert, cellChanges: [], originalRow: nil)
        let writes = try keyed.rowWrites(
            for: [delete, insert],
            insertedRowData: [1: [.text("7"), .text("b")]],
            deletedRowIndices: [0],
            insertedRowIndices: [1]
        )
        #expect(writes.map { $0.statement } == [
            "DELETE FROM \"T1\" WHERE \"ID\" = 7",
            "INSERT INTO \"T1\" (\"ID\", \"V\") VALUES (7, 'b')"
        ])
    }

    @Test("Only consecutive deletes are batched, each run where it stood")
    func interleavedDeleteRuns() throws {
        let keyed = writer(keys: ["ID"], columns: ["ID", "V"], typeNames: ["ID": "NUMBER", "V": "VARCHAR2(5 BYTE)"])
        func delete(_ row: Int) -> PluginRowChange {
            PluginRowChange(rowIndex: row, type: .delete, cellChanges: [], originalRow: [.text("\(row)"), .null])
        }
        let update = PluginRowChange(
            rowIndex: 3,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "V", oldValue: .null, newValue: .text("x"))],
            originalRow: [.text("3"), .null]
        )
        let writes = try keyed.rowWrites(
            for: [delete(1), delete(2), update, delete(4), delete(5)],
            insertedRowData: [:],
            deletedRowIndices: [1, 2, 4, 5],
            insertedRowIndices: []
        )
        #expect(writes.map { $0.statement } == [
            "DELETE FROM \"T1\" WHERE \"ID\" = 1 OR \"ID\" = 2",
            "UPDATE \"T1\" SET \"V\" = 'x' WHERE \"ID\" = 3",
            "DELETE FROM \"T1\" WHERE \"ID\" = 4 OR \"ID\" = 5"
        ])
        #expect(writes.map { $0.rowIndices } == [[1, 2], [3], [4, 5]])
    }

    // MARK: - BFILE

    /// A BFILE reads as `BFILENAME('DIR', 'file')`; quoted or bound, that text fails with ORA-00932.
    @Test("A BFILE value is written back as the BFILENAME call it reads as")
    func bfileWrittenAsCall() throws {
        let files = writer(keys: [], columns: ["ID", "F"], typeNames: ["ID": "NUMBER", "F": "BFILE"])
        let row = try #require(try insert(files, [.text("2"), .text("BFILENAME('DATA_PUMP_DIR', 'it''s.bin')")]))
        #expect(row.statement == "INSERT INTO \"T1\" (\"ID\", \"F\") VALUES (2, BFILENAME('DATA_PUMP_DIR', 'it''s.bin'))")
        #expect(row.parameters.isEmpty)
        let empty = try #require(try insert(files, [.text("3"), .null]))
        #expect(empty.statement == "INSERT INTO \"T1\" (\"ID\", \"F\") VALUES (3, NULL)")
    }

    @Test("Anything in a BFILE cell but the exact BFILENAME call is refused")
    func bfileRefusesOtherText() {
        let files = writer(keys: [], columns: ["F"], typeNames: ["F": "BFILE"])
        let refused = [
            "<bfile>", "x.bin", "BFILENAME('DIR','x.bin')", "bfilename('DIR', 'x.bin')",
            "BFILENAME('DIR', 'x.bin'); DROP TABLE T1", "BFILENAME('DIR', 'x.bin')) --", "BFILENAME('DIR', 'it's')",
            "BFILENAME('DIR', 'x.bin'"
        ]
        for text in refused {
            #expect(throws: PluginRowWriteRefusal.self, "\(text)") { try insert(files, [.text(text)]) }
        }
        #expect(throws: PluginRowWriteRefusal.self) { try insert(files, [.bytes(Data([1]))]) }
    }

    @Test("The BFILENAME text is parsed only in its exact shape")
    func bfileParsing() {
        let names = OracleBFileText.names(in: "BFILENAME('D''IR', 'a''b''.bin')")
        #expect(names?.directory == "D'IR")
        #expect(names?.fileName == "a'b'.bin")
        #expect(OracleBFileText.call(from: "BFILENAME('D''IR', 'a''b''.bin')") == "BFILENAME('D''IR', 'a''b''.bin')")
        #expect(OracleBFileText.names(in: "BFILENAME('DIR', 'x') ") == nil)
        #expect(OracleBFileText.names(in: "BFILENAME('DIR', x)") == nil)
    }

    // MARK: - Numeric literal

    @Test("Only an ASCII number passes as a literal")
    func numericLiteral() {
        for valid in ["0", "-1", "+1", "1.", ".5", "1.5e10", "1E-3", "00123"] {
            #expect(OracleNumericLiteral.isValid(valid), "\(valid)")
        }
        for invalid in ["", "-", ".", "e5", "1e", "1e+", "1.2.3", "1 ", " 1", "1,5", "0x10", "\u{0663}", "1--1", "inf"] {
            #expect(!OracleNumericLiteral.isValid(invalid), "\(invalid)")
        }
    }
}
