//
//  AccountErrorPresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AccountErrorPresentationTests {
    private static let unreadable = AccountError.invalidResponse.friendlyDescription

    @Test("Declining on the confirmation screen says nothing, like closing the sheet")
    func declinedSaysNothing() {
        #expect(AccountError.oauth("access_denied", description: nil).friendlyDescription == nil)
        #expect(AccountError.canceled.friendlyDescription == nil)
    }

    @Test("A busy server asks to try later rather than blaming its response")
    func busyServerAsksToTryLater() throws {
        let busy = try #require(AccountError.oauth("temporarily_unavailable", description: nil).friendlyDescription)
        #expect(busy != Self.unreadable)
    }

    @Test("A session the server ended asks to sign in again")
    func signedOutAsksToSignIn() throws {
        let signedOut = try #require(AccountError.signedOut.friendlyDescription)
        #expect(signedOut != Self.unreadable)
        #expect(signedOut != AccountError.oauth("temporarily_unavailable", description: nil).friendlyDescription)
    }

    @Test("Any other OAuth error reads as an unreadable response")
    func otherOAuthErrorsAreUnreadable() {
        #expect(AccountError.oauth("invalid_grant", description: nil).friendlyDescription == Self.unreadable)
    }
}
