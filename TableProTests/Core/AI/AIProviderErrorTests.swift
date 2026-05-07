//
//  AIProviderErrorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AIProviderError.isRetryable")
struct AIProviderErrorTests {
    @Test("Transient transport failures are retryable")
    func transientErrorsAreRetryable() {
        #expect(AIProviderError.networkError("connection refused").isRetryable)
        #expect(AIProviderError.serverError(500, "internal error").isRetryable)
        #expect(AIProviderError.streamingFailed("connection dropped").isRetryable)
        #expect(AIProviderError.rateLimited.isRetryable)
    }

    @Test("Configuration errors are not retryable")
    func configurationErrorsAreNotRetryable() {
        #expect(!AIProviderError.modelNotFound("gemini-2.0-flash-lite").isRetryable)
        #expect(!AIProviderError.authenticationFailed("invalid key").isRetryable)
        #expect(!AIProviderError.invalidEndpoint("https://broken").isRetryable)
    }
}
