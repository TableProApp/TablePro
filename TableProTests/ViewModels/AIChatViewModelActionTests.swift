//
//  AIChatViewModelActionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct AIChatViewModelActionTests {
    private func request(
        _ action: AIQueryAction,
        _ statement: String,
        type: DatabaseType = .mysql,
        scope: DatabaseScope? = nil,
        error: String? = nil
    ) -> AIQueryRequest {
        AIQueryRequest(action: action, statement: statement, scope: scope, databaseType: type, errorMessage: error)
    }

    private func userPrompt(_ vm: AIChatViewModel) -> String {
        vm.messages.last { $0.role == .user }?.plainText ?? ""
    }

    @Test("Fix with AI on MySQL fences the query as SQL and carries the error")
    func fixErrorSQL() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        let error = "ERROR 1146: Table 'orders' doesn't exist"

        vm.runQueryAction(request(.fixError, "SELECT * FROM orders WHERE id = 999", error: error))

        let prompt = userPrompt(vm)
        #expect(prompt.contains("SQL query"))
        #expect(prompt.contains("```sql"))
        #expect(prompt.contains("SELECT * FROM orders WHERE id = 999"))
        #expect(prompt.contains(error))
    }

    @Test("A MongoDB query is fenced as JavaScript and named for its engine")
    func mongoDBLanguage() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mongodb)

        vm.runQueryAction(request(.review, "db.users.find({})", type: .mongodb))

        let prompt = userPrompt(vm)
        #expect(prompt.contains("MongoDB query"))
        #expect(prompt.contains("```javascript"))
    }

    @Test("A Redis command is fenced as bash and named a command")
    func redisLanguage() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .redis)

        vm.runQueryAction(request(.explain, "GET mykey", type: .redis))

        let prompt = userPrompt(vm)
        #expect(prompt.contains("Redis command"))
        #expect(prompt.contains("```bash"))
    }

    @Test("Each action sends its own instruction with the statement verbatim", arguments: [
        AIQueryAction.review, .explain, .optimize
    ])
    func actionInstruction(action: AIQueryAction) {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        let statement = "SELECT u.name, COUNT(o.id) FROM users u JOIN orders o ON u.id = o.user_id GROUP BY u.name"

        vm.runQueryAction(request(action, statement))

        let prompt = userPrompt(vm)
        #expect(prompt.hasPrefix(action.instruction(typeName: "SQL query", withStructure: false)))
        #expect(prompt.contains(statement))
    }

    @Test("Without structure attached the prompt never claims it is, and an on-screen plan goes inline")
    func promptWithoutStructure() {
        let prompt = AIPromptTemplates.queryActionPrompt(
            .optimize,
            statement: "SELECT * FROM t",
            typeName: "SQL query",
            language: "sql",
            withStructure: false,
            explainPlan: "Seq Scan on t"
        )
        #expect(!prompt.contains("attached"))
        #expect(prompt.contains("Explain plan:\n```text\nSeq Scan on t\n```"))

        let withStructure = AIPromptTemplates.queryActionPrompt(
            .optimize, statement: "SELECT * FROM t", typeName: "SQL query", language: "sql"
        )
        #expect(withStructure.contains("attached"))
    }

    @Test("An empty or whitespace statement sends nothing")
    func emptyStatementIsNoOp() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)

        vm.runQueryAction(request(.review, "   \n  "))

        #expect(vm.messages.isEmpty)
    }

    @Test("A statement over the limit is refused with a reason and sends nothing")
    func oversizedStatementIsRefused() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        let huge = "SELECT " + String(repeating: "a", count: AIChatViewModel.queryActionStatementLimit + 1)

        vm.runQueryAction(request(.review, huge))

        #expect(vm.messages.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    @Test("A menu action starts a new conversation")
    func actionStartsNewConversation() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)

        vm.runQueryAction(request(.explain, "SELECT 1"))
        vm.runQueryAction(request(.optimize, "SELECT 2"))

        let userTurns = vm.messages.filter { $0.role == .user }
        #expect(userTurns.count == 1)
        #expect(userTurns.first?.plainText.contains("SELECT 2") == true)
    }

    @Test("A menu action replaces a stale editor context with its own tab's text")
    func actionReplacesStaleContext() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.currentQuery = "SELECT * FROM other_tab"
        vm.queryResults = "id | secret"

        vm.runQueryAction(AIQueryRequest(
            action: .review,
            statement: "UPDATE b SET x = 1",
            editorText: "SELECT 1;\nUPDATE b SET x = 1;",
            scope: nil,
            databaseType: .mysql
        ))

        #expect(vm.currentQuery == "SELECT 1;\nUPDATE b SET x = 1;")
        #expect(vm.queryResults == nil)
    }

    @Test("The structure attachment follows the Include schema setting")
    func structureAttachmentFollowsSetting() {
        let vm = AIChatViewModel()
        let connection = TestFixtures.makeConnection(type: .mysql)
        vm.connection = connection
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)

        vm.runQueryAction(request(.review, "SELECT * FROM orders", scope: scope))

        let attachment = vm.messages.first { $0.role == .user }?.blocks.compactMap { block -> QueryContextAttachment? in
            guard case .attachment(.queryContext(let attachment)) = block.kind else { return nil }
            return attachment
        }.first
        #expect((attachment != nil) == vm.services.appSettings.ai.includeSchema)
        if let attachment {
            #expect(attachment.statement == "SELECT * FROM orders")
            #expect(attachment.database == "shop")
            #expect(!attachment.isResolved)
            #expect(userPrompt(vm).contains("attached"))
        }
    }

    @Test("Editing a message drops its structure attachment, which described the old statement")
    func editDropsStructure() {
        let vm = AIChatViewModel()
        let connection = TestFixtures.makeConnection(type: .mysql)
        vm.connection = connection
        let attachment = QueryContextAttachment(
            connectionId: connection.id, database: "shop", schema: nil, statement: "SELECT 1", rendered: "## Query context"
        )
        let turn = ChatTurn(role: .user, blocks: [.text("Review this"), .attachment(.queryContext(attachment)), .attachment(.schema(connectionId: connection.id))])
        vm.messages = [turn]

        vm.editMessage(turn)

        #expect(vm.attachedContext == [.schema(connectionId: connection.id)])
    }

    @Test("Refusing access clears the pending walkthrough so the next message is not a rewrite")
    func denyClearsWalkthrough() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.messages.append(ChatTurn(role: .user, blocks: [.text("Review this")]))
        vm.pendingWalkthroughBeforeSQL = "SELECT 1"
        vm.pendingWalkthroughSource = QueryEditorAnchor(tabId: UUID())
        vm.streamingState = .awaitingApproval

        vm.denyAIAccess()

        #expect(vm.pendingWalkthroughBeforeSQL == nil)
        #expect(vm.pendingWalkthroughSource == nil)
    }

    @Test("A slash command is refused while a reply is streaming")
    func slashRefusedWhileStreaming() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.currentQuery = "SELECT 1"
        vm.streamingState = .streaming(assistantID: UUID())

        vm.runSlashCommand(.review)

        #expect(vm.messages.isEmpty)
    }

    @Test("/fix uses the tab's own error and failed query, never the result grid")
    func fixUsesTabError() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.currentQuery = "SELECT 1;\nSELECT nope FROM t;"
        vm.queryResults = "id | email\n1 | a@b.com"
        vm.editorTarget = AssistantEditorTarget(
            tabId: UUID(),
            scope: nil,
            errorMessage: "Unknown column 'nope'",
            errorQuery: "SELECT nope FROM t"
        )

        vm.runSlashCommand(.fix)

        let prompt = userPrompt(vm)
        #expect(prompt.contains("Unknown column 'nope'"))
        #expect(prompt.contains("SELECT nope FROM t"))
        #expect(!prompt.contains("a@b.com"))
    }

    @Test("/fix without a failed query explains itself and sends nothing")
    func fixWithoutErrorRefuses() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.currentQuery = "SELECT 1"
        vm.queryResults = "id\n1"

        vm.runSlashCommand(.fix)

        #expect(vm.messages.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    @Test("A reply in flight, and a wait on AI access, keep the session busy")
    func busyStates() {
        let vm = AIChatViewModel()
        let states: [AIChatViewModel.StreamingState] = [.loading, .streaming(assistantID: UUID()), .awaitingApproval]
        for state in states {
            vm.streamingState = state
            #expect(vm.isBusy, "\(state)")
        }
    }

    @Test("An idle, failed or paused session is not busy")
    func idleStates() {
        let vm = AIChatViewModel()
        let states: [AIChatViewModel.StreamingState] = [.idle, .failed(nil), .pausedAtToolLimit(count: 25)]
        for state in states {
            vm.streamingState = state
            #expect(!vm.isBusy, "\(state)")
        }
    }

    @Test("A tool call waiting on approval keeps its own session busy and no other")
    func pendingToolApprovalIsBusy() {
        let vm = AIChatViewModel()
        let other = AIChatViewModel()
        let center = ToolApprovalCenter.shared
        center.expect(sessionId: vm.sessionId, toolUseIds: ["call_0"])
        defer { center.forget(sessionId: vm.sessionId, toolUseIds: ["call_0"]) }

        #expect(vm.isBusy)
        #expect(!other.isBusy)
    }

    @Test("Preparing a turn, or holding one for a connect, is busy")
    func preparationIsBusy() {
        let vm = AIChatViewModel()
        vm.prepTask = Task {}
        #expect(vm.isBusy)
        vm.prepTask = nil
        #expect(!vm.isBusy)

        vm.heldTurnAwaitsConnection = true
        #expect(vm.isBusy)
    }

    private func oversized() -> String {
        String(repeating: "a", count: ChatPreflight.characterLimit + 1)
    }

    @Test("An oversized message leaves the transcript, its text goes back to the composer and its attachments go")
    func oversizedMessageReturnsToComposer() async {
        let vm = AIChatViewModel()
        let earlier = ChatTurn(role: .user, blocks: [.text("How many orders?")])
        let reply = ChatTurn(role: .assistant, blocks: [.text("42")])
        let message = ChatTurn(role: .user, blocks: [.text(oversized()), .attachment(.schema(connectionId: UUID()))])
        let placeholder = ChatTurn(role: .assistant, blocks: [])
        vm.messages = [earlier, reply, message, placeholder]
        vm.streamingState = .streaming(assistantID: placeholder.id)

        let sent = await vm.preflightCheck(
            systemPrompt: "You are a helpful database assistant.",
            turns: [earlier, reply, message].map { $0.wireSnapshot },
            assistantID: placeholder.id
        )

        #expect(!sent)
        #expect(vm.messages.map { $0.id } == [earlier.id, reply.id])
        #expect(vm.inputText == oversized())
        #expect(vm.attachedContext.isEmpty)
        #expect(vm.errorMessage == ChatPreflight.Rejection.message.explanation)
        #expect(!vm.isBusy)
    }

    @Test("After an oversized message is refused, a short one can be sent")
    func refusalLeavesAConversationThatCanSend() async {
        let vm = AIChatViewModel()
        let message = ChatTurn(role: .user, blocks: [.text(oversized())])
        let placeholder = ChatTurn(role: .assistant, blocks: [])
        vm.messages = [message, placeholder]

        _ = await vm.preflightCheck(systemPrompt: nil, turns: [message.wireSnapshot], assistantID: placeholder.id)
        let short = ChatTurn(role: .user, blocks: [.text("How many orders?")])
        vm.messages.append(short)
        let retried = await vm.preflightCheck(
            systemPrompt: nil,
            turns: vm.messages.map { $0.wireSnapshot },
            assistantID: UUID()
        )

        #expect(retried)
    }

    @Test("A slash command refused as too large takes its invocation back and clears its walkthrough")
    func refusedSlashCommandClearsWalkthrough() async {
        let vm = AIChatViewModel()
        let invocation = ChatTurn(role: .user, blocks: [.text("/review")])
        let prompt = ChatTurn(role: .user, blocks: [.text(oversized())])
        let placeholder = ChatTurn(role: .assistant, blocks: [])
        vm.messages = [invocation, prompt, placeholder]
        vm.pendingWalkthroughBeforeSQL = "SELECT 1"
        vm.pendingWalkthroughSource = QueryEditorAnchor(tabId: UUID())

        _ = await vm.preflightCheck(
            systemPrompt: nil,
            turns: [invocation, prompt].map { $0.wireSnapshot },
            assistantID: placeholder.id
        )

        #expect(vm.messages.isEmpty)
        #expect(vm.inputText == "/review")
        #expect(vm.pendingWalkthroughBeforeSQL == nil)
        #expect(vm.pendingWalkthroughSource == nil)
    }

    @Test("A long conversation is named as the cause, not the message")
    func historyIsNamed() async {
        let vm = AIChatViewModel()
        let earlier = ChatTurn(role: .user, blocks: [.text(oversized())])
        let reply = ChatTurn(role: .assistant, blocks: [.text("Done")])
        let message = ChatTurn(role: .user, blocks: [.text("And now?")])
        let placeholder = ChatTurn(role: .assistant, blocks: [])
        vm.messages = [earlier, reply, message, placeholder]

        _ = await vm.preflightCheck(
            systemPrompt: nil,
            turns: [earlier, reply, message].map { $0.wireSnapshot },
            assistantID: placeholder.id
        )

        #expect(vm.errorMessage == ChatPreflight.Rejection.history.explanation)
        #expect(vm.messages.map { $0.id } == [earlier.id, reply.id])
        #expect(vm.inputText == "And now?")
    }
}
