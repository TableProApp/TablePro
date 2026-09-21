//
//  AIEndpointTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("AI Endpoint Resolution")
struct AIEndpointTests {
    private func chatURL(_ configured: String, _ style: AIEndpointStyle, model: String = "m") -> String? {
        AIEndpoint(configured, style: style)?.chatURL(model: model, style: style)?.absoluteString
    }

    private func modelsURL(_ configured: String, _ style: AIEndpointStyle) -> String? {
        AIEndpoint(configured, style: style)?.url(appending: style.modelsResource)?.absoluteString
    }

    @Test("A base with no version segment gains the style's version")
    func insertsVersionWhenAbsent() {
        #expect(chatURL("https://api.openai.com", .chatCompletions) == "https://api.openai.com/v1/chat/completions")
        #expect(modelsURL("https://api.openai.com", .chatCompletions) == "https://api.openai.com/v1/models")
        #expect(chatURL("https://openrouter.ai/api", .chatCompletions) == "https://openrouter.ai/api/v1/chat/completions")
        #expect(chatURL("https://opencode.ai/zen", .chatCompletions) == "https://opencode.ai/zen/v1/chat/completions")
        #expect(chatURL("http://localhost:8080", .chatCompletions) == "http://localhost:8080/v1/chat/completions")
    }

    @Test("A base already ending in /v1 is not doubled")
    func doesNotDoubleTheVersion() {
        #expect(chatURL("https://opencode.ai/zen/v1", .chatCompletions) == "https://opencode.ai/zen/v1/chat/completions")
        #expect(modelsURL("https://opencode.ai/zen/v1", .chatCompletions) == "https://opencode.ai/zen/v1/models")
        #expect(chatURL("https://api.anthropic.com/v1", .messages) == "https://api.anthropic.com/v1/messages")
        #expect(chatURL("https://api.openai.com/v1", .responses) == "https://api.openai.com/v1/responses")
    }

    /// The reported defect: Z.ai serves its OpenAI-compatible API under /v4.
    @Test("A version segment other than v1 is left alone")
    func honoursANonV1Version() {
        #expect(chatURL("https://api.z.ai/api/paas/v4", .chatCompletions)
            == "https://api.z.ai/api/paas/v4/chat/completions")
        #expect(modelsURL("https://api.z.ai/api/paas/v4", .chatCompletions)
            == "https://api.z.ai/api/paas/v4/models")
        #expect(chatURL("https://host/v2alpha1", .chatCompletions) == "https://host/v2alpha1/chat/completions")
        #expect(chatURL("https://host/v1.5", .chatCompletions) == "https://host/v1.5/chat/completions")
    }

    @Test("A path segment that only starts with v is not a version")
    func doesNotTreatWordsAsVersions() {
        #expect(chatURL("https://host/vertex", .chatCompletions) == "https://host/vertex/v1/chat/completions")
        #expect(chatURL("https://host/v", .chatCompletions) == "https://host/v/v1/chat/completions")
    }

    @Test("A full resource URL is used as it stands, and its sibling resolves beside it")
    func acceptsAFullResourceURL() {
        #expect(chatURL("https://api.z.ai/api/paas/v4/chat/completions", .chatCompletions)
            == "https://api.z.ai/api/paas/v4/chat/completions")
        #expect(modelsURL("https://api.z.ai/api/paas/v4/chat/completions", .chatCompletions)
            == "https://api.z.ai/api/paas/v4/models")
        #expect(chatURL("https://proxy.internal/openai/chat/completions", .chatCompletions)
            == "https://proxy.internal/openai/chat/completions")
        #expect(chatURL("https://api.anthropic.com/v1/messages", .messages)
            == "https://api.anthropic.com/v1/messages")
        #expect(chatURL("https://api.openai.com/v1/responses", .responses)
            == "https://api.openai.com/v1/responses")
        #expect(modelsURL("https://api.openai.com/v1/models", .responses) == "https://api.openai.com/v1/models")
    }

    @Test("Trailing slashes are stripped however many there are")
    func stripsTrailingSlashes() {
        #expect(modelsURL("https://api.openai.com/", .chatCompletions) == "https://api.openai.com/v1/models")
        #expect(modelsURL("https://opencode.ai/zen/v1/", .chatCompletions) == "https://opencode.ai/zen/v1/models")
        #expect(modelsURL("https://opencode.ai/zen/v1///", .chatCompletions) == "https://opencode.ai/zen/v1/models")
    }

    @Test("A query string on the base survives, after the appended path")
    func preservesTheBaseQuery() {
        #expect(chatURL("https://x.openai.azure.com/openai/deployments/dep?api-version=2026-02-01", .chatCompletions)
            == "https://x.openai.azure.com/openai/deployments/dep/v1/chat/completions?api-version=2026-02-01")
    }

    /// `URLComponents.path` decodes `%2F`, which would turn one path segment into two and address
    /// a different route on the gateway.
    @Test("An escaped path separator survives resolution")
    func preservesAnEscapedSeparator() {
        #expect(chatURL("https://gateway.example/tenant%2Fapi/v4", .chatCompletions)
            == "https://gateway.example/tenant%2Fapi/v4/chat/completions")
        #expect(modelsURL("https://gateway.example/tenant%2Fapi", .chatCompletions)
            == "https://gateway.example/tenant%2Fapi/v1/models")
    }

    @Test("Surrounding whitespace is ignored")
    func trimsWhitespace() {
        #expect(chatURL("  https://api.openai.com/v1  ", .chatCompletions)
            == "https://api.openai.com/v1/chat/completions")
    }

    @Test("Gemini keeps its own version segment and query")
    func resolvesGemini() {
        #expect(chatURL("https://generativelanguage.googleapis.com", .gemini, model: "gemini-3-pro")
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro:streamGenerateContent?alt=sse")
        #expect(modelsURL("https://generativelanguage.googleapis.com", .gemini)
            == "https://generativelanguage.googleapis.com/v1beta/models")
        #expect(modelsURL("https://generativelanguage.googleapis.com/v1beta", .gemini)
            == "https://generativelanguage.googleapis.com/v1beta/models")
        #expect(modelsURL("https://gateway.internal/gemini/v1beta/models", .gemini)
            == "https://gateway.internal/gemini/v1beta/models")
    }

    @Test("A Gemini model name is encoded once, not twice")
    func encodesTheGeminiModelOnce() {
        #expect(chatURL("https://generativelanguage.googleapis.com/v1beta", .gemini, model: "a b")
            == "https://generativelanguage.googleapis.com/v1beta/models/a%20b:streamGenerateContent?alt=sse")
    }

    @Test("Ollama keeps its native paths and gains no version")
    func resolvesOllama() {
        #expect(chatURL("http://localhost:11434", .ollama) == "http://localhost:11434/api/chat")
        #expect(modelsURL("http://localhost:11434", .ollama) == "http://localhost:11434/api/tags")
        #expect(chatURL("http://localhost:11434/", .ollama) == "http://localhost:11434/api/chat")
        #expect(chatURL("http://localhost:11434/api/chat", .ollama) == "http://localhost:11434/api/chat")
    }

    @Test("An endpoint that is not an http URL is refused")
    func refusesUnusableEndpoints() {
        #expect(AIEndpoint("api.z.ai/api/paas/v4", style: .chatCompletions) == nil)
        #expect(AIEndpoint("", style: .chatCompletions) == nil)
        #expect(AIEndpoint("   ", style: .chatCompletions) == nil)
        #expect(AIEndpoint("ftp://api.openai.com/v1", style: .chatCompletions) == nil)
        #expect(AIEndpoint("file:///tmp/models", style: .chatCompletions) == nil)
        #expect(AIEndpoint("https://", style: .chatCompletions) == nil)
    }

    /// A key belongs in the Keychain, not in a URL the settings list draws back to the user.
    @Test("An endpoint carrying credentials is refused")
    func refusesCredentialsInTheEndpoint() {
        #expect(AIEndpoint("https://user:secret@host/v1", style: .chatCompletions) == nil)
        #expect(AIEndpoint("https://user@host/v1", style: .chatCompletions) == nil)
    }

    /// An Authorization header on a cleartext request to another machine is readable in transit.
    /// Reaching a server on this machine over http is an ordinary local setup.
    @Test("Plaintext to a remote host is flagged, and to this machine is not")
    func flagsPlaintextToARemoteHost() {
        for base in ["http://gateway.internal.example.com/v1", "http://192.168.1.10:8000/v1", "http://0.0.0.0:8080/v1"] {
            #expect(AIEndpoint(base, style: .chatCompletions)?.isPlaintextToRemoteHost == true, "\(base)")
        }
        for base in [
            "http://localhost:11434",
            "http://127.0.0.1:1234/v1",
            "http://127.0.0.2:8080/v1",
            "https://gateway.internal.example.com/v1",
            "https://api.openai.com/v1",
        ] {
            #expect(AIEndpoint(base, style: .chatCompletions)?.isPlaintextToRemoteHost == false, "\(base)")
        }
    }

    @Test("Every style resolves the provider's own default endpoint")
    func resolvesEveryDefaultEndpoint() {
        for type in AIProviderType.allCases where !type.defaultEndpoint.isEmpty {
            let style = type.endpointStyle
            #expect(
                AIEndpoint(type.defaultEndpoint, style: style)?.chatURL(model: "m", style: style) != nil,
                "\(type.rawValue) default endpoint does not resolve"
            )
        }
    }
}
