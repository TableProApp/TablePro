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

    @Test("A refused key, an offline file for another Mac and a device with an offline file each say what happened")
    func actionsSayWhatHappened() throws {
        let refusedKey = try #require(AccountError.oauth("invalid_grant", description: nil).licenseKeyDescription)
        #expect(refusedKey != Self.unreadable)
        let otherMachine = try #require(AccountError.entitlementRejected(.machine).offlineFileDescription)
        let expired = try #require(AccountError.entitlementRejected(.expired).offlineFileDescription)
        let damaged = try #require(AccountError.entitlementRejected(.signature).offlineFileDescription)
        #expect(Set([otherMachine, expired, damaged]).count == 3)
        let offlineDevice = try #require(AccountError.server(status: 409, code: "offline_file_active").deviceRemovalDescription)
        #expect(offlineDevice != AccountError.server(status: 409, code: nil).deviceRemovalDescription)
    }

    @Test("Closing the sheet or a dropped connection reads the same in every action")
    func actionsFallBackToTheGeneralText() {
        #expect(AccountError.canceled.licenseKeyDescription == nil)
        #expect(AccountError.network("offline").offlineFileDescription == AccountError.network("offline").friendlyDescription)
        #expect(AccountError.network("offline").deviceRemovalDescription == AccountError.network("offline").friendlyDescription)
    }
}
