//
//  StringAIEndpointTests.swift
//  TableProTests
//
//  Tests for AI endpoint path construction, including tolerance for base URLs
//  that already include the /v1 version segment.
//

import Foundation
import Testing

@testable import TablePro

@Suite("AI Endpoint Path")
struct StringAIEndpointTests {
    @Test("base without version gets /v1 appended")
    func appendsVersionWhenMissing() {
        #expect("https://api.openai.com".openAIPath("chat/completions") == "https://api.openai.com/v1/chat/completions")
        #expect("https://openrouter.ai/api".openAIPath("chat/completions") == "https://openrouter.ai/api/v1/chat/completions")
    }

    @Test("base ending in /v1 is not doubled")
    func doesNotDoubleVersion() {
        #expect("https://opencode.ai/zen/v1".openAIPath("chat/completions") == "https://opencode.ai/zen/v1/chat/completions")
        #expect("https://opencode.ai/zen/v1".openAIPath("models") == "https://opencode.ai/zen/v1/models")
    }

    @Test("base without /v1 resolves the OpenCode Zen path")
    func openCodeZenWithoutVersion() {
        #expect("https://opencode.ai/zen".openAIPath("chat/completions") == "https://opencode.ai/zen/v1/chat/completions")
        #expect("https://opencode.ai/zen".openAIPath("models") == "https://opencode.ai/zen/v1/models")
    }

    @Test("trailing slash is normalized before building the path")
    func normalizesTrailingSlash() {
        #expect("https://opencode.ai/zen/v1/".openAIPath("models") == "https://opencode.ai/zen/v1/models")
        #expect("https://api.openai.com/".openAIPath("models") == "https://api.openai.com/v1/models")
    }
}
