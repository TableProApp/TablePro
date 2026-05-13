//
//  MentionPopoverStateTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MentionPopoverState")
@MainActor
struct MentionPopoverStateTests {
    private func candidate(_ name: String) -> MentionCandidate {
        MentionCandidate(item: .table(connectionId: UUID(), name: name))
    }

    @Test("moveSelection wraps forward at end")
    func wrapForwardAtEnd() {
        let state = MentionPopoverState()
        state.candidates = [candidate("a"), candidate("b"), candidate("c")]
        state.selectedIndex = 2
        state.moveSelection(by: 1)
        #expect(state.selectedIndex == 0)
    }

    @Test("moveSelection wraps backward at start")
    func wrapBackwardAtStart() {
        let state = MentionPopoverState()
        state.candidates = [candidate("a"), candidate("b"), candidate("c")]
        state.selectedIndex = 0
        state.moveSelection(by: -1)
        #expect(state.selectedIndex == 2)
    }

    @Test("moveSelection on empty candidates is a no-op")
    func moveOnEmpty() {
        let state = MentionPopoverState()
        state.selectedIndex = 0
        state.moveSelection(by: 1)
        #expect(state.selectedIndex == 0)
        state.moveSelection(by: -1)
        #expect(state.selectedIndex == 0)
    }

    @Test("clampSelection holds index inside bounds when candidates shrink")
    func clampWhenCandidatesShrink() {
        let state = MentionPopoverState()
        state.candidates = [candidate("a"), candidate("b"), candidate("c"), candidate("d")]
        state.selectedIndex = 3
        state.candidates = [candidate("a"), candidate("b")]
        state.clampSelection()
        #expect(state.selectedIndex == 1)
    }

    @Test("clampSelection on empty candidates resets to zero")
    func clampOnEmpty() {
        let state = MentionPopoverState()
        state.candidates = [candidate("a")]
        state.selectedIndex = 0
        state.candidates = []
        state.clampSelection()
        #expect(state.selectedIndex == 0)
    }

    @Test("reset clears everything")
    func resetClearsState() {
        let state = MentionPopoverState()
        state.candidates = [candidate("a")]
        state.selectedIndex = 0
        state.query = "abc"
        state.anchorRange = NSRange(location: 5, length: 4)
        state.isVisible = true
        state.reset()
        #expect(state.candidates.isEmpty)
        #expect(state.selectedIndex == 0)
        #expect(state.query == "")
        #expect(state.anchorRange == NSRange(location: 0, length: 0))
        #expect(state.isVisible == false)
    }

    @Test("selectedCandidate returns nil when out of bounds")
    func selectedCandidateOutOfBounds() {
        let state = MentionPopoverState()
        state.candidates = []
        state.selectedIndex = 5
        #expect(state.selectedCandidate == nil)
    }
}
