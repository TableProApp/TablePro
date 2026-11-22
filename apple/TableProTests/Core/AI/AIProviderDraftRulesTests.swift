import Foundation
@testable import TablePro
import Testing

struct AIProviderDraftRulesTests {
    private func models(_ ids: [String]) -> [AIModelInfo] {
        ids.map { AIModelInfo(id: $0) }
    }

    // A router answers with hundreds of models sorted by name; the first of them is no choice.
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

    // With no list to pick from, requiring a model would leave Save dimmed with no way forward.
    @Test("Save does not wait for a model when no list is available")
    func saveDoesNotWaitWithoutAList() {
        #expect(!AIProviderDraftRules.needsModelChoice(model: "", fetched: []))
    }

    // Resolving an emptied Base URL to the default sent a gateway's key to the vendor's host with no click.
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

    // An empty endpoint saved under a placeholder showing the default failed every request until relaunch.
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

    // Open chat windows never refetch on their own, so Save fetches for the new server.
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

    private let optional = AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .medium, .high])
    private let mandatory = AIReasoningSupport(
        mode: .effortOnly, effortLevels: [.minimal, .low, .medium, .high, .xhigh], defaultEffort: .high, isMandatory: true
    )
    private let curated = CuratedModel(
        id: "gpt-5.5", displayName: "GPT-5.5", supportedEffortLevels: [.low, .medium, .high], defaultEffort: .medium
    )

    @Test("An effort the next model takes is kept")
    func effortTheModelTakesIsKept() {
        #expect(AIProviderDraftRules.effort(afterPicking: .high, reasoning: optional, curated: nil) == .high)
        #expect(AIProviderDraftRules.effort(afterPicking: .low, reasoning: mandatory, curated: nil) == .low)
    }

    @Test("A curated model starts on its own default, and replaces an effort it does not take")
    func curatedModelStartsOnItsDefault() {
        #expect(AIProviderDraftRules.effort(afterPicking: nil, reasoning: optional, curated: curated) == .medium)
        #expect(AIProviderDraftRules.effort(afterPicking: .xhigh, reasoning: optional, curated: curated) == .medium)
    }

    @Test("A listed or typed model that reasons optionally keeps Off, and drops an effort it does not take")
    func optionalReasoningKeepsOff() {
        #expect(AIProviderDraftRules.effort(afterPicking: nil, reasoning: optional, curated: nil) == nil)
        #expect(AIProviderDraftRules.effort(afterPicking: .xhigh, reasoning: optional, curated: nil) == nil)
    }

    // Meta runs its most expensive level when the effort is left out.
    @Test("A model that always reasons never ends up with no effort")
    func mandatoryReasoningAlwaysHasAnEffort() {
        #expect(AIProviderDraftRules.effort(afterPicking: nil, reasoning: mandatory, curated: nil) == .high)
        let narrow = AIReasoningSupport(
            mode: .effortOnly, effortLevels: [.low, .medium], defaultEffort: .low, isMandatory: true
        )
        #expect(AIProviderDraftRules.effort(afterPicking: .xhigh, reasoning: narrow, curated: nil) == .medium)
    }

    // A rule that cleared the effort on every keystroke turned Extra High into Off before the id was complete.
    @Test("Typing, preselecting or reopening keeps the effort, except that a model that always reasons gets one")
    func keptEffortChangesOnlyForMandatoryReasoning() {
        #expect(AIProviderDraftRules.effort(keeping: .xhigh, reasoning: optional) == .xhigh)
        #expect(AIProviderDraftRules.effort(keeping: nil, reasoning: optional) == nil)
        #expect(AIProviderDraftRules.effort(keeping: nil, reasoning: mandatory) == .high)
        #expect(AIProviderDraftRules.effort(keeping: .minimal, reasoning: mandatory) == .minimal)
    }

    @Test("A model that does not reason has no effort")
    func noReasoningNoEffort() {
        #expect(AIProviderDraftRules.effort(afterPicking: .high, reasoning: .unsupported, curated: curated) == nil)
    }

    // A key that failed to load shows as empty, so writing it back would erase the real one.
    @Test("Edit Connection writes the key only when the field was edited")
    func keyIsWrittenOnlyWhenEdited() {
        #expect(AIProviderConnectionRules.keyWrite(edited: false, typed: "") == .keep)
        #expect(AIProviderConnectionRules.keyWrite(edited: false, typed: "sk-loaded") == .keep)
        #expect(AIProviderConnectionRules.keyWrite(edited: true, typed: "sk-new") == .save("sk-new"))
        #expect(AIProviderConnectionRules.keyWrite(edited: true, typed: "") == .delete)
    }

    @Test("Edit Connection saves only once the key has loaded")
    func saveWaitsForTheKey() {
        #expect(!AIProviderConnectionRules.canSave(isKeyLoaded: false, authStyle: .optionalApiKey, apiKey: "sk"))
        #expect(!AIProviderConnectionRules.canSave(isKeyLoaded: true, authStyle: .apiKey, apiKey: "  "))
        #expect(AIProviderConnectionRules.canSave(isKeyLoaded: true, authStyle: .apiKey, apiKey: "sk"))
        #expect(AIProviderConnectionRules.canSave(isKeyLoaded: true, authStyle: .optionalApiKey, apiKey: ""))
    }

    @Test("Edit Connection moves only the name and Base URL onto the saved provider")
    func mergeKeepsLiveEdits() {
        let current = AIProviderConfig(name: "Gateway", type: .custom, model: "picked-on-the-page", endpoint: "https://a.example/v1")
        var draft = current
        draft.name = "  Renamed  "
        draft.endpoint = "https://b.example/v1"
        draft.model = "stale"
        let merged = AIProviderConnectionRules.merged(current, with: draft, allowsName: true, allowsEndpoint: true)
        #expect(merged.name == "Renamed")
        #expect(merged.endpoint == "https://b.example/v1")
        #expect(merged.model == "picked-on-the-page")

        let fixed = AIProviderConnectionRules.merged(current, with: draft, allowsName: false, allowsEndpoint: false)
        #expect(fixed == current)
    }

    @Test("A new Base URL or key counts as a new connection, an untouched key does not")
    func connectionChange() {
        let current = AIProviderConfig(type: .openAI, endpoint: "https://api.openai.com")
        var moved = current
        moved.endpoint = "https://proxy.example"
        #expect(AIProviderConnectionRules.connectionChanged(from: current, to: moved, keyWrite: .keep, savedKey: "sk"))
        #expect(!AIProviderConnectionRules.connectionChanged(from: current, to: current, keyWrite: .keep, savedKey: "sk"))
        #expect(!AIProviderConnectionRules.connectionChanged(from: current, to: current, keyWrite: .save("sk"), savedKey: "sk"))
        #expect(AIProviderConnectionRules.connectionChanged(from: current, to: current, keyWrite: .save("sk-2"), savedKey: "sk"))
        #expect(AIProviderConnectionRules.connectionChanged(from: current, to: current, keyWrite: .delete, savedKey: "sk"))
        #expect(!AIProviderConnectionRules.connectionChanged(from: current, to: current, keyWrite: .delete, savedKey: ""))
    }

    @Test("Output tokens below 1 or not a number mean the provider's default")
    func maxOutputTokensParsing() {
        #expect(AIProviderEditorModel.maxOutputTokens(from: "") == nil)
        #expect(AIProviderEditorModel.maxOutputTokens(from: "0") == nil)
        #expect(AIProviderEditorModel.maxOutputTokens(from: "-5") == nil)
        #expect(AIProviderEditorModel.maxOutputTokens(from: "many") == nil)
        #expect(AIProviderEditorModel.maxOutputTokens(from: " 4096 ") == 4096)
    }

    @Test("The model picker shows a listed model as itself and anything else as Other")
    func modelSelection() {
        let choices = AIModelChoices(curated: [curated], fetched: models(["gpt-5.5", "gpt-4.1"]))
        #expect(choices.fetched == ["gpt-4.1"])
        #expect(choices.selection(for: "gpt-5.5", choseOther: false) == .curated("gpt-5.5"))
        #expect(choices.selection(for: "gpt-4.1", choseOther: false) == .fetched("gpt-4.1"))
        #expect(choices.selection(for: "typed-by-hand", choseOther: false) == .custom)
        #expect(choices.selection(for: "gpt-4.1", choseOther: true) == .custom)
    }
}
