//
//  AIChatInlineSource.swift
//  TablePro
//

import Foundation
import os

@MainActor
final class AIChatInlineSource: InlineSuggestionSource {
    typealias SettingsProvider = @MainActor () -> AISettings
    typealias ProviderResolver = @MainActor (AISettings) -> AIProviderFactory.ResolvedProvider?

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AIChatInlineSource")

    /// Settable, because the provider is per database scope and the source outlives a scope
    /// change: latching the instance handed the model the first scope's tables for the rest of
    /// the tab's life, and left the prompt schema-less once that provider was released.
    internal weak var schemaProvider: SQLSchemaProvider?
    internal var connectionId: UUID?

    /// One id for this source's whole life.
    ///
    /// A stateful transport keeps conversation state per session id, so minting one per request
    /// would leave a Copilot conversation behind for every inline suggestion, locally and on the
    /// server. Inline suggestions are one long-running conversation, not a new one each keystroke.
    private let sessionId = UUID()
    private let accessGate: AIConnectionAccessGate
    private let currentSettings: SettingsProvider
    private let resolveProvider: ProviderResolver

    init(
        schemaProvider: SQLSchemaProvider?,
        connectionId: UUID?,
        accessGate: AIConnectionAccessGate,
        currentSettings: @escaping SettingsProvider = { AppSettingsManager.shared.ai },
        resolveProvider: @escaping ProviderResolver = { AIProviderFactory.resolve(settings: $0) }
    ) {
        self.schemaProvider = schemaProvider
        self.connectionId = connectionId
        self.accessGate = accessGate
        self.currentSettings = currentSettings
        self.resolveProvider = resolveProvider
    }

    var isAvailable: Bool {
        let settings = currentSettings()
        guard settings.enabled, settings.hasActiveProvider else { return false }
        return accessGate.allowsUnpromptedAccess(to: connectionId)
    }

    func requestSuggestion(context: SuggestionContext) async throws -> InlineSuggestion? {
        guard accessGate.allowsUnpromptedAccess(to: connectionId) else { return nil }

        let settings = currentSettings()
        guard let resolved = resolveProvider(settings) else {
            return nil
        }

        let userMessage = AIPromptTemplates.inlineSuggest(textBefore: context.textBefore, fullQuery: context.fullText)
        let turns = [
            ChatTurnWire(role: .user, blocks: [.text(userMessage)])
        ]

        let systemPrompt = await buildSystemPrompt(settings: settings, context: context)

        guard accessGate.allowsUnpromptedAccess(to: connectionId) else { return nil }

        var accumulated = ""
        let stream = resolved.provider.streamChat(
            turns: turns,
            options: ChatTransportOptions(
                model: resolved.model,
                systemPrompt: systemPrompt,
                sessionId: sessionId
            )
        )

        for try await event in stream {
            if case .textDelta(let token) = event {
                accumulated += token
            }
        }

        let cleaned = InlineSuggestionText.clean(accumulated)
        guard !cleaned.isEmpty else { return nil }

        return InlineSuggestion(
            text: cleaned,
            replacementRange: nil,
            replacementText: cleaned
        )
    }

    // MARK: - Private

    private func buildSystemPrompt(settings: AISettings, context: SuggestionContext) async -> String {
        guard settings.includeSchema,
              let provider = schemaProvider else {
            return AIPromptTemplates.inlineSuggestSystemPrompt()
        }

        let schemaContext = await provider.buildSchemaContextForAI(
            settings: settings,
            editorText: context.fullText,
            cursorOffset: context.cursorOffset
        )

        if let schemaContext, !schemaContext.isEmpty {
            return AIPromptTemplates.inlineSuggestSystemPrompt(schemaContext: schemaContext)
        }
        return AIPromptTemplates.inlineSuggestSystemPrompt()
    }
}
