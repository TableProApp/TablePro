import Foundation
@testable import TableProSQLGrammar
import Testing

// The core's script reader runs the same file in its own tests, so the two read each case where the engine does.
struct SQLScriptSharedCorpusTests {
    struct Batch: Decodable, Equatable, CustomStringConvertible {
        let text: String
        let repeatCount: Int

        enum CodingKeys: String, CodingKey {
            case text
            case repeatCount = "repeat"
        }

        var description: String { "\(repeatCount)x \(text)" }
    }

    struct Case: Decodable {
        let name: String
        let dialect: String
        let sql: String
        let statements: [String]
        let batches: [Batch]?

        var grammar: SQLLexicalGrammar? {
            Self.databaseTypeIds[dialect].flatMap { SQLLexicalProfile.curated(forDatabaseTypeId: $0)?.grammar }
        }

        private static let databaseTypeIds = [
            "postgresql": "PostgreSQL", "mysql": "MySQL", "sqlite": "SQLite", "mssql": "SQL Server",
            "clickhouse": "ClickHouse", "duckdb": "DuckDB", "cql": "Cassandra",
        ]
    }

    private struct Corpus: Decodable {
        let cases: [Case]
    }

    static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("core/crates/core/tests/fixtures/sql_script_corpus.json")

    static func cases() throws -> [Case] {
        try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL)).cases
    }

    @Test("Every dialect the corpus names has a curated grammar")
    func everyDialectIsKnown() throws {
        let cases = try Self.cases()
        #expect(!cases.isEmpty)
        #expect(cases.filter { $0.grammar == nil }.map(\.dialect).isEmpty)
    }

    @Test("The scanner splits each case where the engine does")
    func scannerSplitsEachCase() throws {
        for testCase in try Self.cases() {
            guard let grammar = testCase.grammar else { continue }
            let statements = SQLStatementScanner.executableStatements(in: testCase.sql, grammar: grammar)
            #expect(statements.map(\.sql) == testCase.statements, "\(testCase.dialect): \(testCase.name)")
            guard let expected = testCase.batches else { continue }
            let separators = SQLStatementScanner.batchSeparators(in: testCase.sql, grammar: grammar)
            let batches = SQLStatementScanner.batches(in: testCase.sql, statements: statements, separators: separators)
            let read = batches.map { Batch(text: $0.sql, repeatCount: $0.repeatCount) }
            #expect(read == expected, "\(testCase.dialect): \(testCase.name)")
        }
    }
}
