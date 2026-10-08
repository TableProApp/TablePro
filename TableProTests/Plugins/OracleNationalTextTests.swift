//
//  OracleNationalTextTests.swift
//  TableProTests
//
//  Text for NCHAR, NVARCHAR2 and NCLOB columns. Every statement shape below was run against Oracle 23ai with a
//  WE8MSWIN1252 database character set (national AL16UTF16), an AL32UTF8 one with a UTF8 national character set, and
//  AL32UTF8 with AL16UTF16: each stored and matched the text, where a plain literal stored ¿¿¿ on the first.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct OracleNationalTextTests {
    @Test("ASCII text keeps its plain literal")
    func asciiTextIsLeftAlone() {
        #expect(OracleNationalText.sql(for: "abc 123 'q' \\", asLOB: false) == nil)
        #expect(OracleNationalText.sql(for: "", asLOB: true) == nil)
    }

    @Test("Other characters are UTF-16 escapes, a quote is doubled and a backslash is escaped")
    func escapes() {
        #expect(OracleNationalText.sql(for: "ລາວ", asLOB: false) == "UNISTR('\\0EA5\\0EB2\\0EA7')")
        #expect(
            OracleNationalText.sql(for: "é a\\b 'q'", asLOB: false) == "UNISTR('\\00E9 a\\\\b ''q''')"
        )
        #expect(OracleNationalText.sql(for: "😀\n", asLOB: false) == "UNISTR('\\D83D\\DE00\\000A')")
    }

    @Test("NUL is dropped, as the plain literal drops it")
    func nulIsDropped() {
        #expect(OracleNationalText.sql(for: "é\0", asLOB: false) == "UNISTR('\\00E9')")
    }

    @Test("Long text is split into calls of at most 4,000 bytes, never inside a surrogate pair")
    func chunking() throws {
        let text = String(repeating: "ດ", count: 799) + "😀" + "ດ"
        let sql = try #require(OracleNationalText.sql(for: text, asLOB: false))
        let calls = sql.components(separatedBy: " || ")
        #expect(calls.count == 2)
        #expect(calls[0] == "UNISTR('" + String(repeating: "\\0E94", count: 799) + "')")
        #expect(calls[1] == "UNISTR('\\D83D\\DE00\\0E94')")
        for call in calls {
            #expect(call.utf8.count - "UNISTR('')".utf8.count <= OracleNationalText.maxChunkBytes)
        }
    }

    /// One UNISTR of 3,995 `a` and an `é` is 3,996 characters, 7,992 bytes in AL16UTF16, and an AL16UTF16 database kept
    /// 2,000 of them with no error.
    @Test("Mostly ASCII text is split by its size in the national character set, not only by its escapes")
    func chunkingBoundsTheDecodedSize() throws {
        let text = String(repeating: "a", count: 3_995) + "é"
        let sql = try #require(OracleNationalText.sql(for: text, asLOB: true))
        let calls = sql.components(separatedBy: " || ")
        #expect(calls.count == 2)
        #expect(calls[0] == "TO_NCLOB(UNISTR('" + String(repeating: "a", count: 2_000) + "'))")
        #expect(calls[1] == "TO_NCLOB(UNISTR('" + String(repeating: "a", count: 1_995) + "\\00E9'))")
    }

    @Test("Each call is wrapped in TO_NCLOB for an NCLOB, so the joined value has no 4,000-byte limit")
    func lobChunks() throws {
        let sql = try #require(OracleNationalText.sql(for: String(repeating: "ດ", count: 801), asLOB: true))
        #expect(sql.hasPrefix("TO_NCLOB(UNISTR('\\0E94"))
        #expect(sql.components(separatedBy: " || ").allSatisfy { $0.hasPrefix("TO_NCLOB(UNISTR('") && $0.hasSuffix("'))") })
        #expect(sql.components(separatedBy: " || ").count == 2)
    }
}

struct OracleRowWriterNationalTextTests {
    private static let columns = ["ID", "NV", "NC", "NCL", "V"]
    private static let typeNames = [
        "ID": "NVARCHAR2(20)", "NV": "nvarchar2", "NC": "NCHAR(5)", "NCL": "nclob", "V": "VARCHAR2(20)"
    ]
    private static let original: [PluginCellValue] = [.text("ກ"), .text("ລາວ"), .text("ລາວ  "), .null, .text("ລາວ")]

    private func writer(keys: [String]) -> OracleRowWriter {
        var context = PluginRowWriteContext()
        context.columnTypeNames = Self.typeNames
        var writer = OracleRowWriter(qualifiedTable: "\"T1\"", columns: Self.columns, primaryKeyColumns: keys)
        writer.context = context
        return writer
    }

    private func update(_ column: String, to value: PluginCellValue) -> PluginRowChange {
        let index = Self.columns.firstIndex(of: column) ?? 0
        return PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: index, columnName: column, oldValue: Self.original[index], newValue: value)],
            originalRow: Self.original
        )
    }

    private func write(_ writer: OracleRowWriter, _ change: PluginRowChange) throws -> PluginRowWrite {
        let writes = try writer.rowWrites(
            for: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        return try #require(writes.first)
    }

    @Test("A national column is set and matched by its key through UNISTR")
    func keyedUpdate() throws {
        let write = try write(writer(keys: ["ID"]), update("NV", to: .text("ລາວ😀")))
        #expect(write.statement == "UPDATE \"T1\" SET \"NV\" = UNISTR('\\0EA5\\0EB2\\0EA7\\D83D\\DE00') "
            + "WHERE \"ID\" = UNISTR('\\0E81')")
        #expect(write.parameters.isEmpty)
    }

    @Test("A keyless match writes every national value through UNISTR, NCHAR as the padded value it read")
    func keylessMatch() throws {
        let write = try write(writer(keys: []), update("V", to: .text("x")))
        #expect(write.statement == "UPDATE \"T1\" SET \"V\" = 'x' WHERE \"ID\" = UNISTR('\\0E81') "
            + "AND \"NV\" = UNISTR('\\0EA5\\0EB2\\0EA7') AND \"NC\" = UNISTR('\\0EA5\\0EB2\\0EA7  ') "
            + "AND \"NCL\" IS NULL AND \"V\" = 'ລາວ' AND ROWNUM = 1")
    }

    @Test("An NCLOB value is written through TO_NCLOB, however long, instead of a bind")
    func nclobIsNotBound() throws {
        let long = String(repeating: "ດ", count: 3_000)
        let write = try write(writer(keys: ["ID"]), update("NCL", to: .text(long)))
        #expect(write.statement.hasPrefix("UPDATE \"T1\" SET \"NCL\" = TO_NCLOB(UNISTR('\\0E94"))
        #expect(write.parameters.isEmpty)
    }

    @Test("ASCII text in a national column keeps the plain literal, numeric-looking text quoted")
    func asciiStaysPlain() throws {
        let write = try write(writer(keys: ["ID"]), update("NV", to: .text("00123")))
        #expect(write.statement == "UPDATE \"T1\" SET \"NV\" = '00123' WHERE \"ID\" = UNISTR('\\0E81')")
    }

    @Test("ASCII text over the literal limit in an NCLOB is still bound")
    func longAsciiLOBIsBound() throws {
        let long = String(repeating: "a", count: 5_000)
        let write = try write(writer(keys: ["ID"]), update("NCL", to: .text(long)))
        #expect(write.statement.hasPrefix("UPDATE \"T1\" SET \"NCL\" = ? WHERE"))
        #expect(write.parameters == [.text(long)])
    }

    @Test("An insert writes national values through UNISTR and other text as before")
    func insert() throws {
        let writes = try writer(keys: ["ID"]).rowWrites(
            for: [PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)],
            insertedRowData: [0: [.text("1"), .text("é"), .null, .text("ລ"), .text("é")]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        let write = try #require(writes.first)
        #expect(write.statement == "INSERT INTO \"T1\" (\"ID\", \"NV\", \"NC\", \"NCL\", \"V\") "
            + "VALUES ('1', UNISTR('\\00E9'), NULL, TO_NCLOB(UNISTR('\\0EA5')), 'é')")
    }
}
