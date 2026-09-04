//
//  RightPanelStateTests.swift
//  TableProTests
//
//  Tests for RightPanelState teardown.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("RightPanelState", .serialized)
struct RightPanelStateTests {
    @Test("teardown is idempotent - calling twice does not crash")
    @MainActor
    func teardownIdempotent() {
        let state = RightPanelState()
        state.teardown()
        state.teardown()
    }

    @MainActor
    private func makeRegistry() -> (AgentSessionRegistry, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("right-panel-state-\(UUID().uuidString)", isDirectory: true)
        let registry = AgentSessionRegistry(
            services: TestFixtures.makeServices(aiChatStorage: AIChatStorage(directory: directory)),
            store: AgentSessionStore(fileURL: directory.appendingPathComponent("agent_sessions.json")),
            approvals: ToolApprovalCenter(),
            connectionLookup: { _ in nil }
        )
        return (registry, directory)
    }

    @Test("reading the panel's session never creates one")
    @MainActor
    func sessionReadDoesNotCreate() {
        let (registry, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = TestFixtures.makeConnection(type: .mysql)
        let state = RightPanelState(
            connectionId: connection.id,
            connection: connection,
            registry: registry
        )

        #expect(state.session == nil)
        #expect(state.aiViewModel == nil)
        #expect(registry.sessions.isEmpty)
    }

    @Test("starting the session is idempotent")
    @MainActor
    func startSessionReusesTheExistingOne() {
        let (registry, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = TestFixtures.makeConnection(type: .mysql)
        let state = RightPanelState(
            connectionId: connection.id,
            connection: connection,
            registry: registry
        )

        let first = state.startSession()
        let second = state.startSession()

        #expect(first?.id == second?.id)
        #expect(registry.sessions.count == 1)
        #expect(state.session?.id == first?.id)
    }

    @Test("teardown stops the session and keeps its transcript")
    @MainActor
    func teardown_stopsSessionWithoutClearingIt() {
        let (registry, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = TestFixtures.makeConnection(type: .mysql)
        let state = RightPanelState(
            connectionId: connection.id,
            connection: connection,
            registry: registry
        )
        let session = state.startSession()
        session?.viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("keep me")]))

        state.teardown()

        #expect(session?.status == .stopped)
        #expect(session?.viewModel.messages.count == 1)
        #expect(session?.viewModel.connection != nil)
    }

    @Test("teardown nils onSave closure")
    @MainActor
    func teardown_nilsOnSave() {
        let state = RightPanelState()
        state.onSave = { }
        #expect(state.onSave != nil)

        state.teardown()

        #expect(state.onSave == nil)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "RightPanelStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("active tab defaults to details when nothing stored")
    @MainActor
    func activeTabDefaults() throws {
        let defaults = try makeDefaults()
        let state = RightPanelState(connectionId: UUID(), defaults: defaults)
        #expect(state.activeTab == .details)
    }

    @Test("active tab round-trips per connection")
    @MainActor
    func activeTabRoundTrip() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let state = RightPanelState(connectionId: connectionId, defaults: defaults)
        state.activeTab = .aiChat
        let restored = RightPanelState(connectionId: connectionId, defaults: defaults)
        #expect(restored.activeTab == .aiChat)
    }

    @Test("active tab is isolated per connection")
    @MainActor
    func activeTabPerConnectionIsolation() throws {
        let defaults = try makeDefaults()
        let a = UUID()
        let b = UUID()
        RightPanelState(connectionId: a, defaults: defaults).activeTab = .aiChat
        #expect(RightPanelState(connectionId: b, defaults: defaults).activeTab == .details)
        #expect(RightPanelState(connectionId: a, defaults: defaults).activeTab == .aiChat)
    }

    @Test("active tab is not persisted without a connection id")
    @MainActor
    func activeTabNoConnectionNotPersisted() throws {
        let defaults = try makeDefaults()
        let state = RightPanelState(connectionId: nil, defaults: defaults)
        state.activeTab = .aiChat
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.contains("rightPanel.activeTab") })
    }
}
