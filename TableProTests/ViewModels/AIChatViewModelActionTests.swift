//
//  AIChatViewModelActionTests.swift
//  TableProTests
//
//  Tests for AI action dispatch methods on AIChatViewModel.
//

import Foundation
import Testing

@testable import TablePro

@Suite("AIChatViewModel Action Dispatch")
@MainActor
struct AIChatViewModelActionTests {

    // MARK: - handleFixError

    @Test("handleFixError with default connection uses SQL query language")
    func fixErrorDefaultConnection() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)

        vm.handleFixError(query: "SELECT * FROM users", error: "Table not found")

        #expect(vm.messages.count >= 1)
        let userMessage = vm.messages.first { $0.role == .user }
        #expect(userMessage != nil)
        #expect(userMessage?.content.contains("SQL query") == true)
        #expect(userMessage?.content.contains("```sql") == true)
    }

    @Test("handleFixError with MongoDB connection uses JavaScript language")
    func fixErrorMongoDBConnection() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mongodb)

        vm.handleFixError(query: "db.users.find({})", error: "SyntaxError")

        let userMessage = vm.messages.first { $0.role == .user }
        #expect(userMessage != nil)
        #expect(userMessage?.content.contains("MongoDB query") == true)
        #expect(userMessage?.content.contains("```javascript") == true)
    }

    @Test("handleFixError with Redis connection uses bash language")
    func fixErrorRedisConnection() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .redis)

        vm.handleFixError(query: "GET mykey", error: "WRONGTYPE")

        let userMessage = vm.messages.first { $0.role == .user }
        #expect(userMessage != nil)
        #expect(userMessage?.content.contains("Redis command") == true)
        #expect(userMessage?.content.contains("```bash") == true)
    }

    @Test("handleFixError includes query and error text verbatim")
    func fixErrorIncludesVerbatimText() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)

        let query = "SELECT * FROM orders WHERE id = 999"
        let error = "ERROR 1146: Table 'orders' doesn't exist"

        vm.handleFixError(query: query, error: error)

        let userMessage = vm.messages.first { $0.role == .user }
        #expect(userMessage?.content.contains(query) == true)
        #expect(userMessage?.content.contains(error) == true)
    }

    // MARK: - handleExplainSelection

    @Test("handleExplainSelection with non-empty text creates user message")
    func explainSelectionNonEmpty() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)

        let selectedText = "SELECT u.name, COUNT(o.id) FROM users u JOIN orders o ON u.id = o.user_id GROUP BY u.name"

        vm.handleExplainSelection(selectedText)

        let userMessage = vm.messages.first { $0.role == .user }
        #expect(userMessage != nil)
        #expect(userMessage?.content.contains("Explain this SQL query") == true)
        #expect(userMessage?.content.contains(selectedText) == true)
        #expect(userMessage?.content.contains("```sql") == true)
    }

    @Test("handleExplainSelection with empty text is a no-op")
    func explainSelectionEmpty() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)

        let countBefore = vm.messages.count

        vm.handleExplainSelection("")

        // No new messages should be added
        #expect(vm.messages.count == countBefore)
    }

    // MARK: - handleOptimizeSelection

    @Test("handleOptimizeSelection with non-empty text creates user message")
    func optimizeSelectionNonEmpty() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)

        let selectedText = "SELECT * FROM users WHERE name LIKE '%john%'"

        vm.handleOptimizeSelection(selectedText)

        let userMessage = vm.messages.first { $0.role == .user }
        #expect(userMessage != nil)
        #expect(userMessage?.content.contains("Optimize this SQL query") == true)
        #expect(userMessage?.content.contains(selectedText) == true)
        #expect(userMessage?.content.contains("```sql") == true)
    }

    @Test("handleOptimizeSelection with empty text is a no-op")
    func optimizeSelectionEmpty() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)

        let countBefore = vm.messages.count

        vm.handleOptimizeSelection("")

        // No new messages should be added
        #expect(vm.messages.count == countBefore)
    }

    // MARK: - startNewConversation clears state

    @Test("Action methods clear previous messages via startNewConversation")
    func actionClearsPreviousMessages() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)

        vm.handleExplainSelection("SELECT 1")

        let firstCount = vm.messages.filter { $0.role == .user }.count
        #expect(firstCount >= 1)

        vm.handleOptimizeSelection("SELECT 2")

        // After second action, startNewConversation should have cleared,
        // so there should be exactly 1 user message (from the second action).
        // There may also be assistant/error messages from startStreaming.
        let userMessages = vm.messages.filter { $0.role == .user }
        #expect(userMessages.count == 1)
        #expect(userMessages.first?.content.contains("SELECT 2") == true)
    }
}
