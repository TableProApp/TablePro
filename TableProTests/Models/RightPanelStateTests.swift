//
//  RightPanelStateTests.swift
//  TableProTests
//
//  Tests for RightPanelState teardown.
//

import Foundation
import TableProPluginKit
@testable import TablePro
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
}
