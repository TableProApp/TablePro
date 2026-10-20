//
//  KeyboardInteractivePromptKindTests.swift
//  TableProSSHTransportTests
//

import Foundation
import Testing

@testable import TableProSSHTransport

struct KeyboardInteractivePromptKindTests {
    @Test("A password prompt is the SSH password", arguments: ["Password: ", "PASSWORD:", "(tablepro@127.0.0.1) Password: "])
    func passwordPrompt(text: String) {
        #expect(KeyboardInteractivePromptKind(promptText: text) == .password)
    }

    @Test(
        "A prompt naming a code is a TOTP prompt",
        arguments: [
            "Verification code: ", "Enter OTP: ", "Token: ", "TOTP: ", "2FA: ", "One-time code: ", "Second factor: ",
        ]
    )
    func codePrompt(text: String) {
        #expect(KeyboardInteractivePromptKind(promptText: text) == .totp)
    }

    @Test("One-time password asks for a code, not the SSH password")
    func oneTimePasswordIsACode() {
        #expect(KeyboardInteractivePromptKind(promptText: "One-time password: ") == .totp)
        #expect(KeyboardInteractivePromptKind(promptText: "Password and verification code: ") == .totp)
    }

    @Test("A prompt with no known word is unmatched", arguments: ["Enter your PIN: ", "Response: ", ""])
    func unmatchedPrompt(text: String) {
        #expect(KeyboardInteractivePromptKind(promptText: text) == .unmatched)
    }
}
