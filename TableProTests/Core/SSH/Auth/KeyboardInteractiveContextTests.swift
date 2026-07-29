//
//  KeyboardInteractiveContextTests.swift
//  TableProTests
//
//  Verifies how KeyboardInteractiveContext resolves each server prompt: the password / TOTP
//  fast path, deferring unknown prompts to the interactive provider that shows the server's
//  own text (#1920), and the cancel path that fills empty responses without re-prompting. The
//  lazy TOTP fetch (a fresh code per challenge) avoids the "code expired during handshake" race.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class StubTOTPProvider: TOTPProvider, @unchecked Sendable {
    private(set) var attemptsSeen: [Int] = []
    let codes: [String]
    var errorOnAttempt: Int?

    init(codes: [String], errorOnAttempt: Int? = nil) {
        self.codes = codes
        self.errorOnAttempt = errorOnAttempt
    }

    func provideCode(attempt: Int) throws -> String {
        attemptsSeen.append(attempt)
        if errorOnAttempt == attempt {
            throw SSHTunnelError.authenticationFailed(reason: .verificationCode)
        }
        return codes[min(attempt, codes.count - 1)]
    }
}

private final class StubKeyboardInteractivePromptProvider: KeyboardInteractivePromptProvider, @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var attemptsSeen: [Int] = []
    private(set) var lastChallenge: KeyboardInteractiveChallenge?
    let answers: [String]
    var shouldCancel: Bool

    init(answers: [String], shouldCancel: Bool = false) {
        self.answers = answers
        self.shouldCancel = shouldCancel
    }

    func provideResponses(for challenge: KeyboardInteractiveChallenge, attempt: Int) throws -> [String] {
        callCount += 1
        attemptsSeen.append(attempt)
        lastChallenge = challenge
        if shouldCancel {
            throw SSHTunnelError.authenticationFailed(reason: .cancelled)
        }
        return answers
    }
}

private func context(
    password: String? = nil,
    totpProvider: (any TOTPProvider)? = nil,
    promptProvider: any KeyboardInteractivePromptProvider = StubKeyboardInteractivePromptProvider(answers: [])
) -> KeyboardInteractiveContext {
    KeyboardInteractiveContext(password: password, totpProvider: totpProvider, promptProvider: promptProvider)
}

private func prompt(_ text: String, echo: Bool = false) -> KeyboardInteractivePrompt {
    KeyboardInteractivePrompt(text: text, echo: echo)
}

@Suite("KeyboardInteractiveContext TOTP fetch")
struct KeyboardInteractiveContextTests {
    @Test("nextTotpCode returns empty when no provider is configured")
    func noProviderReturnsEmpty() {
        let ctx = context(password: "p")
        #expect(ctx.nextTotpCode() == "")
        #expect(ctx.totpAttemptCount == 0)
    }

    @Test("Each call asks the provider for a fresh code with an incrementing attempt index")
    func incrementsAttemptCounter() {
        let provider = StubTOTPProvider(codes: ["111111", "222222", "333333"])
        let ctx = context(password: "p", totpProvider: provider)

        #expect(ctx.nextTotpCode() == "111111")
        #expect(ctx.nextTotpCode() == "222222")
        #expect(ctx.nextTotpCode() == "333333")

        #expect(provider.attemptsSeen == [0, 1, 2])
        #expect(ctx.totpAttemptCount == 3)
    }

    @Test("Provider error is captured and code falls back to empty string")
    func providerErrorIsStored() {
        let provider = StubTOTPProvider(codes: ["111111"], errorOnAttempt: 0)
        let ctx = context(password: "p", totpProvider: provider)

        #expect(ctx.nextTotpCode() == "")
        #expect(ctx.lastError != nil)
        #expect(ctx.totpAttemptCount == 1)
    }
}

@Suite("KeyboardInteractiveContext prompt resolution")
struct KeyboardInteractiveResponsesTests {
    @Test("A password prompt is answered from the fast path without prompting the user")
    func passwordFastPath() {
        let stub = StubKeyboardInteractivePromptProvider(answers: [])
        let ctx = context(password: "hunter2", promptProvider: stub)

        let result = ctx.responses(name: "", instruction: "", prompts: [prompt("Password: ")])

        #expect(result == ["hunter2"])
        #expect(stub.callCount == 0)
    }

    @Test("A verification-code prompt is answered from the auto-generate provider without prompting")
    func totpFastPath() {
        let stub = StubKeyboardInteractivePromptProvider(answers: [])
        let ctx = context(totpProvider: StubTOTPProvider(codes: ["123456"]), promptProvider: stub)

        let result = ctx.responses(name: "", instruction: "", prompts: [prompt("Verification code: ")])

        #expect(result == ["123456"])
        #expect(stub.callCount == 0)
    }

    @Test("An unrecognized prompt goes to the user, never leaking the SSH password (#1920)")
    func unmatchedPromptDefersToUser() {
        let stub = StubKeyboardInteractivePromptProvider(answers: ["typed-answer"])
        let ctx = context(password: "hunter2", promptProvider: stub)

        let result = ctx.responses(name: "", instruction: "", prompts: [prompt("Enter your PIN: ")])

        #expect(result == ["typed-answer"])
        #expect(result.first != "hunter2")
        #expect(stub.callCount == 1)
    }

    @Test("Fast-path and interactive answers map back to their original prompt indices")
    func mixedFastPathAndInteractiveOrdering() {
        let stub = StubKeyboardInteractivePromptProvider(answers: ["pin-answer"])
        let ctx = context(password: "hunter2", promptProvider: stub)

        let result = ctx.responses(name: "", instruction: "", prompts: [
            prompt("Password: "),
            prompt("PIN: ")
        ])

        #expect(result == ["hunter2", "pin-answer"])
        #expect(stub.lastChallenge?.prompts.count == 1)
        #expect(stub.lastChallenge?.prompts.first?.text == "PIN: ")
    }

    @Test("Two unrecognized prompts are collected into one challenge and mapped in order")
    func multiplePromptsInOneChallenge() {
        let stub = StubKeyboardInteractivePromptProvider(answers: ["A", "B"])
        let ctx = context(promptProvider: stub)

        let result = ctx.responses(name: "", instruction: "", prompts: [
            prompt("First: ", echo: true),
            prompt("Second: ")
        ])

        #expect(result == ["A", "B"])
        #expect(stub.callCount == 1)
        #expect(stub.lastChallenge?.prompts.count == 2)
    }

    @Test("Cancelling fills empty responses and records the cancellation")
    func cancelFillsEmptyResponses() {
        let stub = StubKeyboardInteractivePromptProvider(answers: [], shouldCancel: true)
        let ctx = context(promptProvider: stub)

        let result = ctx.responses(name: "", instruction: "", prompts: [prompt("PIN: ")])

        #expect(result == [""])
        #expect(ctx.userCancelled)
        #expect(ctx.lastError != nil)
    }

    @Test("After a cancel the same session does not prompt again")
    func cancelSuppressesFurtherPrompts() {
        let stub = StubKeyboardInteractivePromptProvider(answers: [], shouldCancel: true)
        let ctx = context(promptProvider: stub)

        _ = ctx.responses(name: "", instruction: "", prompts: [prompt("PIN: ")])
        let second = ctx.responses(name: "", instruction: "", prompts: [prompt("PIN: ")])

        #expect(second == [""])
        #expect(stub.callCount == 1)
    }

    @Test("The interactive attempt index increments across rounds for retry messaging")
    func interactiveAttemptCounterIncrements() {
        let stub = StubKeyboardInteractivePromptProvider(answers: ["x"])
        let ctx = context(promptProvider: stub)

        _ = ctx.responses(name: "", instruction: "", prompts: [prompt("PIN: ")])
        _ = ctx.responses(name: "", instruction: "", prompts: [prompt("PIN: ")])

        #expect(stub.attemptsSeen == [0, 1])
    }
}

@Suite("KeyboardInteractivePrompt")
struct KeyboardInteractivePromptTests {
    @Test("Length-delimited UTF-8 bytes decode without assuming NUL-termination")
    func decodesUtf8Bytes() {
        let bytes = Array("Código: ".utf8)
        #expect(KeyboardInteractivePrompt(utf8Bytes: bytes, echo: false).text == "Código: ")
    }

    @Test("Empty byte buffer decodes to an empty string")
    func emptyBytesDecodeToEmptyString() {
        #expect(KeyboardInteractivePrompt(utf8Bytes: [], echo: true).text == "")
    }

    @Test("isSecure follows the echo flag: hidden when echo is off")
    func isSecureFollowsEcho() {
        #expect(KeyboardInteractivePrompt(text: "x", echo: false).isSecure)
        #expect(!KeyboardInteractivePrompt(text: "x", echo: true).isSecure)
    }
}

@Suite("KeyboardInteractiveAuthenticator.classify")
struct KeyboardInteractiveClassifyTests {
    @Test("A password prompt classifies as password")
    func passwordPrompt() {
        #expect(KeyboardInteractiveAuthenticator.classify("Password: ") == .password)
    }

    @Test("A verification-code prompt classifies as TOTP")
    func verificationCodePrompt() {
        #expect(KeyboardInteractiveAuthenticator.classify("Verification code: ") == .totp)
    }

    @Test("A prompt with no known keyword is unmatched")
    func genericPromptIsUnmatched() {
        #expect(KeyboardInteractiveAuthenticator.classify("Enter your PIN: ") == .unmatched)
        #expect(KeyboardInteractiveAuthenticator.classify("Response: ") == .unmatched)
    }

    @Test("One-time password classifies as a code, not the SSH password")
    func oneTimePasswordClassifiesAsTotp() {
        #expect(KeyboardInteractiveAuthenticator.classify("One-time password: ") == .totp)
    }
}
