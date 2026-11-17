// The corpus the statement scanner and the core's script reader run, read by the import a chunk at a time. The import
// drops the comments between statements' code, so each statement is compared as its code without comments or blanks.

import Foundation
import TableProSQLGrammar
import Testing

@testable import TableProSQLFile

private struct SharedSQLScriptCorpus: Decodable {
    struct Batch: Decodable {
        let text: String
        let `repeat`: Int
    }

    struct Case: Decodable {
        let name: String
        let dialect: String
        let sql: String
        let statements: [String]
        let batches: [Batch]?

        var grammar: SQLLexicalGrammar? {
            Self.databaseTypeIds[dialect].map { TestGrammar.of($0) }
        }

        private static let databaseTypeIds = [
            "postgresql": "PostgreSQL", "mysql": "MySQL", "sqlite": "SQLite", "mssql": "SQL Server",
            "clickhouse": "ClickHouse", "duckdb": "DuckDB", "cql": "Cassandra",
        ]
    }

    let cases: [Case]

    static func load() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("core/crates/core/tests/fixtures/sql_script_corpus.json")
        return try JSONDecoder().decode(SharedSQLScriptCorpus.self, from: Data(contentsOf: url)).cases
    }
}

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
            let grammar = try #require(testCase.grammar, "\(testCase.dialect)")
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
