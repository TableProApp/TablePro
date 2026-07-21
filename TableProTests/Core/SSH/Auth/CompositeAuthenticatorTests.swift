//
//  CompositeAuthenticatorTests.swift
//  TableProTests
//
//  CompositeAuthenticator swallows a method failure and tries the next method (needed for the
//  publickey partial-success chain), but a user cancellation must abort the whole chain instead
//  of falling through to a stale password or agent. The abort hinges on this predicate.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("SSHTunnelError.isUserCancelledAuthentication")
struct CompositeAuthenticatorCancellationTests {
    @Test("A cancelled auth failure is recognized as a user cancellation")
    func cancelledReasonIsUserCancelled() {
        #expect(SSHTunnelError.authenticationFailed(reason: .cancelled).isUserCancelledAuthentication)
    }

    @Test("Every other auth failure reason is not a user cancellation")
    func otherReasonsAreNotUserCancelled() {
        for reason in AuthFailureReason.allCases where reason != .cancelled {
            #expect(!SSHTunnelError.authenticationFailed(reason: reason).isUserCancelledAuthentication)
        }
    }

    @Test("Non-authentication tunnel errors are not user cancellations")
    func nonAuthErrorsAreNotUserCancelled() {
        #expect(!SSHTunnelError.connectionTimeout.isUserCancelledAuthentication)
        #expect(!SSHTunnelError.channelOpenFailed.isUserCancelledAuthentication)
    }
}
