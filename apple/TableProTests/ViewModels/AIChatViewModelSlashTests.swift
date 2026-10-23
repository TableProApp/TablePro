//
//  AIChatViewModelSlashTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

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
        vm.inputText = "/help"
        vm.errorMessage = "stale"

        vm.runSlashCommand(.help)

        #expect(vm.inputText.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test("A custom command's turn ranks tables by its body, not by the schema it rendered")
    func customCommandRanksByBody() {
        let rendered = ChatTurn(role: .user, blocks: [.text("Schema:\n- customers\n  - customer_id\nlist the logs")])
        let messages = [ChatTurn(role: .user, blocks: [.text("/report logs")]), rendered]

        #expect(AIChatViewModel.schemaQuestion(in: messages, override: (rendered.id, "logs")) == "logs")
        #expect(AIChatViewModel.schemaQuestion(in: messages, override: nil) == rendered.plainText)
    }

    @Test("A custom command's body does not rank a later message")
    func staleOverrideIsIgnored() {
        let earlier = ChatTurn(role: .user, blocks: [.text("rendered")])
        let later = ChatTurn(role: .user, blocks: [.text("how many orders")])

        #expect(AIChatViewModel.schemaQuestion(in: [earlier, later], override: (earlier.id, "logs")) == "how many orders")
    }

    @Test("A tool result turn does not replace the user's question")
    func toolResultTurnIsSkipped() {
        let question = ChatTurn(role: .user, blocks: [.text("how many orders")])
        let toolResult = ChatTurn(
            role: .user,
            blocks: [.toolResult(ToolResultBlock(toolUseId: "call_1", content: "rows", isError: false))]
        )
        let messages = [question, ChatTurn(role: .assistant, blocks: []), toolResult]

        #expect(AIChatViewModel.schemaQuestion(in: messages, override: nil) == "how many orders")
        #expect(AIChatViewModel.schemaQuestion(in: messages, override: (question.id, "orders")) == "orders")
    }
}
