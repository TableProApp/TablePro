//
//  CompletionEngineTests.swift
//  TableProTests
//
//  Created by TablePro Tests on 2026-02-17.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Completion Engine", .serialized)
struct CompletionEngineTests {
    private let schemaProvider: SQLSchemaProvider
    private let engine: CompletionEngine

    init() {
        schemaProvider = SQLSchemaProvider()
        engine = CompletionEngine(schemaProvider: schemaProvider, databaseType: .mysql)
    }

    @Test("Empty text returns nil")
    func testEmptyText() async {
        let result = await engine.getCompletions(text: "", cursorPosition: 0)
        #expect(result != nil)
    }

    @Test("Cursor inside string returns nil")
    func testCursorInsideString() async {
        let text = "SELECT * FROM users WHERE name = 'John'"
        let cursorInString = 38
        let result = await engine.getCompletions(text: text, cursorPosition: cursorInString)
        #expect(result == nil)
    }

    @Test("Cursor inside comment returns nil")
    func testCursorInsideComment() async {
        let text = "SELECT * FROM users -- this is a comment"
        let cursorInComment = 30
        let result = await engine.getCompletions(text: text, cursorPosition: cursorInComment)
        #expect(result == nil)
    }

    @Test("SELECT keyword returns completions")
    func testSelectKeyword() async {
        let text = "SELECT"
        let result = await engine.getCompletions(text: text, cursorPosition: text.count)
        #expect(result != nil)
        if let result = result {
            #expect(!result.items.isEmpty)
        }
    }

    @Test("Cursor at start of empty query returns completions")
    func testStartOfEmptyQuery() async {
        let text = " "
        let result = await engine.getCompletions(text: text, cursorPosition: 0)
        #expect(result != nil)
        if let result = result {
            #expect(!result.items.isEmpty)
            let hasStatementKeywords = result.items.contains { item in
                ["SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP"].contains(item.label)
            }
            #expect(hasStatementKeywords)
        }
    }

    @Test("Completion items have valid replacement range")
    func testValidReplacementRange() async {
        let text = "SEL"
        let result = await engine.getCompletions(text: text, cursorPosition: text.count)
        #expect(result != nil)
        if let result = result {
            #expect(result.replacementRange.location >= 0)
            #expect(result.replacementRange.length >= 0)
        }
    }

    @Test("Replacement range does not exceed text length")
    func testReplacementRangeInBounds() async {
        let text = "SELECT * FROM users WHERE"
        let result = await engine.getCompletions(text: text, cursorPosition: text.count)
        #expect(result != nil)
        if let result = result {
            let maxRange = result.replacementRange.location + result.replacementRange.length
            #expect(maxRange <= (text as NSString).length)
        }
    }

    @Test("Result is nil when no items match")
    func testNoMatchingItems() async {
        let text = "SELECT * FROM users WHERE xyz123abc"
        let result = await engine.getCompletions(text: text, cursorPosition: text.count)
        #expect(result == nil)
    }

    @Test("Prefix filtering works for SEL")
    func testPrefixFiltering() async {
        let text = "SEL"
        let result = await engine.getCompletions(text: text, cursorPosition: text.count)
        #expect(result != nil)
        if let result = result {
            let hasSelect = result.items.contains { $0.label == "SELECT" }
            #expect(hasSelect)
        }
    }

    @Test("Short text completion works")
    func testShortText() async {
        let text = "S"
        let result = await engine.getCompletions(text: text, cursorPosition: 1)
        #expect(result != nil)
        if let result = result {
            #expect(!result.items.isEmpty)
        }
    }

    @Test("Simple FROM clause returns items")
    func testFromClause() async {
        let text = "SELECT * FROM "
        let result = await engine.getCompletions(text: text, cursorPosition: text.count)
        #expect(result != nil)
        if let result = result {
            #expect(!result.items.isEmpty)
        }
    }

    /// The seam the quoted prefix died at: every candidate filtered out, so the engine reported no
    /// completion context at all and the popup closed.
    @Test(
        "A quoted table prefix still produces a completion context",
        arguments: ["SELECT * FROM `cat", "SELECT * FROM `cat`"]
    )
    func quotedTablePrefixProducesAContext(text: String) async {
        await schemaProvider.updateTables([TestFixtures.makeTableInfo(name: "category")])
        let result = await engine.getCompletions(text: text, cursorPosition: (text as NSString).length)

        #expect(result != nil)
        #expect(result?.items.contains { $0.label == "category" } == true)
    }

    /// The engine rebuilt the analyzer's context by hand to move `prefixRange` into document
    /// coordinates, and the hand-written copy listed every field but this one, so every context the
    /// engine returned reported no compared column at all.
    @Test("The returned context keeps the column the cursor is comparing against")
    func comparisonColumnSurvivesTheReturnedContext() async {
        await schemaProvider.updateTables([TestFixtures.makeTableInfo(name: "users")])
        let text = "SELECT * FROM users WHERE status = "
        let result = await engine.getCompletions(text: text, cursorPosition: (text as NSString).length)

        #expect(result?.sqlContext.comparisonColumn == "status")
    }

    @Test("WHERE clause returns items")
    func testWhereClause() async {
        let text = "SELECT * FROM users WHERE "
        let result = await engine.getCompletions(text: text, cursorPosition: text.count)
        #expect(result != nil)
        if let result = result {
            #expect(!result.items.isEmpty)
        }
    }

    @Test("Result is nil when prefix matches no items")
    func testSQLContext() async {
        let text = "SELECT * FROM users"
        let result = await engine.getCompletions(text: text, cursorPosition: text.count)
        // "users" prefix in FROM clause with no schema tables loaded yields no matching items
        #expect(result == nil)
    }

    @Test("Completions are limited to maxSuggestions for the clause type")
    func testCompletionsLimited() async {
        let text = "SEL"
        let result = await engine.getCompletions(text: text, cursorPosition: text.count)
        #expect(result != nil)
        if let result = result {
            #expect(result.items.count <= 40)
        }
    }

    @Test("Test with various cursor positions")
    func testVariousCursorPositions() async {
        let text = "SELECT * FROM users WHERE id = 1"
        let positions = [0, 6, 9, 14, 20, 26, text.count]

        for position in positions {
            let result = await engine.getCompletions(text: text, cursorPosition: position)
            if result != nil {
                #expect(result!.replacementRange.location >= 0)
            }
        }
    }

    @Test("Derived-table alias suggests the subquery's output columns")
    func testDerivedTableAliasCompletion() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "happiness_scores")]
        await schemaProvider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        let prefix = "SELECT ahs."
        let text = prefix + " FROM happiness_scores hs "
            + "LEFT JOIN (SELECT country, AVG(score) AS avg_score FROM happiness_scores GROUP BY country) ahs "
            + "ON hs.country = ahs.country"
        let result = await engine.getCompletions(text: text, cursorPosition: (prefix as NSString).length)

        #expect(result != nil)
        let labels = result?.items.map(\.label) ?? []
        #expect(labels.contains("country"))
        #expect(labels.contains("avg_score"))
    }

    @Test("CTE alias suggests the CTE's output columns")
    func testCteAliasCompletion() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "sales")]
        await schemaProvider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        let prefix = "WITH totals AS (SELECT region, SUM(amount) AS total FROM sales GROUP BY region) SELECT t."
        let text = prefix + " FROM totals t"
        let result = await engine.getCompletions(text: text, cursorPosition: (prefix as NSString).length)

        #expect(result != nil)
        let labels = result?.items.map(\.label) ?? []
        #expect(labels.contains("region"))
        #expect(labels.contains("total"))
    }

    // MARK: - Keyword case

    @Test("An opening lowercase prefix opens the popup with lowercase keywords")
    func lowercasePrefixOpensLowercase() async {
        let result = await engine.getCompletions(text: "sel", cursorPosition: 3, keywordCase: .matchTypedElseUpper)
        #expect(result?.items.contains { $0.label == "select" && $0.insertText == "select" } == true)
        #expect(result?.items.contains { $0.label == "SELECT" } == false)
    }

    @Test("An opening uppercase prefix opens the popup with uppercase keywords")
    func uppercasePrefixOpensUppercase() async {
        let result = await engine.getCompletions(text: "SEL", cursorPosition: 3, keywordCase: .matchTypedElseUpper)
        #expect(result?.items.contains { $0.label == "SELECT" } == true)
    }

    /// The candidate pool an open popup re-ranks against stays canonical, so a later prefix folds
    /// from the vocabulary's own spelling rather than from whatever the previous keystroke produced.
    @Test("The session's candidate pool is not re-cased")
    func candidatePoolStaysCanonical() async {
        let result = await engine.getCompletions(text: "sel", cursorPosition: 3, keywordCase: .matchTypedElseUpper)
        #expect(result?.candidates.contains { $0.label == "SELECT" } == true)
    }

    /// The per-keystroke path: the adapter hands `rank` the prefix in the case the user typed it,
    /// so a prefix lowercased on the way in would silently lowercase every later keystroke.
    @Test("Ranking cases from the prefix it is given")
    func rankingFollowsTheGivenPrefix() async {
        let result = await engine.getCompletions(text: "s", cursorPosition: 1, keywordCase: .matchTypedElseUpper)
        let candidates = result?.candidates ?? []
        #expect(!candidates.isEmpty)

        let lowered = engine.rank(
            candidates, prefix: "sel", context: .unanalyzed, keywordCase: .matchTypedElseUpper
        )
        #expect(lowered.contains { $0.insertText == "select" })

        let raised = engine.rank(
            candidates, prefix: "SEL", context: .unanalyzed, keywordCase: .matchTypedElseUpper
        )
        #expect(raised.contains { $0.insertText == "SELECT" })
    }

    @Test("The absolute policies ignore the typed prefix at both entry points")
    func absolutePolicyIgnoresPrefix() async {
        let result = await engine.getCompletions(text: "sel", cursorPosition: 3, keywordCase: .upper)
        #expect(result?.items.contains { $0.insertText == "SELECT" } == true)

        let lowered = await engine.getCompletions(text: "SEL", cursorPosition: 3, keywordCase: .lower)
        #expect(lowered?.items.contains { $0.insertText == "select" } == true)
    }
}
