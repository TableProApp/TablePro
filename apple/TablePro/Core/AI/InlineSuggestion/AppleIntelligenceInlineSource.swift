//
//  AppleIntelligenceInlineSource.swift
//  TablePro
//

import Foundation

@MainActor
final class AppleIntelligenceInlineSource: InlineSuggestionSource {
    typealias SettingsProvider = @MainActor () -> AISettings

    static let replyTokenLimit = 256

    internal weak var schemaProvider: SQLSchemaProvider?
    internal var connectionId: UUID?

    private let accessGate: AIConnectionAccessGate
    private let currentSettings: SettingsProvider
    private let model: any OnDeviceLanguageModel

    init(
        schemaProvider: SQLSchemaProvider?,
        connectionId: UUID?,
        accessGate: AIConnectionAccessGate,
        currentSettings: @escaping SettingsProvider = { AppSettingsManager.shared.ai },
        model: any OnDeviceLanguageModel = SystemOnDeviceLanguageModel()
    ) {
        self.schemaProvider = schemaProvider
        self.connectionId = connectionId
        self.accessGate = accessGate
        self.currentSettings = currentSettings
        self.model = model
    }

    var isAvailable: Bool {
        let settings = currentSettings()
        guard settings.enabled, settings.useAppleIntelligence, model.availability.isAvailable else { return false }
        return accessGate.allowsUnpromptedAccess(to: connectionId)
    }

    func requestSuggestion(context: SuggestionContext) async throws -> InlineSuggestion? {
        guard isAvailable else { return nil }
        let settings = currentSettings()
        let prompt = AIPromptTemplates.inlineSuggest(textBefore: context.textBefore, fullQuery: context.fullText)

        var candidates: [OnDeviceRequest] = []
        if settings.includeSchema, let provider = schemaProvider,
           let schema = await provider.buildSchemaContextForAI(
               settings: settings,
               editorText: context.fullText,
               cursorOffset: context.cursorOffset
           ), !schema.isEmpty {
            candidates.append(OnDeviceRequest(
                instructions: AIPromptTemplates.inlineSuggestSystemPrompt(schemaContext: schema),
                prompt: prompt
            ))
        }
        candidates.append(OnDeviceRequest(instructions: AIPromptTemplates.inlineSuggestSystemPrompt(), prompt: prompt))

        guard case .fits(let index, let allowance) = await model.fit(candidates, reservingForReply: Self.replyTokenLimit)
        else { return nil }
        guard !Task.isCancelled, isAvailable else { return nil }

        var accumulated = ""
        let stream = model.streamResponse(
            to: candidates[index],
            maximumResponseTokens: min(allowance, Self.replyTokenLimit)
        )
        for try await delta in stream {
            accumulated += delta
        }

        let cleaned = InlineSuggestionText.clean(accumulated)
        guard !cleaned.isEmpty else { return nil }
        return InlineSuggestion(text: cleaned, replacementText: cleaned)
    }
}
