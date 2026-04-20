//
//  RightPanelStateTests.swift
//  TableProTests
//
//  Tests for RightPanelState teardown.
//

import Foundation
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

    @Test("teardown nils schemaProvider on aiViewModel")
    @MainActor
    func teardown_nilsSchemaProvider() {
        let state = RightPanelState()
        state.aiViewModel.schemaProvider = SQLSchemaProvider()
        #expect(state.aiViewModel.schemaProvider != nil)

        state.teardown()

        #expect(state.aiViewModel.schemaProvider == nil)
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
