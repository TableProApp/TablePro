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

    @Test("teardown clears aiViewModel session data")
    @MainActor
    func teardown_clearsAIViewModelSession() {
        let state = RightPanelState()
        state.aiViewModel.connection = TestFixtures.makeConnection(type: .mysql)
        #expect(state.aiViewModel.connection != nil)

        state.teardown()

        #expect(state.aiViewModel.connection == nil)
        #expect(state.aiViewModel.messages.isEmpty)
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
