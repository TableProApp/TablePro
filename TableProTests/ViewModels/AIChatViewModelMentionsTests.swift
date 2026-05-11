//
//  AIChatViewModelMentionsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("AIChatViewModel @-mentions")
@MainActor
struct AIChatViewModelMentionsTests {
    @Test("attach adds item to attachedContext")
    func attachAdds() {
        let vm = AIChatViewModel()
        let id = UUID()
        vm.attach(.table(connectionId: id, name: "Customer"))
        #expect(vm.attachedContext.count == 1)
    }

    @Test("attach is idempotent on stableKey")
    func attachDeduplicates() {
        let vm = AIChatViewModel()
        let id = UUID()
        vm.attach(.table(connectionId: id, name: "Customer"))
        vm.attach(.table(connectionId: id, name: "Customer"))
        #expect(vm.attachedContext.count == 1)
    }

    @Test("detach removes the matching item")
    func detachRemoves() {
        let vm = AIChatViewModel()
        let id = UUID()
        let item = ContextItem.table(connectionId: id, name: "Customer")
        vm.attach(item)
        vm.attach(.schema(connectionId: id))
        vm.detach(item)
        #expect(vm.attachedContext.count == 1)
        #expect(vm.attachedContext.first?.stableKey == "schema:\(id.uuidString)")
    }

    @Test("Sending with attachments embeds them as attachment blocks on the user turn")
    func sendMessageEmbedsAttachments() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.inputText = "What is this?"
        vm.attach(.currentQuery(text: "SELECT 1"))

        vm.sendMessage()

        let userTurn = vm.messages.first(where: { $0.role == .user })
        #expect(userTurn != nil)
        let attachmentBlocks = userTurn?.blocks.compactMap { block -> ContextItem? in
            if case .attachment(let item) = block.kind { return item }
            return nil
        }
        #expect(attachmentBlocks?.count == 1)
        #expect(vm.attachedContext.isEmpty)
    }

    @Test("Sending with currentQuery attachment resolves the query text on the wire")
    func currentQueryResolved() async {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.inputText = "Explain"
        vm.attach(.currentQuery(text: "SELECT * FROM Customer"))

        vm.sendMessage()

        guard let userTurn = vm.messages.first(where: { $0.role == .user }) else {
            Issue.record("expected a user turn after sendMessage")
            return
        }
        let wire = await vm.resolveTurnForWire(userTurn)
        let prompt = wire.plainText
        #expect(prompt.contains("Explain"))
        #expect(prompt.contains("SELECT * FROM Customer"))
        #expect(prompt.contains("## Current Query"))
    }

    @Test("Sending with empty input is a no-op even when attachments are present")
    func emptyInputDoesNotSend() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.attach(.currentQuery(text: "SELECT 1"))
        vm.inputText = ""

        vm.sendMessage()

        #expect(vm.messages.isEmpty)
        #expect(vm.attachedContext.count == 1)
    }

    @Test("Stored user turn keeps typed text raw (not pre-resolved)")
    func storedTurnIsRaw() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.inputText = "Explain"
        vm.attach(.currentQuery(text: "SELECT * FROM Customer"))

        vm.sendMessage()

        let userTurn = vm.messages.first(where: { $0.role == .user })
        #expect(userTurn?.plainText == "Explain")
        #expect(userTurn?.blocks.contains(where: {
            if case .attachment = $0.kind { return true } else { return false }
        }) == true)
    }

    @Test("resolveTurnForWire expands attachments into the text block")
    func resolveTurnForWireExpands() async {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        let raw = ChatTurnWire(role: .user, blocks: [
            .text("Explain"),
            .attachment(.currentQuery(text: "SELECT * FROM Customer"))
        ])

        let wire = await vm.resolveTurnForWire(raw)

        #expect(wire.id == raw.id)
        #expect(wire.plainText.contains("Explain"))
        #expect(wire.plainText.contains("SELECT * FROM Customer"))
        #expect(wire.plainText.contains("## Current Query"))
    }

    @Test("editMessage restores typed text and attachments")
    func editMessageRecoversAttachments() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.inputText = "What is this?"
        let connectionId = vm.connection?.id ?? UUID()
        vm.attach(.table(connectionId: connectionId, name: "Customer"))
        vm.sendMessage()

        let userTurn = vm.messages.first(where: { $0.role == .user })
        #expect(userTurn != nil)

        guard let userTurn else { return }
        vm.editMessage(userTurn)

        #expect(vm.inputText == "What is this?")
        #expect(vm.attachedContext.count == 1)
        #expect(vm.attachedContext.first?.stableKey.hasPrefix("table:") == true)
    }
}
