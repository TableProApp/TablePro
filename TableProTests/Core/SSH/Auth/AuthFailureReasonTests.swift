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

    @Test("An unreachable agent names the socket source, not a key (#2583)")
    func agentUnavailableMessage() {
        for origin in AgentSocketOrigin.allCases {
            let description = SSHTunnelError.authenticationFailed(
                reason: .agentUnavailable(origin)
            ).errorDescription ?? ""

            #expect(description.localizedCaseInsensitiveContains("agent"))
            #expect(!description.localizedCaseInsensitiveContains("private key"))
            #expect(!description.localizedCaseInsensitiveContains("passphrase"))
        }
    }

    @Test("Each socket source sends the user somewhere it can actually be changed (#2583)")
    func agentUnavailableNamesItsOwnSource() {
        func message(_ origin: AgentSocketOrigin) -> String {
            SSHTunnelError.authenticationFailed(reason: .agentUnavailable(origin)).errorDescription ?? ""
        }

        #expect(message(.agentSocketSetting).localizedCaseInsensitiveContains("Agent Socket"))
        #expect(message(.identityAgentDirective).localizedCaseInsensitiveContains("IdentityAgent"))
        #expect(message(.environment).localizedCaseInsensitiveContains("SSH_AUTH_SOCK"))

        #expect(!message(.identityAgentDirective).localizedCaseInsensitiveContains("SSH_AUTH_SOCK"))
        #expect(!message(.environment).localizedCaseInsensitiveContains("IdentityAgent"))
    }

    @Test("ssh-add is only offered for the agent ssh-add can reach (#2583)")
    func agentNoIdentitiesMessage() {
        func message(_ origin: AgentSocketOrigin) -> String {
            SSHTunnelError.authenticationFailed(reason: .agentNoIdentities(origin)).errorDescription ?? ""
        }

        for origin in AgentSocketOrigin.allCases {
            #expect(message(origin).localizedCaseInsensitiveContains("agent"))
            #expect(!message(origin).localizedCaseInsensitiveContains("password"))
        }

        #expect(message(.environment).localizedCaseInsensitiveContains("ssh-add"))
        #expect(!message(.agentSocketSetting).localizedCaseInsensitiveContains("ssh-add"))
        #expect(!message(.identityAgentDirective).localizedCaseInsensitiveContains("ssh-add"))
    }

    @Test("An unavailable method names the server, not a credential (#2583)")
    func methodUnavailableMessage() {
        let error = SSHTunnelError.authenticationFailed(reason: .methodUnavailable)
        let description = error.errorDescription ?? ""

        #expect(description.localizedCaseInsensitiveContains("server"))
        #expect(!description.localizedCaseInsensitiveContains("password"))
        #expect(!description.localizedCaseInsensitiveContains("private key"))
    }

    @Test("Only a method nothing was offered through is exempt from defining a chain's failure")
    func onlyMethodUnavailableSkipsAttemptReporting() {
        for reason in AuthFailureReason.allCases {
            #expect(reason.describesAnAttempt == (reason != .methodUnavailable))
        }
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
