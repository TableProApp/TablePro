//
//  AIChatPersistenceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AIChatViewModel persistence", .serialized)
struct AIChatPersistenceTests {
    @MainActor
    private func makeViewModel() -> (AIChatViewModel, AIChatStorage, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chat-persistence-\(UUID().uuidString)", isDirectory: true)
        let storage = AIChatStorage(directory: directory)
        let viewModel = AIChatViewModel(
            services: TestFixtures.makeServices(aiChatStorage: storage),
            connection: TestFixtures.makeConnection()
        )
        return (viewModel, storage, directory)
    }

    @Test("A session holding a conversation id it never listed updates that conversation")
    @MainActor
    func restoredSessionUpdatesItsOwnConversation() async throws {
        let (viewModel, storage, directory) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationId = UUID()
        viewModel.activeConversationID = conversationId
        viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("continue this")]))

        viewModel.persistCurrentConversation()
        try await Task.sleep(for: .milliseconds(50))

        let stored = await storage.loadAll()
        #expect(stored.map(\.id) == [conversationId])
        #expect(viewModel.activeConversationID == conversationId)
    }

    @Test("A session with no conversation id yet writes one and adopts it")
    @MainActor
    func newSessionCreatesOneConversation() async throws {
        let (viewModel, storage, directory) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("first question")]))

        viewModel.persistCurrentConversation()
        viewModel.messages.append(ChatTurn(role: .assistant, blocks: [.text("an answer")]))
        viewModel.persistCurrentConversation()
        try await Task.sleep(for: .milliseconds(50))

        let stored = await storage.loadAll()
        #expect(stored.count == 1)
        #expect(stored.first?.messages.count == 2)
        #expect(stored.first?.title == "first question")
    }

    @Test("The terminate write lands without waiting for the storage actor")
    @MainActor
    func syncSaveWritesImmediately() async {
        let (viewModel, storage, directory) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("quitting now")]))

        viewModel.persistCurrentConversationSync()

        let stored = await storage.loadAll()
        #expect(stored.first?.messages.first?.plainText == "quitting now")
    }

    @Test("An empty session writes nothing")
    @MainActor
    func emptySessionWritesNothing() async throws {
        let (viewModel, storage, directory) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.persistCurrentConversation()
        viewModel.persistCurrentConversationSync()
        try await Task.sleep(for: .milliseconds(50))

        let stored = await storage.loadAll()
        #expect(stored.isEmpty)
    }

    @Test("A session's connection stays on its own record when the connection is dropped")
    @MainActor
    func connectionScopeSurvivesADroppedRecord() async throws {
        let (viewModel, storage, directory) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = try #require(viewModel.connection?.id)
        viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("scoped")]))
        viewModel.persistCurrentConversation()
        try await Task.sleep(for: .milliseconds(50))

        viewModel.connection = nil
        viewModel.messages.append(ChatTurn(role: .assistant, blocks: [.text("still scoped")]))
        viewModel.persistCurrentConversation()
        try await Task.sleep(for: .milliseconds(50))

        let stored = await storage.loadAll()
        #expect(stored.first?.connectionId == connectionId)
    }
}
