//
//  KeyboardInteractiveContextTests.swift
//  TableProTests
//
//  Verifies the lazy TOTP fetch + retry counter behavior of KeyboardInteractiveContext.
//  The C callback consults this context for every prompt the server sends; the upfront
//  fetch (single NSAlert before kbd-int starts) was the source of the "code expired
//  during handshake" race and prevented OpenSSH-style retry within a single session.
//

import Foundation
@testable import TablePro
import Testing

@Suite("KeyboardInteractiveContext")
struct KeyboardInteractiveContextTests {
    final class StubTOTPProvider: TOTPProvider, @unchecked Sendable {
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

    @Test("nextTotpCode returns empty when no provider is configured")
    func noProviderReturnsEmpty() {
        let context = KeyboardInteractiveContext(password: "p", totpProvider: nil)
        #expect(context.nextTotpCode() == "")
        #expect(context.totpAttemptCount == 0)
    }

    @Test("Each call asks the provider for a fresh code with an incrementing attempt index")
    func incrementsAttemptCounter() {
        let provider = StubTOTPProvider(codes: ["111111", "222222", "333333"])
        let context = KeyboardInteractiveContext(password: "p", totpProvider: provider)

        #expect(context.nextTotpCode() == "111111")
        #expect(context.nextTotpCode() == "222222")
        #expect(context.nextTotpCode() == "333333")

        #expect(provider.attemptsSeen == [0, 1, 2])
        #expect(context.totpAttemptCount == 3)
    }

    @Test("Provider error is captured and code falls back to empty string")
    func providerErrorIsStored() {
        let provider = StubTOTPProvider(codes: ["111111"], errorOnAttempt: 0)
        let context = KeyboardInteractiveContext(password: "p", totpProvider: provider)

        let result = context.nextTotpCode()
        #expect(result == "")
        #expect(context.lastTotpError != nil)
        #expect(context.totpAttemptCount == 1)
    }

    @Test("Counter still increments after a provider error so retry callbacks see attempt > 0")
    func counterIncrementsThroughErrors() {
        let provider = StubTOTPProvider(codes: ["111111", "222222"], errorOnAttempt: 0)
        let context = KeyboardInteractiveContext(password: "p", totpProvider: provider)

        _ = context.nextTotpCode() // first call errors
        #expect(context.totpAttemptCount == 1)

        provider.errorOnAttempt = nil
        let second = context.nextTotpCode()
        #expect(second == "222222")
        #expect(provider.attemptsSeen == [0, 1])
    }
}

@Suite("PromptTOTPProvider attempt-aware messaging")
struct PromptTOTPProviderShapeTests {
    @Test("Conformance covers the attempt-bearing protocol method")
    func providerConformsToProtocol() {
        let provider: any TOTPProvider = PromptTOTPProvider()
        // Just verify the protocol witness compiles. The alert UI path is not exercised
        // here because runModal would block the test runner.
        _ = provider
    }
}
