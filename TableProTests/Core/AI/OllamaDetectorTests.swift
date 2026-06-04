//
//  OllamaDetectorTests.swift
//  TableProTests
//

import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
private func makeOllamaDetectorSettings(
    enabled: Bool = true,
    providers: [AIProviderConfig] = []
) -> AISettings {
    AISettings(
        enabled: enabled,
        providers: providers
    )
}

@Suite("OllamaDetector")
@MainActor
struct OllamaDetectorTests {
    @Test("Skips detection when AI is disabled")
    func skipsWhenAIDisabled() async {
        var fetchCount = 0
        var registered: [AIProviderConfig] = []

        await OllamaDetector.detectAndRegister(
            settingsProvider: {
                makeOllamaDetectorSettings(enabled: false)
            },
            registerProvider: { registered.append($0) },
            modelFetcher: {
                fetchCount += 1
                return ["llama3"]
            }
        )

        #expect(fetchCount == 0)
        #expect(registered.isEmpty)
    }

    @Test("Skips detection when Ollama provider already exists")
    func skipsWhenOllamaProviderExists() async {
        let existing = AIProviderConfig(type: .ollama, model: "llama3")
        var fetchCount = 0
        var registered: [AIProviderConfig] = []

        await OllamaDetector.detectAndRegister(
            settingsProvider: {
                makeOllamaDetectorSettings(providers: [existing])
            },
            registerProvider: { registered.append($0) },
            modelFetcher: {
                fetchCount += 1
                return ["llama3"]
            }
        )

        #expect(fetchCount == 0)
        #expect(registered.isEmpty)
    }

    @Test("Skips registration when no models are found")
    func skipsWhenNoModelsFound() async {
        var registered: [AIProviderConfig] = []

        await OllamaDetector.detectAndRegister(
            settingsProvider: {
                makeOllamaDetectorSettings()
            },
            registerProvider: { registered.append($0) },
            modelFetcher: {
                []
            }
        )

        #expect(registered.isEmpty)
    }

    @Test("Registers local Ollama provider from injected model fetcher")
    func registersProviderFromInjectedModelFetcher() async throws {
        var registered: [AIProviderConfig] = []

        await OllamaDetector.detectAndRegister(
            settingsProvider: {
                makeOllamaDetectorSettings()
            },
            registerProvider: { registered.append($0) },
            modelFetcher: {
                ["llama3", "mistral"]
            }
        )

        let provider = try #require(registered.first)
        #expect(registered.count == 1)
        #expect(provider.name == "Ollama (Local)")
        #expect(provider.type == .ollama)
        #expect(provider.model == "llama3")
        #expect(provider.endpoint == AIProviderType.ollama.defaultEndpoint)
    }
}
