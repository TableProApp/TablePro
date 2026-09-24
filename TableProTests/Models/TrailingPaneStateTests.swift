//
//  TrailingPaneStateTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Trailing pane state", .serialized)
struct TrailingPaneStateTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "TrailingPaneStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("teardown is idempotent")
    @MainActor
    func teardownIdempotent() {
        let state = TrailingPaneState()
        state.teardown()
        state.teardown()
    }

    /// Teardown releases the presentation and keeps the conversation. Window close, disconnect and
    /// a lost session all reach it, and none of them is the user throwing a transcript away; it used
    /// to empty `messages` with nothing written to disk.
    @Test("teardown releases the surface and keeps the transcript")
    @MainActor
    func teardownKeepsTheTranscript() {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let state = TrailingPaneState(connectionId: connection.id, sessionRegistry: Self.isolatedRegistry())
        let viewModel = try? #require(state.assistant.activate(connection: connection))
        viewModel?.messages.append(ChatTurn(role: .user, blocks: [.text("keep me")]))

        state.teardown()

        #expect(state.assistant.isActivated == false)
        #expect(viewModel?.messages.isEmpty == false)
    }

    /// `AIChatViewModel.init` reads the stored conversations, so a window that never opens the
    /// assistant must never build one. It used to be forced one line into the window's `onAppear`,
    /// which put that read on the window-open path for every connection, with the feature off.
    @Test("The assistant view model is not built until something asks for it")
    @MainActor
    func assistantIsNotBuiltUntilActivated() {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let state = TrailingPaneState(connectionId: connection.id, sessionRegistry: Self.isolatedRegistry())

        #expect(state.assistant.isActivated == false)
        #expect(state.assistant.viewModelIfActivated == nil)

        state.assistant.activate(connection: connection)

        #expect(state.assistant.isActivated)
        #expect(state.assistant.viewModelIfActivated != nil)
    }

    @Test("Activating twice returns the same view model")
    @MainActor
    func activationIsIdempotent() {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let state = TrailingPaneState(connectionId: connection.id, sessionRegistry: Self.isolatedRegistry())
        let first = state.assistant.activate(connection: connection)
        let second = state.assistant.activate(connection: connection)
        #expect(first === second)
    }

    @Test("An action while the assistant is busy opens a new session and stops observing the busy one")
    @MainActor
    func busyAssistantMovesToANewSession() throws {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let registry = Self.isolatedRegistry()
        let state = TrailingPaneState(connectionId: connection.id, sessionRegistry: registry)
        let busy = try #require(state.assistant.activate(connection: connection))
        busy.streamingState = .streaming(assistantID: UUID())

        let fresh = try #require(state.assistant.activateIdleSession(connection: connection))

        #expect(fresh !== busy)
        #expect(state.assistant.viewModelIfActivated === fresh)
        #expect(fresh.connection?.id == connection.id)
        #expect(busy.isStreaming)
        #expect(registry.sessions(for: connection.id).count == 2)

        var announcements = 0
        let subscription = state.assistant.objectWillChange.sink { announcements += 1 }
        busy.inputText = "typed into the busy session"
        #expect(announcements == 0)
        fresh.inputText = "typed into the new session"
        #expect(announcements > 0)
        subscription.cancel()
    }

    @Test("An action while the assistant is idle stays in its session")
    @MainActor
    func idleAssistantKeepsItsSession() throws {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let registry = Self.isolatedRegistry()
        let state = TrailingPaneState(connectionId: connection.id, sessionRegistry: registry)
        let current = try #require(state.assistant.activate(connection: connection))

        let resolved = state.assistant.activateIdleSession(connection: connection)

        #expect(resolved === current)
        #expect(registry.sessions(for: connection.id).count == 1)
    }

    @Test("A second window's assistant follows the session the first one started")
    @MainActor
    func secondWindowFollowsTheNewSession() throws {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let registry = Self.isolatedRegistry()
        let first = TrailingPaneState(connectionId: connection.id, sessionRegistry: registry)
        let second = TrailingPaneState(connectionId: connection.id, sessionRegistry: registry)
        let busy = try #require(first.assistant.activate(connection: connection))
        second.assistant.activate(connection: connection)
        busy.streamingState = .streaming(assistantID: UUID())
        let fresh = try #require(first.assistant.activateIdleSession(connection: connection))

        second.assistant.followDisplayedSession()

        var announcements = 0
        let subscription = second.assistant.objectWillChange.sink { announcements += 1 }
        busy.inputText = "typed into the busy session"
        #expect(announcements == 0)
        fresh.inputText = "typed into the new session"
        #expect(announcements > 0)
        #expect(second.assistant.viewModelIfActivated === fresh)
        subscription.cancel()
    }

    /// A registry of its own per test, so a session written by one case cannot be restored by the
    /// next and nothing reaches the store the app uses.
    @MainActor
    private static func isolatedRegistry() -> AgentSessionRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionTests-\(UUID().uuidString)", isDirectory: true)
        return AgentSessionRegistry(store: AgentSessionStore(directory: directory))
    }

    @Test("The surface defaults to the inspector when nothing is stored")
    @MainActor
    func surfaceDefaults() throws {
        let defaults = try makeDefaults()
        let state = TrailingPaneState(connectionId: UUID(), defaults: defaults)
        #expect(state.surface == .inspector)
        #expect(state.inspector.viewMode == .fields)
    }

    @Test("The surface round-trips per connection")
    @MainActor
    func surfaceRoundTrip() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        TrailingPaneState(connectionId: connectionId, defaults: defaults).surface = .assistant
        let restored = TrailingPaneState(connectionId: connectionId, defaults: defaults)
        #expect(restored.surface == .assistant)
    }

    @Test("The view mode round-trips per connection")
    @MainActor
    func viewModeRoundTrip() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        TrailingPaneState(connectionId: connectionId, defaults: defaults).inspector.viewMode = .json
        let restored = TrailingPaneState(connectionId: connectionId, defaults: defaults)
        #expect(restored.inspector.viewMode == .json)
    }

    @Test("The surface is isolated per connection")
    @MainActor
    func surfaceIsolation() throws {
        let defaults = try makeDefaults()
        let first = UUID()
        let second = UUID()
        TrailingPaneState(connectionId: first, defaults: defaults).surface = .assistant
        #expect(TrailingPaneState(connectionId: second, defaults: defaults).surface == .inspector)
        #expect(TrailingPaneState(connectionId: first, defaults: defaults).surface == .assistant)
    }

    @Test("Nothing is persisted without a connection id")
    @MainActor
    func noConnectionMeansNoPersistence() throws {
        let defaults = try makeDefaults()
        let state = TrailingPaneState(connectionId: nil, defaults: defaults)
        state.surface = .assistant
        state.inspector.viewMode = .json
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy {
            !$0.contains("trailingPane.surface") && !$0.contains("inspector.viewMode")
        })
    }

    // MARK: - Migration

    /// The old key stored one of "Details", "JSON" or "AI Chat", conflating the surface with the
    /// inspector's rendering. Without the migration everyone lands on the inspector's fields and
    /// the surface they were using reads as removed rather than moved.
    @Test("A connection last left on AI Chat comes back on the assistant")
    @MainActor
    func migratesAIChatToTheAssistant() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        defaults.set("AI Chat", forKey: TrailingPaneState.legacyActiveTabKeyPrefix + connectionId.uuidString)

        let state = TrailingPaneState(connectionId: connectionId, defaults: defaults)

        #expect(state.surface == .assistant)
    }

    @Test("A connection last left on JSON comes back on the inspector showing JSON")
    @MainActor
    func migratesJSONToTheInspectorsJSONMode() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        defaults.set("JSON", forKey: TrailingPaneState.legacyActiveTabKeyPrefix + connectionId.uuidString)

        let state = TrailingPaneState(connectionId: connectionId, defaults: defaults)

        #expect(state.surface == .inspector)
        #expect(state.inspector.viewMode == .json)
    }

    @Test("A connection last left on Details comes back on the inspector's fields")
    @MainActor
    func migratesDetailsToTheInspector() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        defaults.set("Details", forKey: TrailingPaneState.legacyActiveTabKeyPrefix + connectionId.uuidString)

        let state = TrailingPaneState(connectionId: connectionId, defaults: defaults)

        #expect(state.surface == .inspector)
        #expect(state.inspector.viewMode == .fields)
    }

    @Test("The legacy key is consumed so it cannot override a later choice")
    @MainActor
    func migrationConsumesTheLegacyKey() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let legacyKey = TrailingPaneState.legacyActiveTabKeyPrefix + connectionId.uuidString
        defaults.set("AI Chat", forKey: legacyKey)

        _ = TrailingPaneState(connectionId: connectionId, defaults: defaults)
        #expect(defaults.string(forKey: legacyKey) == nil)

        TrailingPaneState(connectionId: connectionId, defaults: defaults).surface = .inspector
        #expect(TrailingPaneState(connectionId: connectionId, defaults: defaults).surface == .inspector)
    }
}
