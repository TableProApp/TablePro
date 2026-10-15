import Foundation
@testable import TableProTabular
import TableProTabularIO
import Testing

final class TabularSaveTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabularSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func open(_ bytes: [UInt8], fileExtension: String = "csv") async throws -> (DelimitedSource, TabularTable) {
        let contents = try await DelimitedFileReader.read(
            Data(bytes),
            fileExtension: fileExtension,
            transcodedFileURL: directory.appendingPathComponent("utf8-\(UUID().uuidString)")
        )
        let source = contents.source
        return (source, TabularTable(source: source, usesFirstRowAsHeader: source.dialect.hasHeaderRow))
    }

    private func save(_ table: TabularTable, source: DelimitedSource, dialect: DelimitedDialect? = nil) throws -> [UInt8] {
        let url = directory.appendingPathComponent("out-\(UUID().uuidString)")
        let headerNames = source.dialect.hasHeaderRow ? source.decodedFields(row: 0) : nil
        let writer = DelimitedWriter(dialect: dialect ?? source.dialect, source: source)
        try writer.write(
            to: url,
            rows: table.outputRows(sourceHeaderNames: headerNames),
            endsWithLineTerminator: source.index.endsWithLineTerminator
        )
        return try [UInt8](Data(contentsOf: url))
    }

    @Test func testUntouchedFileIsWrittenBackByteForByte() async throws {
        let original = Array("id,name\r\n1,\"Doe, Jane\"\r\n2,\"say \"\"hi\"\"\"\r\n3,x".utf8)
        let (source, table) = try await open(original)
        #expect(try save(table, source: source) == original)
    }

    @Test func testAChangedLineEndingRewritesEveryRow() async throws {
        let (source, table) = try await open(Array("id,name\r\n1,a\r\n2,b\r\n".utf8))
        var dialect = source.dialect
        dialect.lineEnding = .lf
        #expect(try save(table, source: source, dialect: dialect) == Array("id,name\n1,a\n2,b\n".utf8))
    }

    @Test func testAppendingToAFileWithoutAFinalNewlineKeepsRowsApart() async throws {
        let (source, original) = try await open(Array("name,age\nAlice,30".utf8))
        var table = original
        table.insertRows([[.text("Bob"), .text("40")]], at: table.rowCount)
        #expect(TabularTextCodec.utf8String(try save(table, source: source)) == "name,age\nAlice,30\nBob,40")
    }

    @Test func testAddedColumnNameIsWritten() async throws {
        let (source, original) = try await open(Array("name,age\nAlice,30\n".utf8))
        var table = original
        table.insertColumn(named: "city", at: 2)
        table.setCell(.text("Paris"), row: 0, column: 2)
        #expect(TabularTextCodec.utf8String(try save(table, source: source)) == "name,age,city\nAlice,30,Paris\n")
    }

    @Test func testOnlyTheEditedRowIsRewritten() async throws {
        let (source, original) = try await open(Array("a,b\n\"1\",2\n3,\"4\"\n".utf8))
        var table = original
        table.setCell(.text("9"), row: 1, column: 0)
        #expect(TabularTextCodec.utf8String(try save(table, source: source)) == "a,b\n\"1\",2\n9,4\n")
    }

    @Test func testUnencodableTextFailsInsteadOfBlankingTheRow() async throws {
        let (source, original) = try await open([0x6E, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x0A, 0x41, 0x0A])
        #expect(source.dialect.encoding == .windows1252)
        var table = original
        table.setCell(.text("東京"), row: 1, column: 0)
        if let error = #expect(throws: (any Error).self, performing: { try save(table, source: source) }) {
            guard case TabularWriteError.unencodable(let row, let column, _, .windows1252) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(row == 2)
            #expect(column == 0)
        }
    }

    @Test func testWindows1252UndefinedBytesRoundTrip() async throws {
        let original: [UInt8] = [0x6E, 0x0A, 0x5A, 0x6F, 0x81, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x0A]
        let (source, first) = try await open(original)
        var table = first
        table.setCell(.text("Caf\u{E9}!"), row: 1, column: 0)
        let saved = try save(table, source: source)
        #expect(saved == [0x6E, 0x0A, 0x5A, 0x6F, 0x81, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x21, 0x0A])
    }

    @Test func testSavingAsTabSeparatedWritesTabs() async throws {
        let (source, table) = try await open(Array("a,b\n1,\"x,y\"\n".utf8))
        var tsv = source.dialect
        tsv.delimiter = DelimitedDialect.tab
        #expect(TabularTextCodec.utf8String(try save(table, source: source, dialect: tsv)) == "a\tb\n1\tx,y\n")
    }

    @Test func testTurningTheHeaderOffWritesTheNamesAsData() async throws {
        let (source, original) = try await open(Array("a,b\n1,2\n".utf8))
        var table = original
        table.renameColumn(table.columns[0].id, to: "id")
        table.setUsesFirstRowAsHeader(false)
        var dialect = source.dialect
        dialect.hasHeaderRow = false
        #expect(TabularTextCodec.utf8String(try save(table, source: source, dialect: dialect)) == "id,b\n1,2\n")
    }

    @Test func testTabSeparatedExtensionForcesTabDelimiter() async throws {
        let (source, table) = try await open(Array("name\taddress\nAnn\t1 Main St, Apt 4, Springfield, IL\n".utf8), fileExtension: "tsv")
        #expect(source.dialect.delimiter == DelimitedDialect.tab)
        #expect(table.cells(row: 0).map(\.text) == ["Ann", "1 Main St, Apt 4, Springfield, IL"])
    }

    @Test func testDelimiterDetectionIsDeterministicForSingleColumnFiles() async throws {
        let (source, _) = try await open(Array("email\na@x.com\nb@y.org\n".utf8))
        #expect(source.dialect.delimiter == DelimitedDialect.comma)
        let (semicolonSource, _) = try await open(Array("a;b\n1;2\n".utf8))
        #expect(semicolonSource.dialect.delimiter == DelimitedDialect.semicolon)
        let (tieSource, _) = try await open(Array("a,b;c\n".utf8))
        #expect(tieSource.dialect.delimiter == DelimitedDialect.comma)
    }

    private func shiftJIS(_ text: String) throws -> [UInt8] {
        [UInt8](try #require(text.data(using: .shiftJIS, allowLossyConversion: false)))
    }

    private func quotedShiftJISExport() throws -> (bytes: [UInt8], rows: [[UInt8]]) {
        let taka: [UInt8] = [0xFB, 0xFC]
        let saki: [UInt8] = [0xFA, 0xB1]
        let smallRomanOne: [UInt8] = [0xFA, 0x40]
        let rows: [[UInt8]] = [
            try shiftJIS("\"顧客ID\",\"氏名\",\"よみがな\",\"備考\"\r\n"),
            try shiftJIS("\"001\",\"") + taka + (try shiftJIS("橋\",\"たかはし\",\"ｿﾌﾄｳｪｱの保守\"\r\n")),
            try shiftJIS("\"002\",\"山") + saki + (try shiftJIS("\",\"やまさき\",\"")) + smallRomanOne + (try shiftJIS("の注文\"\r\n")),
            try shiftJIS("\"003\",\"田中\",\"たなか\",\"ポイント交換\"\r\n"),
            try shiftJIS("\"004\",\"佐藤\",\"さとう\",\"東京都港区芝公園\"\r\n")
        ]
        return (rows.flatMap { $0 }, rows)
    }

    @Test func testShiftJISFileOpensAsShiftJIS() async throws {
        let (source, table) = try await open(try quotedShiftJISExport().bytes)
        #expect(source.dialect.encoding == .shiftJIS)
        #expect(source.origin != nil)
        #expect(table.cells(row: 0).map(\.text) == ["001", "\u{9AD9}橋", "たかはし", "ｿﾌﾄｳｪｱの保守"])
        #expect(table.cells(row: 1).map(\.text) == ["002", "山\u{FA11}", "やまさき", "\u{2170}の注文"])
    }

    @Test func testUntouchedShiftJISRowsKeepTheirQuotesAndIBMExtensionCodes() async throws {
        let export = try quotedShiftJISExport()
        let (source, original) = try await open(export.bytes)
        #expect(try save(original, source: source) == export.bytes)
        var table = original
        table.setCell(.text("鈴木"), row: 2, column: 1)
        let expected = export.rows[0] + export.rows[1] + export.rows[2]
            + (try shiftJIS("003,鈴木,たなか,ポイント交換\r\n")) + export.rows[4]
        #expect(try save(table, source: source) == expected)
    }

    @Test func testDeletingAndReorderingShiftJISRowsCopiesTheRestExactly() async throws {
        let export = try quotedShiftJISExport()
        let (source, original) = try await open(export.bytes)
        var table = original
        table.deleteRows(IndexSet(integer: 1))
        #expect(try save(table, source: source) == export.rows[0] + export.rows[1] + export.rows[3] + export.rows[4])
        var reordered = original
        reordered.replaceRowOrder(.explicit([4, 2, 3, 1]))
        #expect(try save(reordered, source: source) == export.rows[0] + export.rows[4] + export.rows[2] + export.rows[3] + export.rows[1])
    }

    @Test func testAnEditNearTheEndOfALargeShiftJISFileLeavesEveryOtherByte() async throws {
        let header = try shiftJIS("コード,名称,住所\r\n")
        let line = try shiftJIS(",東京都港区芝公園４－２－８,ｻﾞｲｺｶﾝﾘｽﾙ ポイント\r\n")
        var bytes = header
        let rowCount = 40_000
        for row in 0..<rowCount {
            bytes += Array(String(row).utf8) + line
        }
        #expect(bytes.count > TabularTextTranscoder.chunkLength * 2)
        let (source, original) = try await open(bytes)
        #expect(source.dialect.encoding == .shiftJIS)
        var table = original
        table.setCell(.text("999"), row: rowCount - 1, column: 0)
        let saved = try save(table, source: source)
        let lastRowStart = bytes.count - (Array(String(rowCount - 1).utf8) + line).count
        #expect(Array(saved.prefix(lastRowStart)) == Array(bytes.prefix(lastRowStart)))
        #expect(Array(saved.suffix(from: lastRowStart)) == Array("999".utf8) + line)
    }

    @Test func testReversingALargeShiftJISFileCopiesEveryRow() async throws {
        let header = try shiftJIS("コード,名称\r\n")
        let rows = try (0..<60_000).map { try shiftJIS("\($0),東京都港区芝公園４－２－８ ｻﾞｲｺｶﾝﾘｽﾙ\r\n") }
        let bytes = header + rows.flatMap { $0 }
        #expect(bytes.count > TabularTextTranscoder.chunkLength * 2)
        let (source, original) = try await open(bytes)
        #expect(source.origin != nil)
        var reversed = original
        reversed.replaceRowOrder(.explicit(Array((1...rows.count).reversed())))
        #expect(try save(reversed, source: source) == header + rows.reversed().flatMap { $0 })
    }

    @Test func testUntouchedUTF16FileIsWrittenBackByteForByte() async throws {
        let text = "\"名前\"\t\"住所\"\r\n\"吉田\"\t\"三上\"\r\n\"本田\"\t\"日本\"\r\n"
        let bytes = [0xFF, 0xFE] + [UInt8](try #require(text.data(using: .utf16LittleEndian)))
        let (source, table) = try await open(bytes, fileExtension: "tsv")
        #expect(source.dialect.encoding == .utf16LittleEndian)
        #expect(table.cells(row: 1).map(\.text) == ["本田", "日本"])
        #expect(try save(table, source: source) == bytes)
    }

    @Test func testAStrayTrailingUTF16ByteDoesNotMisalignRowsWrittenAfterIt() async throws {
        let text = "名前,住所\r\n吉田,東京\r\n本田,大阪"
        let bytes = [0xFF, 0xFE] + [UInt8](try #require(text.data(using: .utf16LittleEndian))) + [0x0A]
        let (source, original) = try await open(bytes)
        #expect(source.dialect.encoding == .utf16LittleEndian)
        var table = original
        table.insertRows([[.text("新規"), .text("行")]], at: table.rowCount)
        let saved = try save(table, source: source)
        #expect(saved.count.isMultiple(of: 2))
        let (_, reopened) = try await open(saved)
        #expect(reopened.rowCount == 3)
        #expect(reopened.cells(row: 2).map(\.text) == ["新規", "行"])
    }

    @Test func testAYenSignTypedIntoAShiftJISFileSavesAsItsJISRomanByte() async throws {
        let (source, original) = try await open(try quotedShiftJISExport().bytes)
        var table = original
        table.setCell(.text("¥1,000‾"), row: 0, column: 3)
        let saved = try save(table, source: source)
        #expect(saved.suffix(from: 0).starts(with: try quotedShiftJISExport().rows[0]))
        let editedRow = try shiftJIS("001,\u{9AD9}橋,たかはし,\"\\1,000~\"\r\n")
        #expect(saved.firstRange(of: editedRow) != nil)
    }

    @Test func testSavingAShiftJISFileAsUTF8KeepsItsQuoting() async throws {
        let (source, table) = try await open(try quotedShiftJISExport().bytes)
        var utf8 = source.dialect
        utf8.encoding = .utf8
        let saved = TabularTextCodec.utf8String(try save(table, source: source, dialect: utf8))
        #expect(saved.hasPrefix("\"顧客ID\",\"氏名\",\"よみがな\",\"備考\"\r\n\"001\",\"\u{9AD9}橋\""))
    }
}
