//
//  AIChatViewModelSlashTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("AIChatViewModel runSlashCommand")
@MainActor
struct AIChatViewModelSlashTests {
    @Test("/help appends an assistant turn with the command list")
    func helpAppendsAssistantTurn() {
        let vm = AIChatViewModel()
        vm.runSlashCommand(.help)

        let assistant = vm.messages.last(where: { $0.role == .assistant })
        #expect(assistant != nil)
        #expect(assistant?.plainText.contains("Available commands") == true)
        #expect(assistant?.plainText.contains("/explain") == true)
        #expect(assistant?.plainText.contains("/help") == true)
    }

    @Test("/help is idempotent: pressing it twice doesn't append twice")
    func helpDeduplicates() {
        let vm = AIChatViewModel()
        vm.runSlashCommand(.help)
        let countAfterFirst = vm.messages.count
        vm.runSlashCommand(.help)
        #expect(vm.messages.count == countAfterFirst)
    }

    @Test("/explain with no editor query and no body sets an error message")
    func explainWithoutQueryErrors() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.currentQuery = nil

        vm.runSlashCommand(.explain)

        #expect(vm.errorMessage != nil)
        #expect(vm.errorMessage?.contains("explain") == true)
        #expect(vm.messages.isEmpty)
    }

    @Test("/explain with body uses the body as the query")
    func explainPrefersBody() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.currentQuery = "SELECT 1"

        vm.runSlashCommand(.explain, body: "SELECT * FROM custom")

        let userTurns = vm.messages.filter { $0.role == .user }
        #expect(userTurns.count >= 2)
        #expect(userTurns.first?.plainText == "/explain SELECT * FROM custom")
        let prompt = userTurns.last?.plainText ?? ""
        #expect(prompt.contains("SELECT * FROM custom"))
        #expect(!prompt.contains("SELECT 1"))
    }

    @Test("/explain falls back to editor query when body is empty")
    func explainFallsBackToEditorQuery() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.currentQuery = "SELECT * FROM editor_query"

        vm.runSlashCommand(.explain)

        let userTurns = vm.messages.filter { $0.role == .user }
        #expect(userTurns.first?.plainText == "/explain")
        let prompt = userTurns.last?.plainText ?? ""
        #expect(prompt.contains("SELECT * FROM editor_query"))
    }

    @Test("Slash invocation appears as a user turn before the prompt template")
    func slashInvocationVisibleAsUserTurn() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.currentQuery = "SELECT 1"

        vm.runSlashCommand(.optimize)

        let firstUserTurn = vm.messages.first(where: { $0.role == .user })
        #expect(firstUserTurn?.plainText == "/optimize")
    }

    @Test("runSlashCommand clears inputText and errorMessage")
    func runSlashCommandClearsTransientState() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.currentQuery = "SELECT 1"
        vm.inputText = "/explain"
        vm.errorMessage = "stale"

        vm.runSlashCommand(.explain)

        #expect(vm.inputText.isEmpty)
        #expect(vm.errorMessage == nil)
    }
}
