//
//  AIChatSessionReleaseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct AIChatSessionReleaseTests {
    private let storage = AIChatStorage.shared

    private func makeStore() -> AgentSessionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChatSessionReleaseTests-\(UUID().uuidString)", isDirectory: true)
        return AgentSessionStore(directory: directory)
    }

    private static func turns(_ texts: String...) -> [ChatTurn] {
        texts.enumerated().map { offset, text in
            ChatTurn(role: offset.isMultiple(of: 2) ? .user : .assistant, blocks: [.text(text)])
        }
    }

    private static func turns(count: Int) -> [ChatTurn] {
        (0..<count).map { offset in
            ChatTurn(role: offset.isMultiple(of: 2) ? .user : .assistant, blocks: [.text("Turn \(offset)")])
        }
    }

    private static func stored(_ text: String, connectionId: UUID) -> AIConversation {
        var conversation = AIConversation(
            messages: [ChatTurnWire(role: .user, blocks: [.text(text)])],
            connectionId: connectionId
        )
        conversation.updateTitle()
        return conversation
    }

    // Sinks deliver through `RunLoop.main.perform` and answer on the main actor; both have run once this returns.
    private static func afterQueuedMainWork() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Release

    @Test("A stopped session drops what it holds and keeps its title, draft and conversation")
    func stoppedSessionHoldsNothing() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let store = makeStore()
        let registry = AgentSessionRegistry(store: store, services: fixture.services)
        let session = registry.startSession(for: connection.id)
        let vm = session.viewModel
        vm.connection = connection
        vm.trackTableMentions()
        await vm.tableMentionBuild?.value
        await Self.afterQueuedMainWork()
        vm.messages = Self.turns("Which orders shipped late?", "Twelve.")
        vm.persistCurrentConversation()
        vm.columnsByTable["orders"] = [TestFixtures.makeColumnInfo()]
        vm.foreignKeysByTable["orders"] = []
        vm.queryResults = "12 rows"
        vm.inputText = "And yesterday?"
        let conversationId = try #require(vm.activeConversationID)
        try await waitUntil { session.title == "Which orders shipped late?" }

        registry.stopSession(id: session.id)
        await Self.afterQueuedMainWork()

        #expect(vm.messages.isEmpty)
        #expect(vm.conversations.isEmpty)
        #expect(vm.columnsByTable.isEmpty)
        #expect(vm.foreignKeysByTable.isEmpty)
        #expect(vm.queryResults == nil)
        #expect(vm.tableMentions.names.isEmpty)
        #expect(vm.tableMentionSource.isEmpty)
        #expect(vm.tableMentionObservation == nil)
        #expect(!vm.hasRestoredConversation)
        #expect(vm.inputText == "And yesterday?")
        #expect(session.conversationId == conversationId)
        #expect(session.title == "Which orders shipped late?")

        // Holding nothing, the session has nothing to write over the file on disk.
        await vm.lastConversationWrite?.value
        registry.persistNow()
        let stored = await storage.load(id: conversationId)
        #expect(stored?.messages.count == 2)
        #expect(store.load().first?.conversationId == conversationId)

        await storage.delete(conversationId)
    }

    // The restore waits for the writes the stop booked, so it reads the transcript the stop wrote.
    @Test("Reopening a stopped session reads its transcript back from disk")
    func reopeningRestoresTheTranscript() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let registry = AgentSessionRegistry(store: makeStore(), services: fixture.services)
        let session = registry.startSession(for: connection.id)
        let vm = session.viewModel
        vm.connection = connection
        vm.messages = Self.turns("Which orders shipped late?", "Twelve.")
        vm.persistCurrentConversation()
        let conversationId = try #require(vm.activeConversationID)
        registry.stopSession(id: session.id)

        session.resume()
        registry.setDisplayedSession(session.id, for: connection.id)
        vm.restoreConversationsIfNeeded()
        await vm.transcriptLoad?.value

        let texts = vm.messages.map { $0.plainText }
        #expect(texts == ["Which orders shipped late?", "Twelve."])
        #expect(vm.activeConversationID == conversationId)
        #expect(vm.conversations.contains { $0.id == conversationId })
        #expect(vm.tableMentionObservation != nil)
        await vm.tableMentionBuild?.value
        #expect(vm.tableMentions.names == ["orders"])

        await storage.delete(conversationId)
    }

    @Test("A restore that lands after a release is dropped")
    func restoreAfterReleaseIsDropped() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let conversation = Self.stored("Earlier work", connectionId: connection.id)
        await storage.save(conversation)
        let vm = AIChatViewModel(services: fixture.services, restoringConversation: conversation.id)
        vm.connection = connection

        vm.restoreConversationsIfNeeded()
        let load = try #require(vm.transcriptLoad)
        vm.releaseLoadedState()
        await load.value

        #expect(vm.messages.isEmpty)
        #expect(vm.conversations.isEmpty)
        #expect(vm.activeConversationID == nil)
        #expect(vm.conversationToRestore == conversation.id)

        vm.restoreConversationsIfNeeded()
        await vm.transcriptLoad?.value

        #expect(vm.activeConversationID == conversation.id)
        #expect(vm.messages.map { $0.plainText } == ["Earlier work"])

        await storage.delete(conversation.id)
    }

    // An engine change on an unread session derived an empty title and renamed it New Session.
    @Test("A session restored at launch keeps its title until its transcript is read")
    func unopenedSessionKeepsItsTitle() async throws {
        let store = makeStore()
        let sessionId = UUID()
        store.save([
            AgentSessionRecord(
                id: sessionId,
                connectionId: UUID(),
                conversationId: UUID(),
                status: .stopped,
                title: "Earlier work",
                startedAt: Date(timeIntervalSince1970: 1_000),
                lastActiveAt: Date(timeIntervalSince1970: 2_000)
            )
        ])
        let registry = AgentSessionRegistry(store: store)
        let session = try #require(registry.session(id: sessionId))

        session.viewModel.queryResults = nil
        await Self.afterQueuedMainWork()

        #expect(session.title == "Earlier work")
    }

    // MARK: - History list

    @Test("The history list holds no transcripts after a restore or a save")
    func conversationsHoldSummaries() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let earlier = Self.stored("Earlier work", connectionId: connection.id)
        await storage.save(earlier)
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection

        vm.restoreConversationsIfNeeded()
        await vm.transcriptLoad?.value

        #expect(vm.conversations.contains { $0.id == earlier.id && $0.title == "Earlier work" })
        #expect(vm.conversations.allSatisfy { $0.messages.isEmpty })

        vm.messages = Self.turns("Which orders shipped late?", "Twelve.")
        vm.persistCurrentConversation()
        let current = try #require(vm.activeConversationID)

        #expect(vm.conversations.first?.id == current)
        #expect(vm.conversations.first?.title == "Which orders shipped late?")
        #expect(vm.conversations.allSatisfy { $0.messages.isEmpty })
        await vm.lastConversationWrite?.value
        let saved = await storage.load(id: current)
        #expect(saved?.messages.count == 2)

        await storage.delete(earlier.id)
        await storage.delete(current)
    }

    // MARK: - Switching

    @Test("Switching reads the chosen transcript and keeps the one it left on disk")
    func switchingLoadsTheChosenTranscript() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let earlier = Self.stored("Earlier work", connectionId: connection.id)
        await storage.save(earlier)
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection
        vm.restoreConversationsIfNeeded()
        await vm.transcriptLoad?.value
        vm.messages = Self.turns("Current work")
        vm.persistCurrentConversation()
        let current = try #require(vm.activeConversationID)

        vm.switchConversation(to: earlier.id)
        await vm.transcriptLoad?.value

        #expect(vm.activeConversationID == earlier.id)
        #expect(vm.messages.map { $0.plainText } == ["Earlier work"])
        #expect(vm.conversations.allSatisfy { $0.messages.isEmpty })
        await vm.lastConversationWrite?.value
        let left = await storage.load(id: current)
        #expect(left?.messages.map { $0.plainText } == ["Current work"])

        await storage.delete(earlier.id)
        await storage.delete(current)
    }

    // The second file is gone, so only a late first load could change the transcript, whichever lands first.
    @Test("A switch that lands after a second switch is dropped")
    func lateSwitchIsDropped() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let first = Self.stored("First", connectionId: connection.id)
        let second = Self.stored("Second", connectionId: connection.id)
        await storage.save(first)
        await storage.save(second)
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection
        vm.restoreConversationsIfNeeded()
        await vm.transcriptLoad?.value
        vm.messages = Self.turns("Current work")
        vm.persistCurrentConversation()
        let current = try #require(vm.activeConversationID)
        await storage.delete(second.id)

        vm.switchConversation(to: first.id)
        let firstLoad = try #require(vm.transcriptLoad)
        vm.switchConversation(to: second.id)
        let secondLoad = try #require(vm.transcriptLoad)
        await firstLoad.value
        await secondLoad.value

        #expect(vm.activeConversationID == current)
        #expect(vm.messages.map { $0.plainText } == ["Current work"])
        #expect(vm.conversationToRestore == nil)

        await vm.lastConversationWrite?.value
        await storage.delete(first.id)
        await storage.delete(current)
    }

    @Test("A switch that lands after New Conversation is dropped")
    func switchAfterNewConversationIsDropped() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let earlier = Self.stored("Earlier work", connectionId: connection.id)
        await storage.save(earlier)
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection
        vm.restoreConversationsIfNeeded()
        await vm.transcriptLoad?.value

        vm.switchConversation(to: earlier.id)
        let load = try #require(vm.transcriptLoad)
        vm.startNewConversation()
        await load.value

        #expect(vm.activeConversationID == nil)
        #expect(vm.messages.isEmpty)

        await storage.delete(earlier.id)
    }

    // MARK: - Transcripts disk may have trimmed

    @Test(
        "A release keeps a transcript longer than disk keeps whole and drops one that fits",
        arguments: [AIChatStorage.turnsKeptWhenTrimmed + 10, 10]
    )
    func releaseKeepsWhatDiskMayTrim(turnCount: Int) async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection
        vm.restoreConversationsIfNeeded()
        await vm.transcriptLoad?.value
        await vm.tableMentionBuild?.value
        vm.messages = Self.turns(count: turnCount)
        vm.persistCurrentConversation()
        vm.columnsByTable["orders"] = [TestFixtures.makeColumnInfo()]
        let conversationId = try #require(vm.activeConversationID)

        vm.releaseLoadedState()

        let keeps = turnCount > AIChatStorage.turnsKeptWhenTrimmed
        #expect(vm.messages.count == (keeps ? turnCount : 0))
        #expect(vm.activeConversationID == (keeps ? conversationId : nil))
        #expect(vm.conversationToRestore == (keeps ? nil : conversationId))
        #expect(vm.columnsByTable.isEmpty)
        #expect(vm.tableMentions.names.isEmpty)
        #expect(vm.tableMentionObservation == nil)

        await vm.lastConversationWrite?.value
        await storage.delete(conversationId)
    }

    // The first file is deleted while the second is shown, so only memory can bring every turn back.
    @Test("Switching away from a long transcript and back keeps every turn")
    func longTranscriptSurvivesASwitch() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let other = Self.stored("Other work", connectionId: connection.id)
        await storage.save(other)
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection
        vm.restoreConversationsIfNeeded()
        await vm.transcriptLoad?.value
        let turnCount = AIChatStorage.turnsKeptWhenTrimmed + 10
        vm.messages = Self.turns(count: turnCount)
        vm.persistCurrentConversation()
        let long = try #require(vm.activeConversationID)

        vm.switchConversation(to: other.id)
        await vm.transcriptLoad?.value
        #expect(vm.activeConversationID == other.id)
        #expect(vm.conversations.first { $0.id == long }?.messages.count == turnCount)
        #expect(vm.conversations.first { $0.id == other.id }?.messages.isEmpty == true)
        await vm.lastConversationWrite?.value
        await storage.delete(long)

        vm.switchConversation(to: long)

        #expect(vm.activeConversationID == long)
        #expect(vm.messages.count == turnCount)
        #expect(vm.conversations.allSatisfy { $0.messages.isEmpty })

        await vm.lastConversationWrite?.value
        await storage.delete(other.id)
        await storage.delete(long)
    }

    // A read from disk would rebuild every turn, so the same turn objects show nothing was read.
    @Test("Picking the conversation on screen keeps its transcript and reads nothing")
    func repickingTheActiveConversationReadsNothing() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection
        vm.restoreConversationsIfNeeded()
        await vm.transcriptLoad?.value
        vm.messages = Self.turns("Which orders shipped late?", "Twelve.", "And yesterday?")
        vm.persistCurrentConversation()
        let current = try #require(vm.activeConversationID)
        let shown = vm.messages

        vm.switchConversation(to: current)
        await vm.transcriptLoad?.value

        #expect(vm.messages.count == shown.count)
        #expect(zip(vm.messages, shown).allSatisfy { $0 === $1 })
        #expect(vm.activeConversationID == current)

        await vm.lastConversationWrite?.value
        await storage.delete(current)
    }

    // MARK: - Restore

    // The message is set straight on the engine, standing in for a send whose reply has not come yet.
    @Test("A message sent before the restore lands keeps its own conversation")
    func messageBeforeRestoreWins() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let earlier = Self.stored("Earlier work", connectionId: connection.id)
        await storage.save(earlier)
        let vm = AIChatViewModel(services: fixture.services, restoringConversation: earlier.id)
        vm.connection = connection

        vm.restoreConversationsIfNeeded()
        let load = try #require(vm.transcriptLoad)
        vm.messages = Self.turns("A new question")
        await load.value

        #expect(vm.messages.map { $0.plainText } == ["A new question"])
        #expect(vm.activeConversationID == nil)
        #expect(vm.conversationToRestore == nil)
        #expect(vm.conversations.contains { $0.id == earlier.id })

        await storage.delete(earlier.id)
    }

    // A restore with no connection would list every connection's conversations.
    @Test("A restore with no connection waits for one")
    func restoreWaitsForTheConnection() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let earlier = Self.stored("Earlier work", connectionId: connection.id)
        let elsewhere = Self.stored("Elsewhere", connectionId: UUID())
        await storage.save(earlier)
        await storage.save(elsewhere)
        let vm = AIChatViewModel(services: fixture.services, restoringConversation: earlier.id)

        vm.restoreConversationsIfNeeded()

        #expect(vm.transcriptLoad == nil)
        #expect(!vm.hasRestoredConversation)

        vm.connection = connection
        vm.restoreConversationsIfNeeded()
        await vm.transcriptLoad?.value

        #expect(vm.hasRestoredConversation)
        #expect(vm.messages.map { $0.plainText } == ["Earlier work"])
        #expect(vm.conversations.contains { $0.id == earlier.id })
        #expect(!vm.conversations.contains { $0.id == elsewhere.id })

        await storage.delete(earlier.id)
        await storage.delete(elsewhere.id)
    }
}
