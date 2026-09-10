//
//  QuickSwitcherHostResolverTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("QuickSwitcherHostResolver")
struct QuickSwitcherHostResolverTests {
    /// The registry the candidates come from is a dictionary with no order, so before this was
    /// fixed the result landed in whichever window it happened to yield first, overwriting an
    /// editor the user was not looking at.
    @Test("The invoking window wins over every other window that could host")
    func preferredWindowWins() {
        let invoking = UUID()
        let others = [UUID(), UUID(), UUID()]

        let host = QuickSwitcherHostResolver.host(
            preferred: invoking,
            candidates: others + [invoking],
            mostRecentlyFocused: others[0]
        )

        #expect(host == invoking)
    }

    @Test("The most recently focused window wins when the invoking window cannot host")
    func mostRecentlyFocusedWinsWithoutPreferred() {
        let candidates = [UUID(), UUID(), UUID()]

        let host = QuickSwitcherHostResolver.host(
            preferred: nil,
            candidates: candidates,
            mostRecentlyFocused: candidates[2]
        )

        #expect(host == candidates[2])
    }

    @Test("A candidate is picked when nothing was recently focused")
    func fallsBackToFirstCandidate() {
        let candidates = [UUID(), UUID()]

        let host = QuickSwitcherHostResolver.host(
            preferred: nil,
            candidates: candidates,
            mostRecentlyFocused: nil
        )

        #expect(host == candidates[0])
    }

    @Test("A recently focused window that cannot host is ignored")
    func ignoresFocusedWindowOutsideCandidates() {
        let candidates = [UUID(), UUID()]

        let host = QuickSwitcherHostResolver.host(
            preferred: nil,
            candidates: candidates,
            mostRecentlyFocused: UUID()
        )

        #expect(host == candidates[0])
    }

    @Test("An invoking window that cannot host does not win")
    func preferredOutsideCandidatesIsIgnored() {
        let candidates = [UUID(), UUID()]

        let host = QuickSwitcherHostResolver.host(
            preferred: UUID(),
            candidates: candidates,
            mostRecentlyFocused: candidates[1]
        )

        #expect(host == candidates[1])
    }

    @Test("No candidate means no host")
    func noCandidatesYieldsNil() {
        let host = QuickSwitcherHostResolver.host(
            preferred: UUID(),
            candidates: [UUID](),
            mostRecentlyFocused: UUID()
        )

        #expect(host == nil)
    }
}
