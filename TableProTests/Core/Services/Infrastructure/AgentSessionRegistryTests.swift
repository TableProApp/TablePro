//
//  AgentSessionRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AgentSessionRegistry", .serialized)
struct AgentSessionRegistryTests {
    @MainActor
    private func makeRegistry(
        connections: [DatabaseConnection] = []
    ) -> (AgentSessionRegistry, ToolApprovalCenter, URL) {
        let chatDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-registry-\(UUID().uuidString)", isDirectory: true)
        let storeURL = chatDirectory.appendingPathComponent("agent_sessions.json")
        let approvals = ToolApprovalCenter()
        let registry = AgentSessionRegistry(
            services: TestFixtures.makeServices(aiChatStorage: AIChatStorage(directory: chatDirectory)),
            store: AgentSessionStore(fileURL: storeURL),
            approvals: approvals,
            connectionLookup: { id in connections.first { $0.id == id } }
        )
        return (registry, approvals, chatDirectory)
    }

    @Test("A read never creates a session")
    @MainActor
    func readsDoNotCreate() {
        let (registry, _, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()

        #expect(registry.existingDefaultSession(for: connectionId) == nil)
        #expect(registry.existingSession(id: UUID()) == nil)
        #expect(registry.sessions.isEmpty)
    }

    @Test("Two sessions on one connection coexist")
    @MainActor
    func twoSessionsOnOneConnection() {
        let (registry, _, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = TestFixtures.makeConnection()

        let first = registry.makeSession(connection: connection)
        let second = registry.makeSession(connection: connection)

        #expect(first.id != second.id)
        #expect(registry.sessions(for: connection.id).count == 2)
    }

    @Test("Each session gets its own engine and transcript")
    @MainActor
    func sessionsHoldTheirOwnTranscript() {
        let (registry, _, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = TestFixtures.makeConnection()

        let first = registry.makeSession(connection: connection)
        let second = registry.makeSession(connection: connection)
        first.viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("first")]))

        #expect(first.viewModel.messages.count == 1)
        #expect(second.viewModel.messages.isEmpty)
        #expect(first.viewModel.sessionId != second.viewModel.sessionId)
    }

    @Test("The default session is the most recent non-terminal one")
    @MainActor
    func defaultSessionSkipsTerminalSessions() {
        let (registry, _, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = TestFixtures.makeConnection()

        let stopped = registry.makeSession(connection: connection)
        let live = registry.makeSession(connection: connection)
        stopped.stop()

        #expect(registry.existingDefaultSession(for: connection.id)?.id == live.id)
    }

    @Test("Read-or-create returns the session that already exists")
    @MainActor
    func readOrCreateReuses() {
        let (registry, _, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = TestFixtures.makeConnection()

        let created = registry.session(for: connection)
        let resolved = registry.session(for: connection)

        #expect(created.id == resolved.id)
        #expect(registry.sessions.count == 1)
    }

    @Test("Stopping a connection's sessions leaves their transcripts in place")
    @MainActor
    func stopKeepsTranscript() {
        let (registry, _, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = TestFixtures.makeConnection()
        let session = registry.makeSession(connection: connection)
        session.viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("keep me")]))

        registry.stopSessions(for: connection.id)

        #expect(session.status == .stopped)
        #expect(session.viewModel.messages.count == 1)
        #expect(registry.sessions.count == 1)
    }

    @Test("Stopping one connection's sessions leaves another connection's alone")
    @MainActor
    func stopIsScopedToTheConnection() {
        let (registry, _, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = TestFixtures.makeConnection(name: "mine")
        let theirs = TestFixtures.makeConnection(name: "theirs")
        let ours = registry.makeSession(connection: mine)
        let others = registry.makeSession(connection: theirs)

        registry.stopSessions(for: mine.id)

        #expect(ours.status == .stopped)
        #expect(others.status == .idle)
    }

    @Test("Removing a session keeps its partial turn and drops the row")
    @MainActor
    func removeKeepsPartialTurn() {
        let (registry, _, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = TestFixtures.makeConnection()
        let session = registry.makeSession(connection: connection)
        session.viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("partial")]))

        registry.remove(id: session.id)

        #expect(registry.sessions.isEmpty)
        #expect(session.status == .stopped)
        #expect(session.viewModel.messages.count == 1)
    }

    @Test("One session's pending approval does not mark another session")
    @MainActor
    func approvalScopingDoesNotBleed() async {
        let (registry, approvals, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = TestFixtures.makeConnection()
        let waiting = registry.makeSession(connection: connection)
        let quiet = registry.makeSession(connection: connection)

        let request = ApprovalRequestID(sessionId: waiting.id, toolUseId: "call_0")
        let pending = Task { await approvals.awaitDecision(for: request) }
        await Task.yield()

        #expect(waiting.status == .waitingOnYou)
        #expect(quiet.status == .idle)

        approvals.resolve(request, decision: .cancel)
        _ = await pending.value

        #expect(waiting.status == .idle)
    }

    @Test("A session whose connection is gone is not restored")
    @MainActor
    func restoreDropsSessionsWithNoConnection() async {
        let chatDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: chatDirectory) }
        let storeURL = chatDirectory.appendingPathComponent("agent_sessions.json")
        let store = AgentSessionStore(fileURL: storeURL)
        let survivor = TestFixtures.makeConnection(name: "still here")
        await store.save([
            record(connectionId: survivor.id, name: survivor.name, status: .stopped),
            record(connectionId: UUID(), name: "deleted", status: .stopped)
        ])

        let registry = AgentSessionRegistry(
            services: TestFixtures.makeServices(aiChatStorage: AIChatStorage(directory: chatDirectory)),
            store: store,
            approvals: ToolApprovalCenter(),
            connectionLookup: { $0 == survivor.id ? survivor : nil }
        )
        registry.restoreIfNeeded()

        #expect(registry.sessions.map(\.connectionId) == [survivor.id])
    }

    @Test("A session left running is restored as failed, a stopped one as stopped")
    @MainActor
    func restoreStatusMatrix() async {
        let chatDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: chatDirectory) }
        let storeURL = chatDirectory.appendingPathComponent("agent_sessions.json")
        let store = AgentSessionStore(fileURL: storeURL)
        let connection = TestFixtures.makeConnection()
        await store.save([
            record(connectionId: connection.id, name: connection.name, status: .running),
            record(connectionId: connection.id, name: connection.name, status: .stopped),
            record(connectionId: connection.id, name: connection.name, status: .idle)
        ])

        let registry = AgentSessionRegistry(
            services: TestFixtures.makeServices(aiChatStorage: AIChatStorage(directory: chatDirectory)),
            store: store,
            approvals: ToolApprovalCenter(),
            connectionLookup: { _ in connection }
        )
        registry.restoreIfNeeded()

        #expect(registry.sessions.filter { $0.status == .failed }.count == 1)
        #expect(registry.sessions.filter { $0.status == .stopped }.count == 2)
    }

    @Test("Restore runs once, so a second call adds no duplicates")
    @MainActor
    func restoreIsIdempotent() async {
        let chatDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: chatDirectory) }
        let store = AgentSessionStore(fileURL: chatDirectory.appendingPathComponent("agent_sessions.json"))
        let connection = TestFixtures.makeConnection()
        await store.save([record(connectionId: connection.id, name: connection.name, status: .stopped)])

        let registry = AgentSessionRegistry(
            services: TestFixtures.makeServices(aiChatStorage: AIChatStorage(directory: chatDirectory)),
            store: store,
            approvals: ToolApprovalCenter(),
            connectionLookup: { _ in connection }
        )
        registry.restoreIfNeeded()
        registry.restoreIfNeeded()

        #expect(registry.sessions.count == 1)
    }

    @Test("A restored session's transcript is pulled in by id, not by adopting the latest")
    @MainActor
    func restoredTranscriptComesFromItsOwnConversation() async throws {
        let chatDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: chatDirectory) }
        let chatStorage = AIChatStorage(directory: chatDirectory)
        let connection = TestFixtures.makeConnection()
        var mine = AIConversation(
            messages: [ChatTurn(role: .user, blocks: [.text("mine")]).wireSnapshot],
            connectionId: connection.id,
            connectionName: connection.name
        )
        mine.updateTitle()
        let newer = AIConversation(
            title: "newer",
            messages: [ChatTurn(role: .user, blocks: [.text("newer")]).wireSnapshot],
            updatedAt: Date().addingTimeInterval(60),
            connectionId: connection.id,
            connectionName: connection.name
        )
        await chatStorage.save(mine)
        await chatStorage.save(newer)

        let store = AgentSessionStore(fileURL: chatDirectory.appendingPathComponent("agent_sessions.json"))
        await store.save([
            record(
                connectionId: connection.id,
                name: connection.name,
                status: .stopped,
                conversationId: mine.id
            )
        ])
        let registry = AgentSessionRegistry(
            services: TestFixtures.makeServices(aiChatStorage: chatStorage),
            store: store,
            approvals: ToolApprovalCenter(),
            connectionLookup: { _ in connection }
        )
        registry.restoreIfNeeded()
        let session = try #require(registry.sessions.first)

        await registry.loadTranscript(for: session)

        #expect(session.viewModel.messages.map(\.plainText) == ["mine"])
    }

    private func record(
        connectionId: UUID,
        name: String,
        status: AgentSessionStatus,
        conversationId: UUID? = nil
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            id: UUID(),
            connectionId: connectionId,
            connectionName: name,
            title: nil,
            status: status,
            conversationId: conversationId,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
