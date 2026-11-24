//
//  AIModelReferenceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

enum AIModelReferenceFixtures {
    static let json = """
    {
      "schema": 1,
      "generated": "2026-11-24T00:00:00Z",
      "providers": {
        "openai": {
          "default": "gpt-5.6-sol",
          "models": [
            {"id": "gpt-5.6-sol", "name": "GPT-5.6 Sol", "released": "2026-06-01", "output": 128000, "images": true,
             "apis": ["responses", "chat-completions"],
             "reasoning": {"efforts": ["low", "medium", "high", "xhigh", "max"], "toggle": true, "default": "medium"}},
            {"id": "gpt-6.1-sol", "name": "GPT-6.1 Sol", "released": "2026-10-01", "apis": ["responses"],
             "reasoning": {"efforts": ["low", "medium", "high", "xhigh", "max"], "default": "low"}},
            {"id": "gpt-5.5-pro", "name": "GPT-5.5 Pro", "apis": ["responses"],
             "reasoning": {"efforts": ["medium", "high", "xhigh"], "default": "high"}},
            {"id": "gpt-5-pro", "name": "GPT-5 Pro", "apis": ["responses"], "reasoning": {"efforts": ["high"]}},
            {"id": "gpt-5.5", "name": "GPT-5.5", "apis": ["responses", "chat-completions"],
             "reasoning": {"efforts": ["low", "medium", "high", "xhigh"], "toggle": true, "default": "medium"}},
            {"id": "gpt-4.1", "name": "GPT-4.1", "apis": ["responses", "chat-completions"]},
            {"id": "broken"}
          ]
        },
        "openai-codex": {
          "default": "gpt-5.6-sol",
          "client_version": "0.172.0",
          "models": [
            {"id": "gpt-5.6-sol", "name": "GPT-5.6 Sol", "reasoning": {"efforts": ["low", "medium", "high", "xhigh", "max"]}},
            {"id": "gpt-5.5", "name": "GPT-5.5", "reasoning": {"efforts": ["low", "medium", "high", "xhigh"]}}
          ]
        },
        "meta": {
          "default": "muse-spark-1.3",
          "models": [
            {"id": "muse-spark-1.3", "name": "Muse Spark 1.3", "apis": ["chat-completions"],
             "reasoning": {"efforts": ["minimal", "low", "medium", "high", "xhigh", "max"], "default": "high"}},
            {"id": "muse-wonder-1.0", "name": "Muse Wonder", "apis": ["chat-completions"],
             "reasoning": {"efforts": ["minimal", "low", "medium", "high", "xhigh", "max"], "default": "max"}},
            {"id": "muse-ember-1.0", "name": "Muse Ember", "apis": ["chat-completions"],
             "reasoning": {"efforts": ["minimal", "low", "medium", "high", "xhigh", "max"], "default": "max"}},
            {"id": "muse-spark-1.3-contributor", "name": "Muse Spark 1.3 Contributor", "apis": ["chat-completions"]}
          ]
        },
        "anthropic": {
          "default": "claude-opus-5-5",
          "models": [
            {"id": "claude-opus-5-5", "name": "Claude Opus 5.5", "output": 128000, "images": true, "apis": ["messages"],
             "reasoning": {"efforts": ["low", "medium", "high", "xhigh", "max"], "default": "high"}},
            {"id": "claude-haiku-4-5", "name": "Claude Haiku 4.5", "apis": ["messages"],
             "reasoning": {"budget_min": 1024}},
            {"id": "claude-opus-4-5", "name": "Claude Opus 4.5", "apis": ["messages"],
             "reasoning": {"efforts": ["low", "medium", "high"], "budget_min": 1024, "toggle": true}}
          ]
        }
      }
    }
    """

    static var file: AIModelReferenceFile {
        get throws { try AIModelReferenceFile.decode(Data(json.utf8)) }
    }
}

struct AIModelReferenceTests {
    private func info(_ key: String, _ id: String) throws -> AIModelInfo {
        let provider = try #require(try AIModelReferenceFixtures.file.providers[key])
        return try #require(provider.model(id)).info(providerKey: key)
    }

    @Test("A schema this build does not know is refused")
    func unknownSchemaIsRefused() {
        let newer = AIModelReferenceFixtures.json.replacingOccurrences(of: "\"schema\": 1", with: "\"schema\": 2")
        #expect(throws: (any Error).self) { try AIModelReferenceFile.decode(Data(newer.utf8)) }
    }

    @Test("A model entry that fails to decode is skipped, the rest are kept")
    func badEntriesAreSkipped() throws {
        let openAI = try #require(try AIModelReferenceFixtures.file.providers["openai"])
        #expect(openAI.models.count == 7)
        #expect(openAI.defaultModel == "gpt-5.6-sol")
    }

    // gpt-5.6-sol takes none..max: Minimal sent there was a 400.
    @Test("Catalog levels are the ones the model takes, and none becomes an explicit Off")
    func catalogLevels() throws {
        let sol = try #require(try info("openai", "gpt-5.6-sol").reasoning)
        #expect(sol.effortLevels == [.low, .medium, .high, .xhigh, .max])
        #expect(sol.canTurnOff)
        #expect(!sol.isMandatory)
        #expect(sol.defaultEffort == .medium)
    }

    // gpt-5.5-pro takes medium, high and xhigh; gpt-5-pro only high. Low sent to either was a 400.
    @Test("A model that always reasons offers no Off and starts on a level it takes")
    func mandatoryCatalogModels() throws {
        let pro = try #require(try info("openai", "gpt-5.5-pro").reasoning)
        #expect(pro.effortLevels == [.medium, .high, .xhigh])
        #expect(pro.isMandatory)
        #expect(pro.clampedEffort(.low) == .medium)
        #expect(AIProviderDraftRules.effort(afterPicking: .low, reasoning: pro) == .medium)

        let onlyHigh = try #require(try info("openai", "gpt-5-pro").reasoning)
        #expect(onlyHigh.effortLevels == [.high])
        #expect(onlyHigh.preferredEffort == .high)

        let gpt61 = try #require(try info("openai", "gpt-6.1-sol").reasoning)
        #expect(gpt61.isMandatory, "no none means it always reasons")
        #expect(gpt61.preferredEffort == .low)
    }

    @Test("A listed model with no reasoning entry does not reason")
    func nonReasoningModel() throws {
        #expect(try info("openai", "gpt-4.1").reasoning == .unsupported)
    }

    @Test("Claude catalog entries pick adaptive or manual thinking")
    func claudeThinkingModes() throws {
        #expect(try info("anthropic", "claude-opus-5-5").reasoning?.mode == .adaptive)
        #expect(try info("anthropic", "claude-opus-5-5").reasoning?.isMandatory == true)
        #expect(try info("anthropic", "claude-haiku-4-5").reasoning?.mode == .budgeted)
        #expect(try info("anthropic", "claude-haiku-4-5").reasoning?.isMandatory == false)
    }

    // Opus 4.5 takes effort but only manual thinking; adaptive thinking there is refused.
    @Test("A Claude entry with a thinking budget uses manual thinking even when it lists effort levels")
    func budgetWinsOverEffortForClaude() throws {
        let opus45 = try #require(try info("anthropic", "claude-opus-4-5").reasoning)
        #expect(opus45.mode == .budgeted)
        #expect(!opus45.canTurnOff, "omitting thinking already turns manual thinking off")
        #expect(!opus45.isMandatory)
    }

    // Meta may train on what a contributor model is sent; a failed list must not offer one either.
    @Test("A failed Meta list falls back to the catalog without its contributor models")
    func offlineMetaListKeepsContributorsOut() async throws {
        let reference = AIModelReference(file: try AIModelReferenceFixtures.file)
        let result = await AIModelCatalog.list(
            for: AIProviderConfig(preset: .meta),
            using: FailingModelListTransport(),
            reference: reference
        )
        #expect(result.error != nil)
        #expect(result.models.allSatisfy { $0.isOffline && !$0.id.contains("-contributor") })
        #expect(result.models.first?.id == "muse-spark-1.3")
    }

    // An unreachable ChatGPT backend used to save the provider with no model at all.
    @Test("A failed ChatGPT list offers the catalog's models with its default first")
    func offlineCodexListHasADefault() async throws {
        let reference = AIModelReference(file: try AIModelReferenceFixtures.file)
        let result = await AIModelCatalog.list(
            for: AIProviderConfig(type: .chatgptCodex),
            using: FailingModelListTransport(),
            reference: reference
        )
        #expect(result.models.map(\.id) == ["gpt-5.6-sol", "gpt-5.5"])
        #expect(AIProviderDraftRules.initialModel(fetched: result.models) == "gpt-5.6-sol")
    }

    @Test("A dated snapshot and a fine-tune read their base model's entry")
    func snapshotsReadTheirBase() throws {
        let reference = AIModelReference(file: try AIModelReferenceFixtures.file)
        let source = AIModelSource(key: "openai", api: "responses", hidesUnknown: true, liveOrdered: false)
        #expect(reference.info(source: source, modelID: "gpt-5.6-sol-2026-06-01")?.displayName == "GPT-5.6 Sol")
        #expect(reference.info(source: source, modelID: "ft:gpt-5.6-sol:acme::x1")?.reasoning?.canTurnOff == true)
        #expect(reference.info(source: source, modelID: "gpt-9")?.reasoning == nil)
    }

    // The HTTP cache can be overwritten by an answer that is then refused, so the copy kept is a file of its own.
    @Test("A newer catalog fetched is kept for the next launch, an older one is not")
    func fetchedCatalogIsKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = folder.appendingPathComponent("models-v1.json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogHostProtocol.self]
        let session = URLSession(configuration: config)

        CatalogHostProtocol.body = AIModelReferenceFixtures.json
            .replacingOccurrences(of: "2026-11-24T00:00:00Z", with: "2999-01-01T00:00:00Z")
        let reference = AIModelReference(file: try AIModelReferenceFixtures.file, session: session, savedURL: saved)
        await reference.refresh()
        let nextLaunch = AIModelReference(bundle: .main, session: session, savedURL: saved)
        #expect(nextLaunch.current?.providers["openai"]?.defaultModel == "gpt-5.6-sol")
        #expect(FileManager.default.fileExists(atPath: saved.path))

        try FileManager.default.removeItem(at: saved)
        CatalogHostProtocol.body = AIModelReferenceFixtures.json
            .replacingOccurrences(of: "2026-11-24T00:00:00Z", with: "2000-01-01T00:00:00Z")
        await AIModelReference(file: try AIModelReferenceFixtures.file, session: session, savedURL: saved).refresh()
        #expect(!FileManager.default.fileExists(atPath: saved.path))
    }

    @Test("The newer of the bundled and cached copies wins")
    func newerCopyWins() throws {
        let bundled = try AIModelReferenceFixtures.file
        let later = AIModelReferenceFixtures.json.replacingOccurrences(of: "2026-11-24T00:00:00Z", with: "2026-12-01T00:00:00Z")
        let cached = try AIModelReferenceFile.decode(Data(later.utf8))
        #expect(AIModelReference.newer(bundled, cached) == cached)
        #expect(AIModelReference.newer(cached, bundled) == cached)
        #expect(AIModelReference.newer(nil, bundled) == bundled)
    }

    @Test("Each provider type reads its own catalog entry, and only vendor hosts hide unknown ids")
    func sourcesPerProvider() {
        let openAI = AIModelSource(config: AIProviderConfig(type: .openAI))
        #expect(openAI.key == "openai")
        #expect(openAI.hidesUnknown)
        let gateway = AIModelSource(config: AIProviderConfig(type: .openAI, endpoint: "https://gateway.example.com"))
        #expect(!gateway.hidesUnknown)
        #expect(AIModelSource(config: AIProviderConfig(type: .claude)).key == "anthropic")
        #expect(AIModelSource(config: AIProviderConfig(type: .chatgptCodex)).key == "openai-codex")
        #expect(AIModelSource(config: AIProviderConfig(preset: .meta)).key == "meta")
        #expect(AIModelSource(config: AIProviderConfig(preset: .meta)).hidesUnknown)
        #expect(AIModelSource(config: AIProviderConfig(type: .openRouter)).key == nil)
    }

    @Test("The bundled catalog decodes and names a listed default for every provider")
    func bundledCatalogIsValid() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url = url.deletingLastPathComponent()
        }
        let file = try AIModelReferenceFile.decode(Data(contentsOf: url.appendingPathComponent("core/crates/ai/ai-models.json")))
        for (key, provider) in file.providers {
            let defaultModel = try #require(provider.defaultModel, "\(key) has no default")
            #expect(provider.models.contains { $0.id == defaultModel }, "\(key) default \(defaultModel) is not listed")
        }
        #expect(file.providers["openai-codex"]?.clientVersion?.isEmpty == false)
    }
}

private final class FailingModelListTransport: ChatTransport {
    func streamChat(turns: [ChatTurnWire], options: ChatTransportOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] {
        throw AIProviderError.networkError("unreachable")
    }

    func testConnection() async throws -> Bool { false }
}

private final class CatalogHostProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
