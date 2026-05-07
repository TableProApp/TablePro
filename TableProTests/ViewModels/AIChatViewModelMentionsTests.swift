//
//  AIChatViewModelMentionsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
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
            if case .attachment(let item) = block { return item }
            return nil
        }
        #expect(attachmentBlocks?.count == 1)
        #expect(vm.attachedContext.isEmpty)
    }

    @Test("Sending with currentQuery attachment embeds the query text in the prompt")
    func currentQueryResolved() {
        let vm = AIChatViewModel()
        vm.connection = TestFixtures.makeConnection(type: .mysql)
        vm.inputText = "Explain"
        vm.attach(.currentQuery(text: "SELECT * FROM Customer"))

        vm.sendMessage()

        let userTurn = vm.messages.first(where: { $0.role == .user })
        let prompt = userTurn?.plainText ?? ""
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
}
