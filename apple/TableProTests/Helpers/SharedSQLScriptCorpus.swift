//
//  SharedSQLScriptCorpus.swift
//  TableProTests
//
//  The script corpus the core's tests and the statement scanner's tests run, with each case's expected statements.
//

import Foundation
@testable import TablePro

struct SharedSQLScriptCorpus: Decodable {
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

        var databaseType: DatabaseType? {
            SharedSQLScriptCorpus.dialects[dialect]
        }
    }

    let cases: [Case]

    private static let dialects: [String: DatabaseType] = [
        "postgresql": .postgresql, "mysql": .mysql, "sqlite": .sqlite, "mssql": .mssql, "clickhouse": .clickhouse,
        "duckdb": .duckdb, "cql": .cassandra,
    ]

    static func load() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("core/crates/core/tests/fixtures/sql_script_corpus.json")
        return try JSONDecoder().decode(SharedSQLScriptCorpus.self, from: Data(contentsOf: url)).cases
    }
}
