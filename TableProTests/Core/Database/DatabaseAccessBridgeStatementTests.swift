//
//  DatabaseAccessBridgeStatementTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Database access bridge statement text")
struct DatabaseAccessBridgeStatementTests {
    @Test(
        "Invisible characters and trailing semicolons come off an external statement",
        arguments: ["\u{FEFF}\u{0008}SELECT 1;\u{00A0};\u{200B}", "\u{3000}SELECT 1\u{2028}", " SELECT 1 ; "]
    )
    func trimsInvisibleCharacters(sql: String) {
        #expect(DatabaseAccessBridge.stripTrailingSemicolons(sql) == "SELECT 1")
    }

    @Test("A statement of nothing but invisible characters is empty")
    func invisibleOnlyStatementIsEmpty() {
        #expect(DatabaseAccessBridge.stripTrailingSemicolons("\u{FEFF}\u{0008};\u{200B}").isEmpty)
    }

    @Test(
        "A statement that trims to nothing is refused before it reaches a connection",
        arguments: ["\u{FEFF}", ";", "\u{0008} ;\u{200B}"]
    )
    func emptyStatementIsRefused(sql: String) async {
        let bridge = DatabaseAccessBridge()
        let scope = DatabaseScope(connectionId: UUID(), database: "", schema: nil)
        let error = await #expect(throws: DatabaseAccessError.self) {
            try await bridge.runStatement(scope: scope, query: sql, maxRows: 1, timeoutSeconds: 1, cancellation: nil)
        }
        guard case .invalidArgument(let detail)? = error else {
            Issue.record("Expected an invalid argument, got \(String(describing: error))")
            return
        }
        #expect(detail == String(localized: "The query is empty."))
    }

    @Test("The text an external client sends is the text that was classified")
    func sentTextMatchesClassifiedText() {
        let sent = DatabaseAccessBridge.stripTrailingSemicolons("\u{0008}SELECT 1;")
        #expect(sent == "SELECT 1")
        #expect(QueryClassifier.classifyTier(sent, databaseType: .postgresql) == .safe)
    }

    @Test("An explain behind an invisible character is not wrapped in a second explain")
    func explainBehindInvisibleCharacterIsNotWrapped() throws {
        let statement = try MCPConnectionBridge.explainStatement(
            for: "\u{FEFF}EXPLAIN SELECT 1;",
            databaseType: .postgresql,
            variantId: nil,
            analyze: false
        )
        #expect(statement == "EXPLAIN SELECT 1")
    }
}
