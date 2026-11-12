import Foundation
@testable import TableProSQLGrammar
import Testing

// The core keeps its own copy of these names for its MCP server, and both test suites compare theirs with one file.
struct SQLOutsideReachNamesTests {
    private static let sharedNames = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("core/crates/core/tests/fixtures/outside_reach.json")

    @Test("Each list names what the core lists")
    func listsMatchTheSharedNames() throws {
        let data = try Data(contentsOf: Self.sharedNames)
        let shared = try JSONDecoder().decode([String: [String]].self, from: data)
            .mapValues { Set($0.map { $0.uppercased() }) }
        let duckDB = SQLStatementTiering.duckDB
        let clickHouse = SQLStatementTiering.clickHouse
        let listed: [String: Set<String>] = [
            "filesystem_word_runs": Set(SQLStatementTiering.filesystemWordRuns.map { $0.joined(separator: " ") }),
            "filesystem_names": SQLStatementTiering.filesystemNames,
            "filesystem_or_code_keywords": SQLStatementTiering.filesystemOrCodeKeywords,
            "filesystem_functions": SQLStatementTiering.filesystemFunctions,
            "duckdb_functions": SQLStatementTiering.functionsReachingOutside[duckDB] ?? [],
            "duckdb_families": Set(SQLStatementTiering.functionFamiliesReachingOutside[duckDB] ?? []),
            "clickhouse_functions": SQLStatementTiering.functionsReachingOutside[clickHouse] ?? [],
            "clickhouse_families": Set(SQLStatementTiering.functionFamiliesReachingOutside[clickHouse] ?? []),
        ]
        #expect(listed == shared)
    }
}
