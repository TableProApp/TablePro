//
//  SQLFileParserSharedCorpusTests.swift
//  TableProTests
//
//  The corpus the statement scanner and the core's script reader run, read by the import a chunk at a time. The import
//  drops the comments between statements' code, so each statement is compared as its code without comments or blanks.
//

import Foundation
import TableProSQLGrammar
import Testing

@testable import TablePro

struct SQLFileParserSharedCorpusTests {
    // The code a statement holds: comments dropped, blanks outside literals dropped.
    private static func code(_ statement: String, grammar: SQLLexicalGrammar) -> String {
        let text = statement as NSString
        var units: [UInt16] = []
        var index = 0
        while index < text.length {
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                if !span.kind.isComment {
                    for offset in span.start..<span.end {
                        units.append(text.character(at: offset))
                    }
                }
                index = max(span.end, index + 1)
                continue
            }
            let unit = text.character(at: index)
            if !SqlLexer.isWhitespace(unit) {
                units.append(unit)
            }
            index += 1
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func imported(_ sql: String, grammar: SQLLexicalGrammar, chunkSize: Int) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var statements: [String] = []
        let parser = SQLFileParser(chunkSize: chunkSize)
        for try await (statement, _) in parser.parseFile(url: url, encoding: .utf8, grammar: grammar) {
            statements.append(statement)
        }
        return statements
    }

    @Test("The import cuts each corpus case where the engine does, however the file is read")
    func importCutsEachCase() async throws {
        for testCase in try SharedSQLScriptCorpus.load() {
            let type = try #require(testCase.databaseType, "\(testCase.dialect)")
            let grammar = type.lexicalGrammar
            let runs = testCase.batches.map { batches in
                batches.flatMap { batch in Array(repeating: batch.text, count: batch.repeat) }
            } ?? testCase.statements
            let expected = runs.map { Self.code($0, grammar: grammar) }
            for chunkSize in [1, 7, SQLFileParser.defaultChunkSize] {
                let read = try await Self.imported(testCase.sql, grammar: grammar, chunkSize: chunkSize)
                    .map { Self.code($0, grammar: grammar) }
                #expect(read == expected, "\(testCase.dialect): \(testCase.name), chunks of \(chunkSize)")
            }
        }
    }
}
