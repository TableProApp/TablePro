//
//  AIProviderDraftRulesTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AIProviderDraftRulesTests {
    private func models(_ ids: [String]) -> [AIModelInfo] {
        ids.map { AIModelInfo(id: $0) }
    }

    /// The reported defect: a router answers with several hundred models sorted by name, and the
    /// sheet put a new provider on the first of them without being asked.
    @Test("A fetched list with several models picks none of them")
    func severalFetchedModelsPickNone() {
        let fetched = models(["alibaba/qwen-max", "anthropic/claude-sonnet-5", "openai/gpt-5.5"])
        #expect(AIProviderDraftRules.initialModel(curated: [], fetched: fetched) == nil)
    }

    @Test("A server offering one model starts on it")
    func singleFetchedModelIsPicked() {
        #expect(AIProviderDraftRules.initialModel(curated: [], fetched: models(["qwen3:8b"])) == "qwen3:8b")
    }

    @Test("The first curated model wins over anything fetched")
    func curatedWins() {
        let curated = [CuratedModel(id: "claude-opus-5", displayName: "Claude Opus 5")]
        let fetched = models(["claude-3-haiku", "claude-opus-5"])
        #expect(AIProviderDraftRules.initialModel(curated: curated, fetched: fetched) == "claude-opus-5")
        #expect(AIProviderDraftRules.initialModel(curated: curated, fetched: []) == "claude-opus-5")
    }

    @Test("The model a provider marks as its default is picked from a longer list")
    func providerDefaultIsPicked() {
        let fetched = [
            AIModelInfo(id: "gpt-a"),
            AIModelInfo(id: "gpt-b", isProviderDefault: true),
            AIModelInfo(id: "gpt-c")
        ]
        #expect(AIProviderDraftRules.initialModel(curated: [], fetched: fetched) == "gpt-b")
    }

    @Test("With nothing curated and nothing fetched there is no model to pick")
    func nothingToPick() {
        #expect(AIProviderDraftRules.initialModel(curated: [], fetched: []) == nil)
    }

    @Test("Save waits for a model while there is a list to pick from")
    func saveWaitsForAModelWhenThereIsAList() {
        let fetched = models(["alibaba/qwen-max", "openai/gpt-5.5"])
        #expect(AIProviderDraftRules.needsModelChoice(model: "", fetched: fetched))
        #expect(AIProviderDraftRules.needsModelChoice(model: "  ", fetched: fetched))
        #expect(!AIProviderDraftRules.needsModelChoice(model: "openai/gpt-5.5", fetched: fetched))
        #expect(!AIProviderDraftRules.needsModelChoice(model: "typed-by-hand", fetched: fetched))
    }

    /// A provider whose list is blocked, failed, or waits on a sign-in has nothing to pick from, and
    /// requiring a model there would leave Save dimmed with no way forward.
    @Test("Save does not wait for a model when no list is available")
    func saveDoesNotWaitWithoutAList() {
        #expect(!AIProviderDraftRules.needsModelChoice(model: "", fetched: []))
    }

    /// The fetch runs on a timer while the field is edited. Resolving an emptied Base URL to the
    /// default sent the key typed for a gateway to the vendor's own host with no click.
    @Test("The automatic model fetch waits while the Base URL field is empty")
    func emptiedBaseURLBlocksTheFetch() {
        AIProviderRegistration.registerAll()
        let descriptor = AIProviderRegistry.shared.descriptor(for: AIProviderType.claude.rawValue)
        var draft = AIProviderConfig(type: .claude, endpoint: "https://llm-gateway.example/anthropic")
        #expect(AIProviderDraftRules.modelListBlocker(descriptor: descriptor, draft: draft, apiKey: "sk-gateway") == nil)

        draft.endpoint = ""
        #expect(
            AIProviderDraftRules.modelListBlocker(descriptor: descriptor, draft: draft, apiKey: "sk-gateway")
                == .missingEndpoint
        )
    }

    /// The reported defect: clearing the field saved an empty endpoint under a placeholder that
    /// showed the default, and every request failed until the next launch.
    @Test("A cleared Base URL saves as the default the placeholder shows")
    func clearedEndpointSavesAsTheDefault() {
        let fallback = AIProviderPreset.requesty.endpoint
        #expect(AIProviderDraftRules.endpoint("", defaultEndpoint: fallback) == fallback)
        #expect(AIProviderDraftRules.endpoint("  \n", defaultEndpoint: fallback) == fallback)
    }

    @Test("A typed Base URL is kept, without its surrounding whitespace")
    func typedEndpointIsKept() {
        #expect(
            AIProviderDraftRules.endpoint(" https://router.eu.requesty.ai ", defaultEndpoint: "https://router.requesty.ai")
                == "https://router.eu.requesty.ai"
        )
    }

    @Test("A custom provider with no default keeps an empty Base URL empty")
    func noDefaultStaysEmpty() {
        #expect(AIProviderDraftRules.endpoint("", defaultEndpoint: "").isEmpty)
    }

    @Test("Save stores a list that loaded for the draft's key and Base URL")
    func currentListIsStored() {
        #expect(
            AIProviderDraftRules.catalogUpdate(listIsCurrent: true, listIsEmpty: false, connectionChanged: true)
                == .store
        )
    }

    @Test("Save drops the old list when the server answered with no models")
    func currentEmptyListIsRemoved() {
        #expect(
            AIProviderDraftRules.catalogUpdate(listIsCurrent: true, listIsEmpty: true, connectionChanged: false)
                == .remove
        )
    }

    /// The list on record was fetched with the old key or Base URL, so it describes a server the
    /// saved provider no longer points at. Open chat windows never refetch on their own, so Save
    /// fetches it again rather than leaving them with no list.
    @Test("Save fetches the list again when the key or Base URL changed and the new one did not load")
    func staleListIsFetchedAgainWhenTheConnectionChanged() {
        #expect(
            AIProviderDraftRules.catalogUpdate(listIsCurrent: false, listIsEmpty: false, connectionChanged: true)
                == .refetch
        )
    }

    @Test("Save keeps the list on record when nothing about the connection changed")
    func untouchedConnectionKeepsItsList() {
        #expect(
            AIProviderDraftRules.catalogUpdate(listIsCurrent: false, listIsEmpty: true, connectionChanged: false)
                == .keep
        )
    }
}
