//
//  TrailingPaneStateTests.swift
//  TableProTests
//

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

    @Test("teardown clears the assistant's session data")
    @MainActor
    func teardownClearsAssistantSession() {
        let state = TrailingPaneState()
        let viewModel = state.assistant.activate()
        viewModel.connection = TestFixtures.makeConnection(type: .mysql)
        #expect(viewModel.connection != nil)

        state.teardown()

        #expect(viewModel.connection == nil)
        #expect(viewModel.messages.isEmpty)
    }

    /// `AIChatViewModel.init` reads the stored conversations, so a window that never opens the
    /// assistant must never build one. It used to be forced one line into the window's `onAppear`,
    /// which put that read on the window-open path for every connection, with the feature off.
    @Test("The assistant view model is not built until something asks for it")
    @MainActor
    func assistantIsNotBuiltUntilActivated() {
        let state = TrailingPaneState()

        #expect(state.assistant.isActivated == false)
        #expect(state.assistant.viewModelIfActivated == nil)

        state.assistant.activate()

        #expect(state.assistant.isActivated)
        #expect(state.assistant.viewModelIfActivated != nil)
    }

    @Test("Activating twice returns the same view model")
    @MainActor
    func activationIsIdempotent() {
        let state = TrailingPaneState()
        let first = state.assistant.activate()
        let second = state.assistant.activate()
        #expect(first === second)
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
