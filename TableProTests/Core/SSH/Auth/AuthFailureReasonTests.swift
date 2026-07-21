//
//  AuthFailureReasonTests.swift
//  TableProTests
//
//  Verifies that the user-facing error string matches the failure cause so the alert
//  doesn't say "Check your credentials or private key" when the user's only mistake was
//  typing a wrong TOTP code (TableProApp/TablePro#1005 follow-up).
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("SSHTunnelError.authenticationFailed reason")
struct AuthFailureReasonTests {
    @Test("Verification-code reason mentions the authenticator, not the password")
    func verificationCodeMessage() {
        let error = SSHTunnelError.authenticationFailed(reason: .verificationCode)
        let description = error.errorDescription ?? ""

        #expect(description.localizedCaseInsensitiveContains("verification code"))
        #expect(description.localizedCaseInsensitiveContains("authenticator"))
        #expect(!description.localizedCaseInsensitiveContains("private key"))
    }

    @Test("Password reason points at the password, not the key")
    func passwordMessage() {
        let error = SSHTunnelError.authenticationFailed(reason: .password)
        let description = error.errorDescription ?? ""

        #expect(description.localizedCaseInsensitiveContains("password"))
        #expect(!description.localizedCaseInsensitiveContains("private key"))
        #expect(!description.localizedCaseInsensitiveContains("verification code"))
    }

    @Test("Private key reason points at the key file")
    func privateKeyMessage() {
        let error = SSHTunnelError.authenticationFailed(reason: .privateKey)
        let description = error.errorDescription ?? ""

        #expect(description.localizedCaseInsensitiveContains("private key"))
        #expect(!description.localizedCaseInsensitiveContains("verification code"))
    }

    @Test("Agent reason mentions the agent")
    func agentMessage() {
        let error = SSHTunnelError.authenticationFailed(reason: .agentRejected)
        let description = error.errorDescription ?? ""

        #expect(description.localizedCaseInsensitiveContains("agent"))
    }

    @Test("Passwordless reason points at the server, not the user's credentials")
    func passwordlessRejectedMessage() {
        let error = SSHTunnelError.authenticationFailed(reason: .passwordlessRejected)
        let description = error.errorDescription ?? ""

        #expect(description.localizedCaseInsensitiveContains("passwordless"))
        #expect(!description.localizedCaseInsensitiveContains("verification code"))
    }

    @Test("Keyboard-interactive reason points at the verification response")
    func keyboardInteractiveMessage() {
        let error = SSHTunnelError.authenticationFailed(reason: .keyboardInteractive)
        let description = error.errorDescription ?? ""

        #expect(description.localizedCaseInsensitiveContains("verification"))
        #expect(!description.localizedCaseInsensitiveContains("private key"))
    }

    @Test("Cancelled reason says the attempt was cancelled")
    func cancelledMessage() {
        let error = SSHTunnelError.authenticationFailed(reason: .cancelled)
        let description = error.errorDescription ?? ""

        #expect(description.localizedCaseInsensitiveContains("cancel"))
    }

    @Test("Generic reason keeps the original wording for unknown cases")
    func genericMessage() {
        let error = SSHTunnelError.authenticationFailed(reason: .generic)
        #expect(error.errorDescription == "SSH authentication failed. Check your credentials or private key.")
    }

    @Test("Each reason produces a distinct, non-empty message")
    func allReasonsHaveDistinctMessages() {
        let messages = AuthFailureReason.allCases.map {
            SSHTunnelError.authenticationFailed(reason: $0).errorDescription ?? ""
        }

        #expect(!messages.contains(""))
        #expect(Set(messages).count == messages.count)
    }
}
