//
//  FilterFocusStateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Filter Focus State")
struct FilterFocusStateTests {
    @Test("Claims focus when requested id matches identity")
    func testClaimFocus_newRequestClaims() {
        var state = FilterFocusState()
        let identity = UUID()
        let claimed = state.claimFocus(requestedId: identity, identity: identity)
        #expect(claimed)
        #expect(state.claimedId == identity)
    }

    @Test("Does not re-claim focus it already owns")
    func testClaimFocus_repeatedRequestDoesNotReclaim() {
        var state = FilterFocusState()
        let identity = UUID()
        _ = state.claimFocus(requestedId: identity, identity: identity)
        let reclaimed = state.claimFocus(requestedId: identity, identity: identity)
        #expect(!reclaimed)
    }

    @Test("Does not claim focus requested for another identity")
    func testClaimFocus_otherIdentityDoesNotClaim() {
        var state = FilterFocusState()
        let claimed = state.claimFocus(requestedId: UUID(), identity: UUID())
        #expect(!claimed)
        #expect(state.claimedId == nil)
    }

    @Test("Does not claim focus when nothing is requested")
    func testClaimFocus_nilRequestDoesNotClaim() {
        var state = FilterFocusState()
        let claimed = state.claimFocus(requestedId: nil, identity: UUID())
        #expect(!claimed)
    }

    @Test("Releasing focus allows a later re-claim")
    func testReleaseFocus_allowsReclaim() {
        var state = FilterFocusState()
        let identity = UUID()
        _ = state.claimFocus(requestedId: identity, identity: identity)
        state.releaseFocus()
        #expect(state.claimedId == nil)
        let reclaimed = state.claimFocus(requestedId: identity, identity: identity)
        #expect(reclaimed)
    }

    @Test("Click-driven focus suppresses a redundant programmatic claim")
    func testMarkFocused_suppressesRedundantClaim() {
        var state = FilterFocusState()
        let identity = UUID()
        state.markFocused(identity)
        let claimed = state.claimFocus(requestedId: identity, identity: identity)
        #expect(!claimed)
    }

    @Test("Focus marked on another identity does not block this identity")
    func testMarkFocused_otherIdentityDoesNotBlockClaim() {
        var state = FilterFocusState()
        let identity = UUID()
        state.markFocused(UUID())
        let claimed = state.claimFocus(requestedId: identity, identity: identity)
        #expect(claimed)
    }
}
