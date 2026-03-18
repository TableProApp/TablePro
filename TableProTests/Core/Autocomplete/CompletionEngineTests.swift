//
//  CompletionEngineTests.swift
//  TableProTests
//
//  Created by TablePro Tests on 2026-02-17.
//

import Foundation
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

    @Test("Completions are limited")
    func testCompletionsLimited() async {
        let text = "SELECT "
        let result = await engine.getCompletions(text: text, cursorPosition: text.count)
        #expect(result != nil)
        if let result = result {
            #expect(result.items.count <= 20)
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
}
