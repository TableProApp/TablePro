import Foundation
@testable import TableProTabular
import TableProTabularIO
import XCTest

final class TabularSaveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabularSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func open(_ bytes: [UInt8], fileExtension: String = "csv") async throws -> (DelimitedSource, TabularTable) {
        let data = Data(bytes)
        let dialect = data.withUnsafeBytes { raw -> DelimitedDialect in
            let buffer = raw.bindMemory(to: UInt8.self)
            let sniff = DelimitedDialectDetector.sniffEncoding(buffer)
            return DelimitedDialectDetector.detect(
                buffer,
                contentStart: sniff.byteOrderMarkLength,
                encoding: sniff.encoding,
                hasByteOrderMark: sniff.hasByteOrderMark,
                fileExtension: fileExtension
            )
        }
        let source = try await DelimitedSourceBuilder.build(
            bytes: data,
            dialect: dialect,
            byteEncoding: dialect.encoding,
            contentStart: dialect.hasByteOrderMark ? dialect.encoding.byteOrderMark.count : 0
        )
        return (source, TabularTable(source: source, usesFirstRowAsHeader: dialect.hasHeaderRow))
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

    func testUntouchedFileIsWrittenBackByteForByte() async throws {
        let original = Array("id,name\r\n1,\"Doe, Jane\"\r\n2,\"say \"\"hi\"\"\"\r\n3,x".utf8)
        let (source, table) = try await open(original)
        XCTAssertEqual(try save(table, source: source), original)
    }

    func testAppendingToAFileWithoutAFinalNewlineKeepsRowsApart() async throws {
        let (source, original) = try await open(Array("name,age\nAlice,30".utf8))
        var table = original
        table.insertRows([[.text("Bob"), .text("40")]], at: table.rowCount)
        XCTAssertEqual(TabularTextCodec.utf8String(try save(table, source: source)), "name,age\nAlice,30\nBob,40")
    }

    func testAddedColumnNameIsWritten() async throws {
        let (source, original) = try await open(Array("name,age\nAlice,30\n".utf8))
        var table = original
        table.insertColumn(named: "city", at: 2)
        table.setCell(.text("Paris"), row: 0, column: 2)
        XCTAssertEqual(TabularTextCodec.utf8String(try save(table, source: source)), "name,age,city\nAlice,30,Paris\n")
    }

    func testOnlyTheEditedRowIsRewritten() async throws {
        let (source, original) = try await open(Array("a,b\n\"1\",2\n3,\"4\"\n".utf8))
        var table = original
        table.setCell(.text("9"), row: 1, column: 0)
        XCTAssertEqual(TabularTextCodec.utf8String(try save(table, source: source)), "a,b\n\"1\",2\n9,4\n")
    }

    func testUnencodableTextFailsInsteadOfBlankingTheRow() async throws {
        let (source, original) = try await open([0x6E, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x0A, 0x41, 0x0A])
        XCTAssertEqual(source.dialect.encoding, .windows1252)
        var table = original
        table.setCell(.text("東京"), row: 1, column: 0)
        XCTAssertThrowsError(try save(table, source: source)) { error in
            guard case TabularWriteError.unencodable(let row, let column, _, .windows1252) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(row, 2)
            XCTAssertEqual(column, 0)
        }
    }

    func testWindows1252UndefinedBytesRoundTrip() async throws {
        let original: [UInt8] = [0x6E, 0x0A, 0x5A, 0x6F, 0x81, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x0A]
        let (source, first) = try await open(original)
        var table = first
        table.setCell(.text("Caf\u{E9}!"), row: 1, column: 0)
        let saved = try save(table, source: source)
        XCTAssertEqual(saved, [0x6E, 0x0A, 0x5A, 0x6F, 0x81, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x21, 0x0A])
    }

    func testSavingAsTabSeparatedWritesTabs() async throws {
        let (source, table) = try await open(Array("a,b\n1,\"x,y\"\n".utf8))
        var tsv = source.dialect
        tsv.delimiter = DelimitedDialect.tab
        XCTAssertEqual(TabularTextCodec.utf8String(try save(table, source: source, dialect: tsv)), "a\tb\n1\tx,y\n")
    }

    func testTurningTheHeaderOffWritesTheNamesAsData() async throws {
        let (source, original) = try await open(Array("a,b\n1,2\n".utf8))
        var table = original
        table.renameColumn(table.columns[0].id, to: "id")
        table.setUsesFirstRowAsHeader(false)
        var dialect = source.dialect
        dialect.hasHeaderRow = false
        XCTAssertEqual(TabularTextCodec.utf8String(try save(table, source: source, dialect: dialect)), "id,b\n1,2\n")
    }

    func testTabSeparatedExtensionForcesTabDelimiter() async throws {
        let (source, table) = try await open(Array("name\taddress\nAnn\t1 Main St, Apt 4, Springfield, IL\n".utf8), fileExtension: "tsv")
        XCTAssertEqual(source.dialect.delimiter, DelimitedDialect.tab)
        XCTAssertEqual(table.cells(row: 0).map(\.text), ["Ann", "1 Main St, Apt 4, Springfield, IL"])
    }

    func testDelimiterDetectionIsDeterministicForSingleColumnFiles() async throws {
        let (source, _) = try await open(Array("email\na@x.com\nb@y.org\n".utf8))
        XCTAssertEqual(source.dialect.delimiter, DelimitedDialect.comma)
        let (semicolonSource, _) = try await open(Array("a;b\n1;2\n".utf8))
        XCTAssertEqual(semicolonSource.dialect.delimiter, DelimitedDialect.semicolon)
        let (tieSource, _) = try await open(Array("a,b;c\n".utf8))
        XCTAssertEqual(tieSource.dialect.delimiter, DelimitedDialect.comma)
    }
}
