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
@testable import TablePro
import Testing

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

    @Test("Generic reason keeps the original wording for unknown cases")
    func genericMessage() {
        let error = SSHTunnelError.authenticationFailed(reason: .generic)
        #expect(error.errorDescription == "SSH authentication failed. Check your credentials or private key.")
    }

    @Test("Each reason produces a distinct, non-empty message")
    func allReasonsHaveDistinctMessages() {
        let messages: [String] = [
            SSHTunnelError.authenticationFailed(reason: .password).errorDescription ?? "",
            SSHTunnelError.authenticationFailed(reason: .verificationCode).errorDescription ?? "",
            SSHTunnelError.authenticationFailed(reason: .privateKey).errorDescription ?? "",
            SSHTunnelError.authenticationFailed(reason: .agentRejected).errorDescription ?? "",
            SSHTunnelError.authenticationFailed(reason: .generic).errorDescription ?? ""
        ]

        #expect(!messages.contains(""))
        #expect(Set(messages).count == messages.count)
    }
}
