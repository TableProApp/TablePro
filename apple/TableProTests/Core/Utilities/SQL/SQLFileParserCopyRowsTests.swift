//
//  SQLFileParserCopyRowsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar
import Testing

@testable import TablePro

struct SQLFileParserCopyRowsTests {
    private enum Element: Equatable {
        case statement(String, line: Int)
        case copy(String, line: Int, rows: Data)

        static func copying(_ statement: String, line: Int, rows: String) -> Element {
            .copy(statement, line: line, rows: Data(rows.utf8))
        }
    }

    private static func withFile<T>(_ sql: String, _ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLFileParserCopyRowsTests-\(UUID().uuidString).sql")
        try Data(sql.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }

    private static func pieces(of rows: PluginCopyData) throws -> [Data] {
        var pieces: [Data] = []
        while let piece = try rows.nextPiece() {
            pieces.append(piece)
        }
        return pieces
    }

    private static func read(_ element: PluginImportElement) throws -> Element {
        switch element {
        case let .statement(statement, lineNumber):
            return .statement(statement, line: lineNumber)
        case let .copyFromStandardInput(statement, lineNumber, rows):
            return .copy(statement, line: lineNumber, rows: Data(try pieces(of: rows).joined()))
        @unknown default:
            Issue.record("An element this test does not read: \(element)")
            return .statement("", line: 0)
        }
    }

    private static func elements(
        _ sql: String,
        parser: SQLFileParser = SQLFileParser(),
        grammar: SQLLexicalGrammar = TestGrammar.postgres
    ) async throws -> [Element] {
        try await withFile(sql) { url in
            var result: [Element] = []
            for try await element in parser.parseElements(url: url, encoding: .utf8, grammar: grammar) {
                result.append(try read(element))
            }
            return result
        }
    }

    // The pieces of every COPY the file holds, in order.
    private static func copyPieces(_ sql: String, parser: SQLFileParser = SQLFileParser()) async throws -> [Data] {
        try await withFile(sql) { url in
            var result: [Data] = []
            for try await element in parser.parseElements(url: url, encoding: .utf8, grammar: TestGrammar.postgres) {
                if case let .copyFromStandardInput(_, _, rows) = element {
                    result += try pieces(of: rows)
                }
            }
            return result
        }
    }

    @Test("COPY FROM STDIN yields its rows up to the \\. line, and the statements after it keep their file lines")
    func linefeedRows() async throws {
        let sql = "CREATE TABLE t (a int, b text);\nCOPY public.t (a, b) FROM stdin;\n1\tone\n2\tDROP TABLE users;\n\\.\n"
            + "SELECT count(*) FROM t;\nSELECT 2;\n"
        #expect(try await Self.elements(sql) == [
            .statement("CREATE TABLE t (a int, b text)", line: 1),
            .copying("COPY public.t (a, b) FROM stdin", line: 2, rows: "1\tone\n2\tDROP TABLE users;\n"),
            .statement("SELECT count(*) FROM t", line: 6),
            .statement("SELECT 2", line: 7),
        ])
    }

    @Test("CRLF rows keep their CRLF, and a \\. line ending in CRLF ends them")
    func carriageReturnRows() async throws {
        let sql = "COPY t (a) FROM stdin;\r\n1\r\n2\r\n\\.\r\nSELECT 1;\r\n"
        #expect(try await Self.elements(sql) == [
            .copying("COPY t (a) FROM stdin", line: 1, rows: "1\r\n2\r\n"),
            .statement("SELECT 1", line: 5),
        ])
    }

    @Test("Rows end at the end of the file when no \\. line ends them first", arguments: [
        ("COPY t (a) FROM stdin;\n1\n2\n", "1\n2\n"),
        ("COPY t (a) FROM stdin;\n1\n2", "1\n2"),
        ("COPY t (a) FROM stdin;\n1\n\\.", "1\n"),
        ("COPY t (a) FROM stdin;\n1\n\\.\r", "1\n"),
        ("COPY t (a) FROM stdin;\n\\.\n", ""),
        ("COPY t (a) FROM stdin;\n", ""),
        ("COPY t (a) FROM stdin;", ""),
    ])
    func rowsToTheEndOfTheFile(sql: String, rows: String) async throws {
        #expect(try await Self.elements(sql) == [.copying("COPY t (a) FROM stdin", line: 1, rows: rows)])
    }

    @Test("Text after the ; on the COPY line is neither data nor run")
    func restOfTheCopyLineRunsNothing() async throws {
        let sql = "COPY t (a) FROM stdin; SELECT 'not run';\n1\n\\.\nSELECT 2;\n"
        #expect(try await Self.elements(sql) == [
            .copying("COPY t (a) FROM stdin", line: 1, rows: "1\n"),
            .statement("SELECT 2", line: 4),
        ])
    }

    @Test("Two COPY blocks each get their own rows")
    func twoCopyBlocks() async throws {
        let sql = "COPY a (x) FROM stdin;\n1\n\\.\nCOPY b (y) FROM stdin;\n2\n3\n\\.\nSELECT 3;\n"
        #expect(try await Self.elements(sql) == [
            .copying("COPY a (x) FROM stdin", line: 1, rows: "1\n"),
            .copying("COPY b (y) FROM stdin", line: 4, rows: "2\n3\n"),
            .statement("SELECT 3", line: 8),
        ])
    }

    @Test("Rows left unread are passed over, and their reader answers nil once the next element is asked for")
    func unreadRowsArePassedOver() async throws {
        let sql = "COPY t (a) FROM stdin;\n1\n2\n\\.\nSELECT 5;\n"
        try await Self.withFile(sql) { url in
            var iterator = SQLFileParser().parseElements(url: url, encoding: .utf8, grammar: TestGrammar.postgres)
                .makeAsyncIterator()
            let copy = try #require(try await iterator.next())
            guard case let .copyFromStandardInput(_, _, rows) = copy else {
                Issue.record("Expected the COPY, got \(copy)")
                return
            }
            let next = try #require(try await iterator.next())
            #expect(try Self.read(next) == .statement("SELECT 5", line: 5))
            #expect(try rows.nextPiece() == nil)
            let end = try await iterator.next().map { try Self.read($0) }
            #expect(end == nil)
        }
    }

    @Test("Rows read half way are passed over from where the reading stopped")
    func halfReadRowsArePassedOver() async throws {
        let sql = "COPY t (a) FROM stdin;\n1\n2\n3\n4\n5\n\\.\nSELECT 5;\n"
        try await Self.withFile(sql) { url in
            let parser = SQLFileParser(copyPieceLength: 4)
            var iterator = parser.parseElements(url: url, encoding: .utf8, grammar: TestGrammar.postgres).makeAsyncIterator()
            let copy = try #require(try await iterator.next())
            guard case let .copyFromStandardInput(_, _, rows) = copy else {
                Issue.record("Expected the COPY, got \(copy)")
                return
            }
            #expect(try rows.nextPiece() == Data("1\n2\n".utf8))
            let next = try #require(try await iterator.next())
            #expect(try Self.read(next) == .statement("SELECT 5", line: 8))
            #expect(try rows.nextPiece() == nil)
        }
    }

    @Test("A CSV header line is data, sent as the server reads it")
    func csvHeaderIsData() async throws {
        let sql = "COPY t (a, b) FROM stdin WITH (FORMAT csv, HEADER true);\na,b\n1,\"x\"\n\\.\n"
        #expect(try await Self.elements(sql) == [
            .copying("COPY t (a, b) FROM stdin WITH (FORMAT csv, HEADER true)", line: 1, rows: "a,b\n1,\"x\"\n"),
        ])
    }

    @Test("Rows keep non-ASCII text and emoji byte for byte, whatever the chunk and piece size",
          arguments: [2, 3, 5, SQLFileParser.defaultCopyPieceLength])
    func nonASCIIRowsAreByteExact(pieceLength: Int) async throws {
        let rows = "1\tcafé\n2\t日本語\n3\t😀😀😀\n"
        let sql = "COPY t (a, b) FROM stdin;\n\(rows)\\.\nSELECT 1;\n"
        for chunkSize in [1, 2, 3, 7, SQLFileParser.defaultChunkSize] {
            let parser = SQLFileParser(chunkSize: chunkSize, copyPieceLength: pieceLength)
            let pieces = try await Self.copyPieces(sql, parser: parser)
            #expect(Data(pieces.joined()) == Data(rows.utf8), "chunk \(chunkSize)")
        }
    }

    @Test("A chunk end anywhere, inside a \\. line too, changes nothing")
    func chunkEndAnywhere() async throws {
        let sql = "SET a = 1;\nCOPY t (a) FROM stdin;\r\n1\r\n\\.x\n\\.\r2\n\\\n22\n\\.\r\nSELECT 2;\nCOPY u FROM stdin;\n3\n\\."
        let expected: [Element] = [
            .statement("SET a = 1", line: 1),
            .copying("COPY t (a) FROM stdin", line: 2, rows: "1\r\n\\.x\n\\.\r2\n\\\n22\n"),
            .statement("SELECT 2", line: 9),
            .copying("COPY u FROM stdin", line: 10, rows: "3\n"),
        ]
        for chunkSize in 1...12 {
            for pieceLength in [2, 3, 5, 64] {
                let parser = SQLFileParser(chunkSize: chunkSize, copyPieceLength: pieceLength)
                #expect(try await Self.elements(sql, parser: parser) == expected, "chunk \(chunkSize), piece \(pieceLength)")
            }
        }
    }

    @Test("A row longer than a piece arrives in pieces no longer than the limit")
    func rowLongerThanAPiece() async throws {
        let row = String(repeating: "x", count: 50) + "\n"
        let pieces = try await Self.copyPieces("COPY t (a) FROM stdin;\n\(row)\\.\n", parser: SQLFileParser(copyPieceLength: 8))
        #expect(pieces.count == 7)
        #expect(pieces.allSatisfy { piece in piece.count <= 8 })
        #expect(Data(pieces.joined()) == Data(row.utf8))
    }

    @Test("Pieces end at a line end when the line fits")
    func piecesEndAtLineEnds() async throws {
        let rows = (1...500).map { "\($0)\tvalue \($0)\n" }.joined()
        let pieces = try await Self.copyPieces("COPY t (a, b) FROM stdin;\n\(rows)\\.\n", parser: SQLFileParser(copyPieceLength: 100))
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { piece in piece.count <= 100 && piece.last == 0x0A })
        #expect(Data(pieces.joined()) == Data(rows.utf8))
    }

    @Test("A piece holds at most 1 MiB of UTF-8, even of three-byte characters")
    func pieceStaysWithinOneMebibyte() async throws {
        let row = String(repeating: "日", count: 400_000) + "\n"
        let pieces = try await Self.copyPieces("COPY t (a) FROM stdin;\n\(row)\\.\n")
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { piece in piece.count <= 1_048_576 })
        #expect(Data(pieces.joined()) == Data(row.utf8))
    }

    @Test("The count reads each COPY as one statement and none of its rows")
    func countReadsCopyAsOne() async throws {
        let sql = "CREATE TABLE t (a text);\nCOPY t (a) FROM stdin;\nSELECT 1;\nDROP TABLE t;\n\\.\n"
            + "COPY t (a) FROM stdin;\nx\n\\.\nSELECT 2;\n"
        let count = try await Self.withFile(sql) { url in
            try await SQLFileParser().countStatements(url: url, encoding: .utf8, grammar: TestGrammar.postgres)
        }
        #expect(count == 4)
        #expect(try await Self.elements(sql).count == count)
    }

    @Test("The element stream yields each run the statement stream yields, GO n repeats included")
    func elementsRepeatLikeStatements() async throws {
        let sql = "SELECT 1\nGO 3\nSELECT 2\nGO\n"
        let statements = try await Self.withFile(sql) { url in
            var result: [Element] = []
            for try await (statement, line) in SQLFileParser().parseFile(url: url, encoding: .utf8, grammar: TestGrammar.sqlServer) {
                result.append(.statement(statement, line: line))
            }
            return result
        }
        #expect(statements.count == 4)
        #expect(try await Self.elements(sql, grammar: TestGrammar.sqlServer) == statements)
    }
}
