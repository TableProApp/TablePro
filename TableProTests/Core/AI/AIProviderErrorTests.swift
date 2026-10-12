//
//  AIProviderErrorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

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
        #expect(!AIProviderError.notFound(url: nil, detail: "").isRetryable)
        #expect(!AIProviderError.authenticationFailed("invalid key").isRetryable)
        #expect(!AIProviderError.invalidEndpoint("https://broken").isRetryable)
    }

    @Test("A 404 names the URL it called rather than blaming the model")
    func notFoundNamesTheRequestURL() throws {
        let url = try #require(URL(string: "https://api.z.ai/api/paas/v4/v1/chat/completions"))
        let error = AIProviderError.mapHTTPError(statusCode: 404, body: "", requestURL: url)
        let description = try #require(error.errorDescription)
        #expect(description.contains("https://api.z.ai/api/paas/v4/v1/chat/completions"))
        #expect(!description.contains("Model not found"))
    }

    @Test("A 404 keeps the server's own message")
    func notFoundKeepsServerDetail() throws {
        let body = #"{"error":{"message":"no such model"}}"#
        let error = AIProviderError.mapHTTPError(statusCode: 404, body: body)
        let description = try #require(error.errorDescription)
        #expect(description.contains("no such model"))
    }
}
